import Foundation
import Testing
@testable import MeetingMate

/// Fake LLM: returns prepared replies in order and remembers every prompt.
private final class ScriptedLLM: LLMClient {
    var replies: [String]
    var prompts: [String] = []
    var contextLengths: [Int] = []

    init(_ replies: [String]) { self.replies = replies }

    func isRunning() async -> Bool { true }
    func installedModels() async throws -> [String] { ["qwen3:8b"] }
    func pull(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    func chat(messages: [LLMMessage], options: LLMChatOptions,
              onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        prompts.append(messages.last?.content ?? "")
        contextLengths.append(options.contextLength)
        return replies.removeFirst()
    }
    func unload(model: String) async {}
}

/// Records the search queries it was given and returns fixed chunks.
private final class FakeSearch: @unchecked Sendable {
    var queries: [String] = []
    let results: [RetrievedChunk]
    init(_ results: [RetrievedChunk]) { self.results = results }
    func search(_ queries: [String]) async -> [RetrievedChunk] {
        self.queries = queries
        return results
    }
}

private func chunk(_ id: Int64, _ path: String, _ text: String, location: String = "",
                   meeting: Date? = nil) -> RetrievedChunk {
    RetrievedChunk(id: id, path: path, sourceType: meeting == nil ? .doc : .meeting, location: location,
                   text: text, meetingDate: meeting, score: 1)
}

private let notesReply = """
{"keyPoints":[{"text":"Thanh toán QR","timestamp":"00:00:10"}],
 "decisions":[{"text":"Ra mắt QR vào tháng 1","timestamp":"00:01:00"}],"actionItems":[],"openQuestions":[]}
"""

/// The model cites S1 (real), S9 (made up) and invents its own path.
private let contextSummaryReply = """
{"title":"Họp thanh toán","overview":"Chốt lịch QR.",
 "keyPoints":[{"text":"QR cho khách hàng","timestamp":"00:00:10","sourceRefs":["S1","S7"]}],
 "decisions":[{"text":"Ra mắt QR tháng 1","timestamp":"00:01:00","sourceRefs":["[S2]"]}],
 "actionItems":[],"openQuestions":[],
 "relatedDocs":[{"source":"S1","path":"made/up/path.md","reason":"Mô tả tính năng QR"},
                {"source":"S9","path":"ghost.md","reason":"không tồn tại"}],
 "changesFromBefore":[{"text":"Lùi ra mắt từ tháng 12 sang tháng 1","previousSource":"s2","timestamp":"00:01:00"},
                      {"text":"bịa","previousSource":"S5","timestamp":""}]}
"""

private let plainSummaryReply = """
{"title":"T","overview":"O","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[]}
"""

struct ContextSummaryTests {
    private let lines = [
        TranscriptLine(start: 10, end: 15, speaker: "Người khác", text: "Mình làm thanh toán QR nhé", track: .system),
        TranscriptLine(start: 60, end: 65, speaker: "Tôi", text: "Ok, ra mắt tháng 1", track: .mic),
    ]
    private let search = FakeSearch([
        chunk(1, "docs/payments.md", "Tính năng thanh toán QR cho khách hàng.", location: "Thanh toán > QR"),
        chunk(2, ".meetings/2026-11-01_09-00-00/summary.md", "Quyết định: ra mắt QR tháng 12.",
              meeting: Date(timeIntervalSince1970: 1_793_000_000)),
    ])

    private func pipeline(_ llm: LLMClient, withContext: Bool = true) -> SummaryPipeline {
        var p = SummaryPipeline(client: llm, model: "qwen3:8b", prompts: PromptStore.defaults,
                                myName: "Anh", language: .vietnamese)
        if withContext { p.retrieveContext = { [search] in await search.search($0) } }
        return p
    }

    @Test func shortMeetingSearchesWithNotesAndAddsLabelledContext() async throws {
        let llm = ScriptedLLM([notesReply, contextSummaryReply])
        _ = try await pipeline(llm).summarize(lines, duration: 120) { _, _ in }

        #expect(llm.prompts.count == 2) // quick notes, then the final summary
        #expect(search.queries.first == "Ra mắt QR vào tháng 1") // decisions first, then key points
        #expect(search.queries.contains("Thanh toán QR"))
        let final = try #require(llm.prompts.last)
        #expect(final.contains("PROJECT CONTEXT"))
        #expect(final.contains("[S1] tài liệu dự án · docs/payments.md — Thanh toán > QR"))
        #expect(final.contains("[S2] CUỘC HỌP KHÁC (mã 2026-11-01_09-00-00, ngày"))
        #expect(final.contains("nguồn DUY NHẤT"))
        #expect(llm.contextLengths.allSatisfy { $0 == 12_288 })
    }

