import Foundation
import Testing
@testable import MeetingMate

/// Fake embedder: records which texts it was asked to embed; can pretend Ollama is off.
private final class MockEmbedder: EmbeddingClient {
    var embedded: [String] = []
    var failWith: LLMError?

    func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        if let failWith { throw failWith }
        embedded += texts
        return texts.map { _ in Vector.normalized([1, 2, 3]) }
    }
}

/// A temporary project folder + index database, removed after each test.
private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "lang-index-\(UUID().uuidString)")
    let store: IndexStore
    let embedder = MockEmbedder()

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try IndexStore(url: root.appending(path: "index.sqlite.tmp")) // not indexed: unknown extension
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String, modified: Date) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func run(embedder: EmbeddingClient? = nil) async throws -> IndexUpdater.Result {
        try await IndexUpdater(root: root, store: store, embedder: embedder ?? self.embedder, model: "bge-m3",
                               maxFileSize: 2_000_000, patterns: []).run()
    }
}

private let day1 = Date(timeIntervalSince1970: 1_790_000_000)
private let day2 = Date(timeIntervalSince1970: 1_790_086_400)

struct IndexUpdateTests {
    @Test func firstRunIndexesAndEmbedsEverything() async throws {
        let box = try Sandbox()
        try box.write("a.md", "# A\nTính năng thanh toán QR.", modified: day1)
        try box.write("b.txt", "Ghi chú về ngân sách.", modified: day1)
        try box.write("src/c.swift", "func pay() {}\n", modified: day1)

        let result = try await box.run()
        #expect(result.added == 3)
        #expect(try box.store.chunkCount() == 3)
        #expect(box.embedder.embedded.count == 3)
        #expect(try box.store.allFiles().allSatisfy { $0.embeddingModel == "bge-m3" })
        // Vectors are stored as Float32 blobs of unit length.
        let vector = try #require(try box.store.chunks(path: "a.md").first?.vector)
        let floats = Vector.floats(vector)
        #expect(abs(floats.reduce(0) { $0 + $1 * $1 } - 1) < 0.0001)
    }

    @Test func unchangedFilesAreNotReadOrEmbeddedAgain() async throws {
        let box = try Sandbox()
        try box.write("a.md", "# A\nNội dung.", modified: day1)
        try box.write("b.md", "# B\nNội dung khác.", modified: day1)
        _ = try await box.run()
        box.embedder.embedded = []

        let result = try await box.run()
        #expect(result.unchanged == 2 && result.added == 0 && result.updated == 0)
        #expect(box.embedder.embedded.isEmpty)
    }

    @Test func editingOneFileReembedsOnlyThatFile() async throws {
        let box = try Sandbox()
        try box.write("a.md", "# A\nPhiên bản 1.", modified: day1)
        try box.write("b.md", "# B\nKhông đổi.", modified: day1)
        _ = try await box.run()
        box.embedder.embedded = []

        try box.write("a.md", "# A\nPhiên bản 2 mới hơn.", modified: day2)
        let result = try await box.run()
        #expect(result.updated == 1 && result.unchanged == 1)
        #expect(box.embedder.embedded.count == 1)
        #expect(box.embedder.embedded[0].contains("Phiên bản 2"))
        #expect(try box.store.chunks(path: "a.md").first?.text.contains("Phiên bản 2") == true)
    }

    @Test func touchedButIdenticalFileIsNotReembedded() async throws {
        let box = try Sandbox()
        try box.write("a.md", "# A\nGiống hệt.", modified: day1)
        _ = try await box.run()
        box.embedder.embedded = []

        try box.write("a.md", "# A\nGiống hệt.", modified: day2) // same text, new date
        let result = try await box.run()
        #expect(result.unchanged == 1)
        #expect(box.embedder.embedded.isEmpty)
        #expect(try box.store.file("a.md")?.modified == day2.timeIntervalSince1970)
    }

    @Test func deletedFilesLoseTheirChunks() async throws {
        let box = try Sandbox()
        try box.write("a.md", "# A\nSẽ bị xóa.", modified: day1)
        try box.write("b.md", "# B\nỞ lại.", modified: day1)
        _ = try await box.run()

        try FileManager.default.removeItem(at: box.root.appending(path: "a.md"))
        let result = try await box.run()
        #expect(result.removed == 1)
        #expect(try box.store.file("a.md") == nil)
        #expect(try box.store.chunks(path: "a.md").isEmpty)
        #expect(try box.store.chunkCount() == 1)
    }

    @Test func withoutOllamaChunksAreKeptAndEmbeddedLater() async throws {
        let box = try Sandbox()
        try box.write("a.md", "# A\nCần vector.", modified: day1)
        let offline = MockEmbedder()
        offline.failWith = .notRunning

        let first = try await box.run(embedder: offline)
        #expect(first.embeddingProblemIsNotRunning)
        #expect(try box.store.file("a.md")?.embeddingModel == nil) // stored, keyword search only
        #expect(try box.store.chunks(path: "a.md").first?.vector == nil)

        // Ollama is back: the same (unchanged) file now gets its vectors.
        let second = try await box.run()
        #expect(second.embeddingProblem == nil)
        #expect(box.embedder.embedded.count == 1)
        #expect(try box.store.file("a.md")?.embeddingModel == "bge-m3")
    }
}
