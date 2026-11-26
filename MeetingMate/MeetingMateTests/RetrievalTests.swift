import Foundation
import Testing
@testable import MeetingMate

// MARK: - Ranking math

struct RankingTests {
    @Test func cosineScoresAreDotProductsOfUnitVectors() {
        let matrix: [Float] = [1, 0,   0, 1,   0.6, 0.8] // 3 rows × 2 dims
        let scores = Ranking.cosineScores(matrix: matrix, dimensions: 2, query: [1, 0])
        #expect(scores.count == 3)
        let expected: [Float] = [1, 0, 0.6]
        for (score, want) in zip(scores, expected) {
            #expect(abs(score - want) < 1e-6)
        }
        #expect(Ranking.topIndices(scores, count: 2) == [0, 2])
    }

    @Test func rrfRewardsItemsFoundByBothMethods() {
        // 3 is only 3rd in the vector list, but also 1st in the keyword list → wins overall.
        let fused = Ranking.reciprocalRankFusion([[1, 2, 3], [3, 4]])
        let order = fused.sorted { $0.value > $1.value }.map(\.key)
        #expect(order.first == 3)
        let expected: Double = 1.0 / 63 + 1.0 / 61 // 3rd in one list + 1st in the other
        let difference: Double = abs((fused[3] ?? 0) - expected)
        #expect(difference < 1e-12)
    }

    private func chunk(_ id: Int64, _ path: String, _ score: Double, meeting: Date? = nil) -> RetrievedChunk {
        RetrievedChunk(id: id, path: path, sourceType: meeting == nil ? .doc : .meeting, location: "",
                       text: "", meetingDate: meeting, score: score)
    }

    @Test func atMostTwoChunksPerFile() {
        let sorted = [chunk(1, "a.md", 0.9), chunk(2, "a.md", 0.8), chunk(3, "a.md", 0.7),
                      chunk(4, "b.md", 0.6), chunk(5, "c.md", 0.5)]
        let picked = Ranking.diversify(sorted, perFile: 2, limit: 3)
        #expect(picked.map(\.id) == [1, 2, 4])
    }

    @Test func recentMeetingsWinOnlyNearTies() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = Ranking.recencyBonus(meetingDate: now.addingTimeInterval(-86_400), now: now)
        let old = Ranking.recencyBonus(meetingDate: now.addingTimeInterval(-365 * 86_400), now: now)
        #expect(recent > old)
        #expect(Ranking.recencyBonus(meetingDate: nil, now: now) == 0)
        // A clearly better match (rank 1 vs rank 10 in one list) still beats a fresh meeting.
        let gap = 1.0 / 61 - 1.0 / 70
        #expect(recent < gap)
    }
}

// MARK: - Hybrid search on a real (temporary) index

/// Fake embedder that understands two topics in both languages, so we can test "meaning" search.
private final class TopicEmbedder: EmbeddingClient {
    var offline = false

    func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        if offline { throw LLMError.notRunning }
        return texts.map { text in
            let n = TranscriptMerger.normalize(text)
            if n.contains("thanh toan") || n.contains("payment") { return [1, 0, 0] }
            if n.contains("ngan sach") || n.contains("budget") { return [0, 1, 0] }
            return [0, 0, 1]
        }
    }
}

struct RetrieverTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "lang-search-\(UUID().uuidString)")

    private func makeIndex(embedder: TopicEmbedder) async throws -> IndexStore {
        func write(_ path: String, _ text: String) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("docs/payments.md", """
            # Thanh toán
            Tính năng thanh toán QR cho khách hàng.
            ## Thanh toán thẻ
            Thanh toán bằng thẻ nội địa.
            ## Thanh toán ví
            Thanh toán qua ví điện tử.
            ## Hoàn tiền thanh toán
            Quy trình hoàn tiền thanh toán.
            """)
        try write("docs/budget.md", "# Ngân sách\nNgân sách quý 4 là 200 triệu.")
        try write("team.md", "# Nhóm\nNgười phụ trách backend là Nguyễn Văn Tùng.")
        try write(".meetings/2026-11-25_22-07-16/summary.md", "# Họp\nChốt thanh toán QR ra mắt tháng 12.")

        let store = try IndexStore(url: root.appending(path: "index.db"))
        _ = try await IndexUpdater(root: root, store: store, embedder: embedder, model: "test",
                                   maxFileSize: 2_000_000, patterns: []).run()
        return store
    }

    @Test func findsByMeaningEvenWithoutSharedWords() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let embedder = TopicEmbedder()
        let retriever = ProjectRetriever(store: try await makeIndex(embedder: embedder), embedder: embedder, model: "test")
        let results = try await retriever.search(query: "payment feature", limit: 3)
        #expect(results.first?.path == "docs/payments.md" || results.first?.path.hasPrefix(".meetings/") == true)
        #expect(!results.contains { $0.path == "docs/budget.md" })
    }

    @Test func findsNamesByKeywordWithoutAccents() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let embedder = TopicEmbedder()
        let retriever = ProjectRetriever(store: try await makeIndex(embedder: embedder), embedder: embedder, model: "test")
        let results = try await retriever.search(query: "Tung", limit: 3) // no accent, embeddings don't help here
        #expect(results.first?.path == "team.md")
    }

    @Test func capsChunksPerFileAndCanExcludeAMeeting() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let embedder = TopicEmbedder()
        let retriever = ProjectRetriever(store: try await makeIndex(embedder: embedder), embedder: embedder, model: "test")
        let results = try await retriever.search(query: "thanh toán", limit: 8,
                                                 excludingPathPrefix: ".meetings/2026-11-25_22-07-16/")
        #expect(results.filter { $0.path == "docs/payments.md" }.count == 2) // file has 4 matching chunks
        #expect(!results.contains { $0.path.hasPrefix(".meetings/") })
    }

    @Test func keywordSearchStillWorksWhenOllamaIsOff() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let embedder = TopicEmbedder()
        let store = try await makeIndex(embedder: embedder)
        embedder.offline = true
        let results = try await ProjectRetriever(store: store, embedder: embedder, model: "test")
            .search(query: "ngân sách", limit: 3)
        #expect(results.first?.path == "docs/budget.md")
    }
}