    @Test func onlyRealSourcesSurviveAndPathsComeFromTheApp() async throws {
        let llm = ScriptedLLM([notesReply, contextSummaryReply])
        let summary = try await pipeline(llm).summarize(lines, duration: 120) { _, _ in }

        #expect(summary.relatedDocs == [RelatedDoc(source: "S1", path: "docs/payments.md", reason: "Mô tả tính năng QR")])
        #expect(summary.changesFromBefore.map(\.previousSource) == ["S2"])
        #expect(summary.keyPoints.first?.sourceRefs == ["S1"])     // S7 dropped
        #expect(summary.decisions.first?.sourceRefs == ["S2"])     // "[S2]" cleaned up
        #expect(summary.sources.map(\.path) == ["docs/payments.md", ".meetings/2026-11-01_09-00-00/summary.md"])
    }

    @Test func withoutContextNothingChangesFromPhase3() async throws {
        let llm = ScriptedLLM([plainSummaryReply])
        let summary = try await pipeline(llm, withContext: false).summarize(lines, duration: 120) { _, _ in }
        #expect(llm.prompts.count == 1)
        #expect(!llm.prompts[0].contains("PROJECT CONTEXT"))
        #expect(llm.contextLengths == [8_192])
        #expect(summary.relatedDocs.isEmpty && summary.sources.isEmpty)
    }

    @Test func contextIsKeptWithinTheTokenBudget() async throws {
        let big = String(repeating: "chữ ", count: 2_000) // far more than one source may use
        let many = FakeSearch((1...10).map { chunk(Int64($0), "docs/f\($0).md", big) })
        var p = SummaryPipeline(client: ScriptedLLM([]), model: "m", prompts: PromptStore.defaults,
                                myName: "", language: .vietnamese)
        p.retrieveContext = { await many.search($0) }
        let sources = await p.findContext(for: [ChunkNotes(keyPoints: [SummaryItem(text: "x")])])
        let used = sources.map { TranscriptChunker.estimateTokens(SummaryPipeline.describe($0)) }.reduce(0, +)
        #expect(!sources.isEmpty)
        #expect(used <= SummaryPipeline.contextTokenBudget)
        #expect(sources.map(\.label) == (1...sources.count).map { "S\($0)" })
    }

    @Test func oldPromptFilesWithoutPlaceholderStillGetContext() async throws {
        var prompts = PromptStore.defaults
        prompts.final = prompts.final.replacingOccurrences(of: "{{project_context}}", with: "")
        var p = SummaryPipeline(client: ScriptedLLM([notesReply, contextSummaryReply]), model: "m",
                                prompts: prompts, myName: "", language: .vietnamese)
        p.retrieveContext = { [search] in await search.search($0) }
        let llm = p.client as! ScriptedLLM
        _ = try await p.summarize(lines, duration: 60) { _, _ in }
        #expect(llm.prompts.last?.contains("[S1] tài liệu dự án · docs/payments.md") == true)
    }

    // MARK: Meeting identity

    private let identity = SummaryPipeline.MeetingIdentity(
        id: "2026-11-28_10-05-00", start: Date(timeIntervalSince1970: 1_795_860_300),
        projectName: "Payments", projectAbout: "Ví điện tử cho khách hàng cá nhân.")

    @Test func finalPromptNamesTheMeetingAndPutsItsTranscriptLast() async throws {
        let llm = ScriptedLLM([notesReply, contextSummaryReply])
        var p = pipeline(llm)
        p.meeting = identity
        let summary = try await p.summarize(lines, duration: 120) { _, _ in }

        let final = try #require(llm.prompts.last)
        #expect(final.contains("Mã cuộc họp: 2026-11-28_10-05-00"))
        #expect(final.contains("Thuộc dự án: Payments"))
        #expect(final.contains("Dự án \"Payments\" — tổng quan: Ví điện tử"))
        // Order: who → project reference → this meeting's own transcript.
        let header = try #require(final.range(of: "CUỘC HỌP CẦN TÓM TẮT"))
        let context = try #require(final.range(of: "<<< THAM KHẢO DỰ ÁN"))
        let start = try #require(final.range(of: "<<< BẮT ĐẦU CUỘC HỌP 2026-11-28_10-05-00"))
        let end = try #require(final.range(of: "<<< KẾT THÚC CUỘC HỌP 2026-11-28_10-05-00 >>>"))
        #expect(header.lowerBound < context.lowerBound && context.lowerBound < start.lowerBound)
        #expect(start.lowerBound < end.lowerBound)
        #expect(summary.meetingID == "2026-11-28_10-05-00" && summary.projectName == "Payments")
    }

    @Test func userPromptFileFromPhase3GetsHeaderAndContextBeforeTheTranscript() {
        let old = "Dưới đây là {{input_kind}}.\n\nJSON schema:\n{{schema}}\n\n{{input}}"
        let t = SummaryPipeline.upgradedTemplate(old)
        #expect(t.hasPrefix("{{meeting_header}}"))
        #expect(t.hasSuffix("{{project_context}}\n\n{{input}}"))
        #expect(SummaryPipeline.upgradedTemplate(PromptStore.defaults.final) == PromptStore.defaults.final)
    }

