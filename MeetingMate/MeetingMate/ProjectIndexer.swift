import AppKit
import CryptoKit
import Foundation

/// One row in "Show Indexed Files".
struct IndexedFileInfo: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let sourceType: SourceType
    let chunkCount: Int
    let modified: Date
    let indexedAt: Date
    let hasVectors: Bool
    var error: String?

    init(_ record: IndexedFileRecord) {
        path = record.path
        sourceType = record.sourceType
        chunkCount = record.chunkCount
        modified = Date(timeIntervalSince1970: record.modified)
        indexedAt = Date(timeIntervalSince1970: record.indexedAt)
        hasVectors = record.embeddingModel != nil || record.chunkCount == 0
        error = record.error
    }
}

// MARK: - Incremental update (no UI; covered by unit tests)

/// Brings the index up to date with the project folder:
/// unchanged files are skipped, changed files are re-chunked and re-embedded,
/// removed files are deleted from the index.
struct IndexUpdater {
    struct Result: Equatable {
        var added = 0, updated = 0, unchanged = 0, removed = 0
        /// Set when vectors couldn't be made (Ollama off, model missing). Keyword search still works.
        var embeddingProblem: String?
        var embeddingProblemIsMissingModel = false
        var embeddingProblemIsNotRunning = false
    }

    static let batchSize = 16

    let root: URL
    let store: IndexStore
    let embedder: EmbeddingClient?
    let model: String
    let maxFileSize: Int
    let patterns: [String]

    /// - Parameters:
    ///   - force: re-read and re-embed every file ("Reindex Project").
    ///   - progress: (files done, total files).
    ///   - mayContinue: waits while indexing is paused; returns false to cancel.
    func run(force: Bool = false,
             progress: @escaping (Int, Int) async -> Void = { _, _ in },
             mayContinue: @escaping () async -> Bool = { true }) async throws -> Result {
        var result = Result()
        let found = ProjectScanner.scan(root: root, maxFileSize: maxFileSize, extraPatterns: patterns)
        let stored = Dictionary(uniqueKeysWithValues: try store.allFiles().map { ($0.path, $0) })

        // Files that disappeared.
        let foundPaths = Set(found.map(\.relativePath))
        let removed = stored.keys.filter { !foundPaths.contains($0) }
        try store.delete(paths: removed)
        result.removed = removed.count

        var embedder = self.embedder
        for (index, file) in found.enumerated() {
            guard await mayContinue() else { throw CancellationError() }
            await progress(index, found.count)

            let previous = stored[file.relativePath]
            let modified = file.modified.timeIntervalSince1970
            let vectorsDone = { (record: IndexedFileRecord) in
                record.embeddingModel == model || record.chunkCount == 0 || embedder == nil
            }
            // Same modified date and vectors present: nothing to do (we don't even read it).
            if !force, let previous, previous.modified == modified, vectorsDone(previous) {
                result.unchanged += 1
                continue
            }

            var record = IndexedFileRecord(path: file.relativePath, sourceType: file.sourceType,
                                           modified: modified, hash: "",
                                           meetingDate: file.meetingDate?.timeIntervalSince1970,
                                           indexedAt: Date().timeIntervalSince1970, chunkCount: 0,
                                           embeddingModel: nil, error: nil)
            let text: String
            do {
                text = try DocumentLoader.text(of: file)
            } catch {
                record.error = error.localizedDescription
                try store.replace(record, chunks: [])
                result.updated += 1
                continue
            }
            record.hash = Self.hash(text)

            // Modified date changed but the text is identical (e.g. the file was only touched).
            if !force, let previous, previous.hash == record.hash, vectorsDone(previous) {
                try store.touch(file.relativePath, modified: modified)
                result.unchanged += 1
                continue
            }

            let pieces = Chunker.chunks(for: file, text: text)
            var vectors: [[Float]]?
            if let client = embedder, !pieces.isEmpty {
                do {
                    vectors = []
                    for start in stride(from: 0, to: pieces.count, by: Self.batchSize) {
                        guard await mayContinue() else { throw CancellationError() }
                        let batch = pieces[start..<min(start + Self.batchSize, pieces.count)]
                        vectors! += try await client.embed(batch.map(Self.embeddingInput(file: file)), model: model)
                    }
                } catch let error as LLMError {
                    // Ollama is off or the model is missing: keep going with keyword search only.
                    vectors = nil
                    embedder = nil
                    result.embeddingProblem = error.localizedDescription
                    if case .modelMissing = error { result.embeddingProblemIsMissingModel = true }
                    if case .notRunning = error { result.embeddingProblemIsNotRunning = true }
                }
            }

            record.chunkCount = pieces.count
            record.embeddingModel = (vectors != nil || pieces.isEmpty) ? model : nil
            let chunks = pieces.enumerated().map { i, piece in
                ChunkRecord(id: nil, path: file.relativePath, sourceType: file.sourceType, location: piece.location,
                            text: piece.text, searchText: TranscriptMerger.normalize(piece.text),
                            modified: modified, hash: record.hash,
                            meetingDate: file.meetingDate?.timeIntervalSince1970,
                            vector: vectors.map { Vector.data($0[i]) })
            }
            try store.replace(record, chunks: chunks)
            if previous == nil { result.added += 1 } else { result.updated += 1 }
        }
        await progress(found.count, found.count)
        return result
    }

