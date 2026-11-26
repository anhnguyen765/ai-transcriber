import Foundation
import Testing
@testable import MeetingMate

/// Fake LLM for the rewriter: fixed reply, remembers the prompt.
private final class OneReplyLLM: LLMClient {
    let reply: String?
    var prompts: [String] = []
    init(_ reply: String?) { self.reply = reply }

    func isRunning() async -> Bool { true }
    func installedModels() async throws -> [String] { [] }
    func pull(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func chat(messages: [LLMMessage], options: LLMChatOptions,
              onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        prompts.append(messages.last?.content ?? "")
        guard let reply else { throw LLMError.notRunning }
        return reply
    }
    func unload(model: String) async {}
}

private let today = ISO8601DateFormatter().date(from: "2026-11-26T03:00:00Z")!

struct QueryRewriterTests {
    @Test func plainQuestionWithoutHistoryOrDatesSkipsTheLLM() async {
        let llm = OneReplyLLM(#"{"query":"should not be used","meetingsFrom":"","meetingsTo":""}"#)
        let result = await QueryRewriter(client: llm, model: "m").rewrite(question: "Ai phụ trách backend?", history: [])
        #expect(result == RewrittenQuery(query: "Ai phụ trách backend?", meetingsFrom: nil, meetingsTo: nil))
        #expect(llm.prompts.isEmpty)
    }

    @Test func followUpUsesHistoryAndReturnsStandaloneQuery() async {
        let llm = OneReplyLLM(#"{"query":"người phụ trách thanh toán QR","meetingsFrom":"","meetingsTo":""}"#)
        let history = [(question: "Thanh toán QR ra mắt khi nào?", answer: "Tháng 1 [S1].")]
        let result = await QueryRewriter(client: llm, model: "m")
            .rewrite(question: "Còn ai phụ trách?", history: history, today: today)
        #expect(result.query == "người phụ trách thanh toán QR")
        #expect(result.meetingsFrom == nil && result.meetingsTo == nil)
        #expect(llm.prompts.first?.contains("Thanh toán QR ra mắt khi nào?") == true)
        #expect(llm.prompts.first?.contains("2026-11-26") == true) // knows today's date
    }

    @Test func relativeDatesBecomeAWholeDayRange() async throws {
        let llm = OneReplyLLM(#"{"query":"deadline team đã chốt","meetingsFrom":"2026-11-16","meetingsTo":"2026-11-22"}"#)
        let result = await QueryRewriter(client: llm, model: "m")
            .rewrite(question: "Tuần trước team đã chốt gì về deadline?", history: [], today: today)
        let range = result.dateRange()
        let from = try #require(range.from), to = try #require(range.to)
        let f = RewrittenQuery.dayFormatter
        #expect(f.string(from: from) == "2026-11-16")
        #expect(f.string(from: to) == "2026-11-23") // exclusive end: includes all of the 22nd
    }

    @Test func brokenReplyOrBadDatesFallBackSafely() async {
        let broken = await QueryRewriter(client: OneReplyLLM("not json"), model: "m")
            .rewrite(question: "Hôm qua họp gì?", history: [])
        #expect(broken.query == "Hôm qua họp gì?")
        let offline = await QueryRewriter(client: OneReplyLLM(nil), model: "m")
            .rewrite(question: "Hôm qua họp gì?", history: [])
        #expect(offline.query == "Hôm qua họp gì?")
        let badDates = await QueryRewriter(client: OneReplyLLM(#"{"query":"x","meetingsFrom":"tuần trước","meetingsTo":""}"#),
                                           model: "m").rewrite(question: "tuần trước?", history: [])
        #expect(badDates.meetingsFrom == nil)
    }
}

struct AnswerServiceTests {
    private func chunk(_ id: Int64) -> RetrievedChunk {
        RetrievedChunk(id: id, path: "docs/\(id).md", sourceType: .doc, location: "", text: "x",
                       meetingDate: nil, score: 0.01)
    }

    @Test func notFoundWhenSimilarityIsBelowThreshold() {
        let weak = SearchOutcome(chunks: [chunk(1)], bestSimilarity: AnswerService.minSimilarity - 0.05, keywordHits: 9)
        let strong = SearchOutcome(chunks: [chunk(1)], bestSimilarity: AnswerService.minSimilarity + 0.05, keywordHits: 0)
        #expect(AnswerService.isNotFound(weak))   // keyword noise doesn't override a weak vector match
        #expect(!AnswerService.isNotFound(strong))
        #expect(AnswerService.isNotFound(SearchOutcome(chunks: [], bestSimilarity: 0.9, keywordHits: 3)))
        // Without vectors (Ollama embedding unavailable), keyword hits decide.
        #expect(!AnswerService.isNotFound(SearchOutcome(chunks: [chunk(1)], bestSimilarity: nil, keywordHits: 2)))
        #expect(AnswerService.isNotFound(SearchOutcome(chunks: [chunk(1)], bestSimilarity: nil, keywordHits: 0)))
    }

    @Test func notFoundReplyListsClosestThreeSources() {
        let sources = AnswerService.sources(from: (1...5).map(chunk))
        let reply = AnswerService.notFoundReply(closest: sources, query: "ngân sách")
        #expect(reply.hasPrefix(AnswerService.notFoundMessage))
        #expect(reply.contains("[S3]") && !reply.contains("[S4]"))
    }

    @Test func parsesCitationsInOrderWithoutDuplicates() {
        let text = "Deadline là 15/12 [S2]. Đã chốt trong họp [S1][S2], tài liệu ghi khác [S10]. [s3] và [S] bị bỏ."
        #expect(AnswerService.citations(in: text) == ["S2", "S1", "S10"])
    }

    @Test func promptLabelsSourcesAndKeepsRules() {
        let meeting = RetrievedChunk(id: 1, path: ".meetings/2026-11-20_10-00-00/transcript.md", sourceType: .meeting,
                                     location: "00:03:00–00:06:00", text: "Chốt deadline 15/12",
                                     meetingDate: AnswerService.dateFormatter.date(from: "2026-11-20"), score: 1)
        let messages = AnswerService.messages(question: "Deadline?", sources: AnswerService.sources(from: [meeting]),
                                              history: [])
        #expect(messages[0].content.contains("Mình không tìm thấy thông tin này trong dự án."))
        #expect(messages[1].content.contains(
            "[S1] cuộc họp 2026-11-20 · 00:03:00–00:06:00 · .meetings/2026-11-20_10-00-00/transcript.md\nChốt deadline 15/12"))
        #expect(messages[1].content.hasSuffix("Câu hỏi: Deadline?"))
    }
}

struct ChatExportTests {
    @Test func markdownRoundTrip() {
        var first = ChatTurn(question: "Deadline là khi nào?")
        first.answer = "Ngày 15/12 [S1]."
        first.status = .done
        first.sources = [AnswerSource(label: "S1", path: ".meetings/2026-11-20_10-00-00/transcript.md",
                                      location: "00:03:00–00:06:00", sourceType: .meeting,
                                      meetingDate: AnswerService.dateFormatter.date(from: "2026-11-20"), preview: "…"),
                         AnswerSource(label: "S2", path: "docs/plan.md", location: "", sourceType: .doc,
                                      meetingDate: nil, preview: "…")]
        var second = ChatTurn(question: "Ngân sách quý 5?")
        second.answer = AnswerService.notFoundMessage
        second.status = .notFound
        var unfinished = ChatTurn(question: "đang hỏi")
        unfinished.status = .answering // not saved

        let md = ChatExport.markdown([first, second, unfinished], projectName: "2027", started: today)
        #expect(md.contains("## Hỏi\n\nDeadline là khi nào?\n\n## Trả lời\n\nNgày 15/12 [S1]."))
        #expect(md.contains("- [S1] cuộc họp 2026-11-20 · 00:03:00–00:06:00 · .meetings/2026-11-20_10-00-00/transcript.md"))
        #expect(!md.contains("đang hỏi"))

        let parsed = ChatExport.parse(md)
        #expect(parsed.map(\.question) == ["Deadline là khi nào?", "Ngân sách quý 5?"])
        #expect(parsed[0].answer == "Ngày 15/12 [S1].")
        #expect(parsed[0].sources.map(\.path) == [".meetings/2026-11-20_10-00-00/transcript.md", "docs/plan.md"])
        #expect(parsed[0].sources[0].location == "00:03:00–00:06:00")
        #expect(parsed[0].sources[0].sourceType == .meeting)
        #expect(parsed[1].status == .notFound)
    }

    @Test func chatsAreNeverIndexed() {
        #expect(!FileWatcher.isRelevant("/p/.meetings/chats/2026-11-26_10-30.md"))
        let root = FileManager.default.temporaryDirectory.appending(path: "lang-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = root.appending(path: ".meetings/chats/2026-11-26_10-30.md")
        try? FileManager.default.createDirectory(at: chat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "# chat".write(to: chat, atomically: true, encoding: .utf8)
        #expect(ProjectScanner.scan(root: root, maxFileSize: 1_000_000, extraPatterns: []).isEmpty)
    }
}
