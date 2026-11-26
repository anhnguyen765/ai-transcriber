import CryptoKit
import Foundation
import GRDB

/// One indexed file (table "file").
struct IndexedFileRecord: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "file"

    var path: String            // relative to the project folder
    var sourceType: SourceType
    var modified: Double        // seconds since 1970
    var hash: String            // SHA-256 of the extracted text
    var meetingDate: Double?
    var indexedAt: Double
    var chunkCount: Int
    /// The embedding model used for this file's vectors; nil = vectors still missing.
    var embeddingModel: String?
    var error: String?
}

/// One chunk (table "chunk"); its searchText is mirrored into the FTS5 table "chunk_ft".
struct ChunkRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chunk"

    var id: Int64?
    var path: String
    var sourceType: SourceType
    var location: String        // heading path, time range or line range
    var text: String
    var searchText: String      // lowercase, no accents (đ → d), for keyword search
    var modified: Double
    var hash: String            // content hash of the file it came from
    var meetingDate: Double?
    var vector: Data?           // Float32, unit length

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension SourceType: DatabaseValueConvertible {}

/// The project's index: one SQLite database per project in
/// ~/Library/Application Support/Lang/Indexes/, so the project folder stays clean.
final class IndexStore {
    let url: URL
    private let db: DatabaseQueue

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Lang/Indexes", directoryHint: .isDirectory)
    }

    /// Stable id from the folder path: "<folder name>-<first 12 hex of SHA-256(path)>".
    static func databaseURL(for projectFolder: URL) -> URL {
        let path = projectFolder.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let name = projectFolder.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        return folder.appending(path: "\(name)-\(digest).sqlite")
    }

    convenience init(projectFolder: URL) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try self.init(url: Self.databaseURL(for: projectFolder))
    }

    init(url: URL) throws {
        self.url = url
        db = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(db)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "file") { t in
                t.primaryKey("path", .text)
                t.column("sourceType", .text).notNull()
                t.column("modified", .double).notNull()
                t.column("hash", .text).notNull()
                t.column("meetingDate", .double)
                t.column("indexedAt", .double).notNull()
                t.column("chunkCount", .integer).notNull()
                t.column("embeddingModel", .text)
                t.column("error", .text)
            }
            try db.create(table: "chunk") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().indexed()
                    .references("file", column: "path", onDelete: .cascade)
                t.column("sourceType", .text).notNull()
                t.column("location", .text).notNull()
                t.column("text", .text).notNull()
                t.column("searchText", .text).notNull()
                t.column("modified", .double).notNull()
                t.column("hash", .text).notNull()
                t.column("meetingDate", .double)
                t.column("vector", .blob)
            }
            // Keyword search; kept in sync with "chunk" automatically by triggers.
            try db.create(virtualTable: "chunk_ft", using: FTS5()) { t in
                t.synchronize(withTable: "chunk")
                t.tokenizer = .unicode61()
                t.column("searchText")
            }
            try db.create(table: "info") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        return migrator
    }

    // MARK: - Files

    func allFiles() throws -> [IndexedFileRecord] {
        try db.read { try IndexedFileRecord.order(Column("path")).fetchAll($0) }
    }

    func file(_ path: String) throws -> IndexedFileRecord? {
        try db.read { try IndexedFileRecord.fetchOne($0, key: path) }
    }

    /// Replaces a file and all its chunks in one transaction.
    func replace(_ file: IndexedFileRecord, chunks: [ChunkRecord]) throws {
        try db.write { db in
            _ = try IndexedFileRecord.deleteOne(db, key: file.path) // cascades to its chunks
            try file.insert(db)
            for var chunk in chunks { try chunk.insert(db) }
        }
        didChange()
    }

    /// The file didn't really change (same text): only remember the new modified date.
    func touch(_ path: String, modified: Double) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE file SET modified = ? WHERE path = ?", arguments: [modified, path])
            try db.execute(sql: "UPDATE chunk SET modified = ? WHERE path = ?", arguments: [modified, path])
        }
        didChange()
    }

    func delete(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try db.write { db in _ = try IndexedFileRecord.deleteAll(db, keys: paths) }
        didChange()
    }

    func deleteEverything() throws {
        try db.write { db in
            _ = try IndexedFileRecord.deleteAll(db)
            try db.execute(sql: "DELETE FROM info")
        }
        didChange()
    }

    // MARK: - Chunks

    func chunkCount() throws -> Int {
        try db.read { try ChunkRecord.fetchCount($0) }
    }

    func chunks(path: String) throws -> [ChunkRecord] {
        try db.read { try ChunkRecord.filter(Column("path") == path).order(Column("id")).fetchAll($0) }
    }

    /// Walks every chunk's text without loading them all at once (used for glossary suggestions).
    func forEachChunk(_ body: (_ path: String, _ sourceType: SourceType, _ text: String) -> Void) throws {
        try db.read { db in
            let rows = try Row.fetchCursor(db, sql: "SELECT path, sourceType, text FROM chunk")
            while let row = try rows.next() {
                let type = SourceType(rawValue: row["sourceType"] ?? "") ?? .doc
                body(row["path"], type, row["text"])
            }
        }
    }

    func chunks(ids: [Int64]) throws -> [ChunkRecord] {
        try db.read { try ChunkRecord.fetchAll($0, keys: ids) }
    }

    // MARK: - Search support

    /// Goes up on every write, so the retriever knows when to reload its vectors.
    private(set) var changeCounter = 0
    private let counterLock = NSLock()

    private func didChange() {
        counterLock.withLock { changeCounter += 1 }
    }

    var currentChangeCounter: Int { counterLock.withLock { changeCounter } }

    /// Per-row facts the search filters on (scope, meeting dates).
    struct ChunkMeta {
        let sourceType: SourceType
        let meetingDate: Double?
        let path: String
    }

    /// All stored vectors as one row-major matrix (n × dimensions), for brute-force cosine search.
    func vectorMatrix() throws -> (ids: [Int64], meta: [ChunkMeta], dimensions: Int, matrix: [Float]) {
        try db.read { db in
            var ids: [Int64] = []
            var meta: [ChunkMeta] = []
            var matrix: [Float] = []
            var dimensions = 0
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, vector, sourceType, meetingDate, path FROM chunk WHERE vector IS NOT NULL
                """)
            while let row = try rows.next() {
                let data: Data = row["vector"]
                let count = data.count / MemoryLayout<Float>.size
                if dimensions == 0 { dimensions = count }
                guard count == dimensions else { continue } // skip vectors from another model
                ids.append(row["id"])
                meta.append(ChunkMeta(sourceType: SourceType(rawValue: row["sourceType"] ?? "") ?? .doc,
                                      meetingDate: row["meetingDate"], path: row["path"] ?? ""))
                data.withUnsafeBytes { matrix.append(contentsOf: $0.bindMemory(to: Float.self)) }
            }
            return (ids, meta, dimensions, matrix)
        }
    }

    /// Keyword search with FTS5, best (bm25) first. The query is matched without accents.
    func keywordSearch(_ query: String, limit: Int, filter: SearchFilter = SearchFilter()) throws -> [Int64] {
        let normalized = TranscriptMerger.normalize(query)
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: normalized) else { return [] }
        var sql = """
            SELECT chunk_ft.rowid FROM chunk_ft JOIN chunk ON chunk.id = chunk_ft.rowid
            WHERE chunk_ft MATCH ?
            """
        var arguments: StatementArguments = [pattern]
        if let types = filter.sourceTypes {
            sql += " AND chunk.sourceType IN (\(types.map { _ in "?" }.joined(separator: ",")))"
            for type in types.sorted(by: { $0.rawValue < $1.rawValue }) { _ = arguments.append(contentsOf: [type.rawValue]) }
        }
        if let from = filter.meetingsFrom {
            sql += " AND (chunk.meetingDate IS NULL OR chunk.meetingDate >= ?)"
            _ = arguments.append(contentsOf: [from.timeIntervalSince1970])
        }
        if let to = filter.meetingsTo {
            sql += " AND (chunk.meetingDate IS NULL OR chunk.meetingDate < ?)"
            _ = arguments.append(contentsOf: [to.timeIntervalSince1970])
        }
        if let prefix = filter.pathPrefix {
            sql += " AND substr(chunk.path, 1, ?) = ?"
            _ = arguments.append(contentsOf: [prefix.count, prefix])
        }
        sql += " ORDER BY bm25(chunk_ft) LIMIT ?"
        _ = arguments.append(contentsOf: [limit])
        let finalArguments = arguments
        return try db.read { db in try Int64.fetchAll(db, sql: sql, arguments: finalArguments) }
    }

    // MARK: - Small key/value info (e.g. last update time)

    func info(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM info WHERE key = ?", arguments: [key]) }
    }

    func setInfo(_ key: String, _ value: String) throws {
        try db.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO info (key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }

    /// Deletes this project's database file (Settings → "Delete project index").
    static func deleteDatabase(for projectFolder: URL) throws {
        let url = databaseURL(for: projectFolder)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