    /// The text that gets embedded: file name and location help the model place the chunk.
    static func embeddingInput(file: ProjectFile) -> (TextChunk) -> String {
        { chunk in "\(file.relativePath) — \(chunk.location)\n\(chunk.text)" }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - UI side: progress, pausing, watching for changes

@MainActor
final class ProjectIndexer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case reading(done: Int, total: Int)
        case paused(done: Int, total: Int)
        case ready
    }

    /// Why vectors are missing (keyword search still works meanwhile).
    enum Problem: Equatable {
        case ollamaNotRunning
        case modelMissing(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var files: [IndexedFileInfo] = []
    @Published private(set) var chunkCount = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var problem: Problem?
    @Published private(set) var downloadProgress: Double?
    @Published var errorMessage: String?

    /// Indexing waits while this returns false (recording, transcribing or summarizing).
    var canRun: () -> Bool = { true }
    /// Short reason shown while paused.
    var pauseReason: () -> String = { "" }

    private(set) var projectFolder: URL?
    private(set) var store: IndexStore?
    private var task: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var updateAgain = false
    private let ollama = OllamaClient()

    // MARK: Menu text

    var statusText: String? {
        switch phase {
        case .idle: return nil
        case .scanning: return "Đang tìm file trong dự án…"
        case .reading(let done, let total): return "Đang đọc dự án… \(done)/\(total) file"
        case .paused(let done, let total): return "Tạm dừng đọc dự án (\(done)/\(total)) · \(pauseReason())"
        case .ready:
            let count = Self.numberFormatter.string(from: NSNumber(value: chunkCount)) ?? "\(chunkCount)"
            var when = ""
            if let lastUpdated {
                when = Date().timeIntervalSince(lastUpdated) < 60
                    ? "vừa xong"
                    : Self.relativeFormatter.localizedString(for: lastUpdated, relativeTo: Date())
            }
            return "Đã đọc \(count) đoạn · cập nhật \(when)"
        }
    }

    var progressValue: Double? {
        switch phase {
        case .reading(let done, let total), .paused(let done, let total):
            total > 0 ? Double(done) / Double(total) : nil
        default: nil
        }
    }

    var isWorking: Bool {
        switch phase {
        case .scanning, .reading, .paused: true
        default: false
        }
    }

    // MARK: Actions

    /// Opens (or creates) the project's index, brings it up to date and watches for changes.
    func index(projectFolder: URL?) {
        task?.cancel()
        task = nil
        watcher = nil
        store = nil
        self.projectFolder = projectFolder
        files = []
        chunkCount = 0
        lastUpdated = nil
        guard let projectFolder else {
            phase = .idle
            return
        }
        do {
            store = try IndexStore(projectFolder: projectFolder)
            refreshFromStore()
        } catch {
            errorMessage = "Can't open the project index: \(error.localizedDescription)"
            phase = .idle
            return
        }
        // Re-check the project 5 s after files stop changing.
        watcher = FileWatcher(folder: projectFolder, delay: 5) { [weak self] in
            self?.update()
        }
        update()
    }

    /// Incremental update: only changed files are re-read and re-embedded.
    func update(force: Bool = false) {
        guard let projectFolder, let store else { return }
        if task != nil { // already running: run once more afterwards
            updateAgain = true
            return
        }
        errorMessage = nil
        phase = .scanning
        let updater = IndexUpdater(root: projectFolder, store: store, embedder: ollama,
                                   model: AppSettings.embeddingModel,
                                   maxFileSize: AppSettings.maxIndexFileSize,
                                   patterns: AppSettings.extraIgnorePatterns)
        task = Task {
            do {
                let result = try await updater.run(
                    force: force,
                    progress: { done, total in
                        await MainActor.run { self.phase = .reading(done: done, total: total) }
                    },
                    mayContinue: { await self.waitUntilAllowed() })
                problem = result.embeddingProblemIsMissingModel ? .modelMissing(AppSettings.embeddingModel)
                    : result.embeddingProblemIsNotRunning ? .ollamaNotRunning : nil
                if let message = result.embeddingProblem, problem == nil { errorMessage = message }
                try? store.setInfo("lastUpdated", "\(Date().timeIntervalSince1970)")
            } catch is CancellationError {
                // a new project was picked; nothing to report
            } catch {
                errorMessage = "Indexing failed: \(error.localizedDescription)"
            }
            if self.store === store {
                refreshFromStore()
                phase = .ready
            }
            task = nil
            if updateAgain {
                updateAgain = false
                update()
            }
        }
    }

    /// Hybrid search over the current project's index (nil when no project is open).
    var retriever: ProjectRetriever? {
        guard let store else { return nil }
        let model = AppSettings.embeddingModel
        if let cached = cachedRetriever, cached.store === store, cached.model == model { return cached.retriever }
        let retriever = ProjectRetriever(store: store, embedder: ollama, model: model)
        cachedRetriever = (store, model, retriever)
        return retriever
    }
    private var cachedRetriever: (store: IndexStore, model: String, retriever: ProjectRetriever)?

    /// "Reindex Project": re-read and re-embed everything.
    func reindex() {
        guard task == nil else { return }
        update(force: true)
    }

    /// Settings → "Delete project index".
    func deleteIndex() {
        guard let projectFolder else { return }
        task?.cancel()
        task = nil
        watcher = nil
        store = nil
        do {
            try IndexStore.deleteDatabase(for: projectFolder)
            files = []
            chunkCount = 0
            lastUpdated = nil
            phase = .idle
            // Keep the same project folder; "Reindex Project" builds a fresh index.
            store = try IndexStore(projectFolder: projectFolder)
            watcher = FileWatcher(folder: projectFolder, delay: 5) { [weak self] in self?.update() }
        } catch {
            errorMessage = "Could not delete the index: \(error.localizedDescription)"
        }
    }

    /// Downloads the embedding model, then indexes again.
    func downloadModel() {
        guard case .modelMissing(let model) = problem, downloadProgress == nil else { return }
        downloadProgress = 0
        Task {
            do {
                try await ollama.pull(model: model) { p in
                    Task { @MainActor in self.downloadProgress = p }
                }
                downloadProgress = nil
                problem = nil
                update()
            } catch {
                downloadProgress = nil
                errorMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    /// Opens Ollama, then updates once it answers.
    func openOllamaAndRetry() {
        let app = URL(fileURLWithPath: "/Applications/Ollama.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        Task {
            for _ in 0..<30 {
                if await ollama.isRunning() { problem = nil; update(); return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Helpers

    /// Waits while recording/transcribing/summarizing. Returns false if this run was cancelled.
    private func waitUntilAllowed() async -> Bool {
        while !canRun() {
            if case .reading(let done, let total) = phase { phase = .paused(done: done, total: total) }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return false }
        }
        if case .paused(let done, let total) = phase { phase = .reading(done: done, total: total) }
        return !Task.isCancelled
    }

    private func refreshFromStore() {
        guard let store else { return }
        files = ((try? store.allFiles()) ?? []).map(IndexedFileInfo.init)
        chunkCount = (try? store.chunkCount()) ?? 0
        if let value = try? store.info("lastUpdated"), let seconds = Double(value) {
            lastUpdated = Date(timeIntervalSince1970: seconds)
        }
        if !files.isEmpty, phase == .idle { phase = .ready }
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "vi_VN") // 1.240
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "vi_VN") // "2 phút trước"
        f.unitsStyle = .full
        return f
    }()
}