    @Test func otherMeetingsTranscriptsAndThisMeetingAreNeverContext() async throws {
        let mixed = FakeSearch([
            chunk(1, ".meetings/2026-11-01_09-00-00/transcript.md", "Người khác: nói chuyện khác"),
            chunk(2, ".meetings/2026-11-28_10-05-00/summary.md", "chính nó"),
            chunk(3, ".meetings/2026-11-01_09-00-00/summary.md", "Quyết định cũ"),
            chunk(4, "docs/a.md", "Tài liệu"),
        ])
        var p = SummaryPipeline(client: ScriptedLLM([]), model: "m", prompts: PromptStore.defaults,
                                myName: "", language: .vietnamese)
        p.meeting = identity
        p.retrieveContext = { await mixed.search($0) }
        let sources = await p.findContext(for: [ChunkNotes(keyPoints: [SummaryItem(text: "x")])])
        #expect(sources.map(\.chunk.path) == [".meetings/2026-11-01_09-00-00/summary.md", "docs/a.md"])
    }

    @Test func weakMatchesMeanNoProjectContext() {
        let chunks = [chunk(1, "docs/a.md", "x")]
        #expect(SummaryPipeline.relevantContext(SearchOutcome(chunks: chunks, bestSimilarity: 0.40, keywordHits: 3)).isEmpty)
        #expect(SummaryPipeline.relevantContext(SearchOutcome(chunks: chunks, bestSimilarity: 0.61, keywordHits: 0)) == chunks)
        // No vectors (embedding model missing): keyword results are still used.
        #expect(SummaryPipeline.relevantContext(SearchOutcome(chunks: chunks, bestSimilarity: nil, keywordHits: 1)) == chunks)
    }
}

struct ContextSummaryWriterTests {
    @Test func rendersNewSectionsWithRelativeLinksAndSkipsEmptyOnes() throws {
        let sources = [
            ContextSource(label: "S1", path: "docs/my plan.md", location: "", meetingDate: nil),
            ContextSource(label: "S2", path: ".meetings/2026-11-01_09-00-00/summary.md", location: "", meetingDate: nil),
        ]
        let summary = MeetingSummary(
            title: "T", overview: "O",
            decisions: [SummaryItem(text: "Ra mắt tháng 1", timestamp: "00:01:00", sourceRefs: ["S2"])],
            relatedDocs: [RelatedDoc(source: "S1", path: "docs/my plan.md", reason: "Kế hoạch gốc")],
            changesFromBefore: [ChangeFromBefore(text: "Lùi sang tháng 1", previousSource: "S2", timestamp: "00:01:00")],
            sources: sources)
        let md = SummaryWriter.markdown(summary, meetingStart: Date(), duration: 60, projectName: "P",
                                        language: .vietnamese)
        #expect(md.contains("## Liên quan tới tài liệu\n\n- [docs/my plan.md](../../docs/my%20plan.md) — Kế hoạch gốc"))
        #expect(md.contains("## Thay đổi so với trước\n\n- Lùi sang tháng 1 · [00:01:00] — trước đây: [2026-11-01_09-00-00/summary.md](../../.meetings/2026-11-01_09-00-00/summary.md)"))
        #expect(md.contains("- Ra mắt tháng 1 · [00:01:00] (xem: [2026-11-01_09-00-00/summary.md]"))

        let plain = SummaryWriter.markdown(MeetingSummary(title: "T", overview: "O"), meetingStart: Date(),
                                           duration: 60, projectName: "P", language: .vietnamese)
        #expect(!plain.contains("Liên quan tới tài liệu") && !plain.contains("Thay đổi so với trước"))
        #expect(!plain.contains("mã cuộc họp"))

        let named = SummaryWriter.markdown(MeetingSummary(title: "T", overview: "O", meetingID: "2026-11-28_10-05-00"),
                                           meetingStart: Date(), duration: 60, projectName: "P", language: .vietnamese)
        #expect(named.contains("· P · mã cuộc họp `2026-11-28_10-05-00`"))
    }

    @Test func decodesSummaryJSONWithAndWithoutNewFields() throws {
        let old = try SummarySchema.parse(MeetingSummary.self, from: #"{"title":"T","overview":"O"}"#)
        #expect(old.relatedDocs.isEmpty && old.changesFromBefore.isEmpty && old.sources.isEmpty)
        let new = try SummarySchema.parse(MeetingSummary.self, from: contextSummaryReply)
        #expect(new.relatedDocs.count == 2 && new.changesFromBefore.count == 2) // validation happens later
    }
}
