import Foundation
import Testing
@testable import MeetingMate

// MARK: - Helpers

private func line(_ start: Double, _ end: Double, _ speaker: TranscriptTrack, _ text: String) -> TranscriptLine {
    TranscriptLine(start: start, end: end, speaker: speaker.speaker, text: text, track: speaker)
}

/// Fake LLM: returns prepared replies in order and remembers what it was asked.
private final class MockLLMClient: LLMClient {
    var replies: [String]
    var prompts: [String] = []
    var running = true
    var models = ["qwen3:8b"]

    init(replies: [String]) { self.replies = replies }

    func isRunning() async -> Bool { running }
    func installedModels() async throws -> [String] { models }
    func pull(model: String, progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }
    func chat(messages: [LLMMessage], options: LLMChatOptions,
              onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        prompts.append(messages.last?.content ?? "")
        guard !replies.isEmpty else { throw LLMError.server("no more mock replies") }
        return replies.removeFirst()
    }
    func unload(model: String) async {}
}

/// Thread-safe list of (part, total) progress calls.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, Int)] = []
    func add(_ part: Int, _ total: Int) { lock.withLock { items.append((part, total)) } }
    var last: (Int, Int)? { lock.withLock { items.last } }
}

private let validSummary = """
{"title":"Kế hoạch ra mắt","overview":"Nhóm thống nhất lịch ra mắt.","keyPoints":[{"text":"Ra mắt tháng sau","timestamp":"00:01:00"}],
"decisions":[],"actionItems":[{"task":"Gửi báo giá","owner":"Minh","deadline":"Thứ Sáu","timestamp":"00:02:10"}],"openQuestions":[]}
"""
private let validNotes = """
{"keyPoints":[{"text":"Điểm A","timestamp":"00:00:10"}],"decisions":[],"actionItems":[],"openQuestions":[]}
"""

// MARK: - TranscriptChunker

struct TranscriptChunkerTests {
    @Test func formatsLinesAndReplacesMyLabelWithName() {
        #expect(TranscriptChunker.format(line(754, 760, .mic, "Ok"), myName: "Anh") == "[00:12:34] Anh: Ok")
        #expect(TranscriptChunker.format(line(5, 6, .system, "Chào"), myName: "Anh") == "[00:00:05] Người khác: Chào")
        #expect(TranscriptChunker.format(line(5, 6, .mic, "Chào"), myName: "  ") == "[00:00:05] Tôi: Chào")
    }

    @Test func splitsAboutEveryTenMinutesWithoutCuttingLines() {
        // 30 minutes, one line every 30 s.
        let lines = (0..<60).map { i in line(Double(i) * 30, Double(i) * 30 + 20, .system, "Câu số \(i)") }
        let chunks = TranscriptChunker.chunks(lines, myName: "Tôi")
        #expect(chunks.count == 3)
        // Every original line appears exactly once, whole and in order.
        let all = chunks.flatMap(\.lines)
        #expect(all == lines.map { TranscriptChunker.format($0, myName: "Tôi") })
        #expect(chunks.allSatisfy { $0.end - $0.start <= 600 })
    }

    @Test func respectsTokenLimitPerChunk() {
        let text = String(repeating: "lời nói dài ", count: 40) // ~480 chars ≈ 192 tokens
        let lines = (0..<50).map { i in line(Double(i) * 5, Double(i) * 5 + 4, .mic, text) }
        let chunks = TranscriptChunker.chunks(lines, myName: "Tôi", maxTokens: 1_000)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { TranscriptChunker.estimateTokens($0.text) <= 1_000 })
        #expect(chunks.flatMap(\.lines).count == 50) // nothing split, nothing lost
    }

    @Test func splitsOnlyAnOversizedSingleLineAtWords() {
        let words = (0..<2_000).map { "từ\($0)" }
        let chunks = TranscriptChunker.chunks([line(0, 600, .system, words.joined(separator: " "))],
                                              myName: "Tôi", maxTokens: 500)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { TranscriptChunker.estimateTokens($0.text) <= 500 })
        // Every word kept, each piece keeps the timestamp and speaker.
        let rejoined = chunks.flatMap(\.lines)
            .map { $0.replacingOccurrences(of: "[00:00:00] Người khác: ", with: "") }
            .joined(separator: " ")
        #expect(rejoined == words.joined(separator: " "))
    }
}

// MARK: - SummarySchema decoding

struct SummarySchemaTests {
    @Test func decodesValidJSON() throws {
        let summary = try SummarySchema.parse(MeetingSummary.self, from: validSummary)
        #expect(summary.title == "Kế hoạch ra mắt")
        #expect(summary.actionItems.first?.owner == "Minh")
    }

    @Test func toleratesTextAndCodeFencesAroundJSON() throws {
        let reply = "Đây là kết quả:\n```json\n\(validSummary)\n```"
        #expect(try SummarySchema.parse(MeetingSummary.self, from: reply).title == "Kế hoạch ra mắt")
    }

    @Test func missingListsBecomeEmptyAndOwnerDefaultsToUnknown() throws {
        let json = #"{"title":"T","overview":"O","actionItems":[{"task":"Làm X","owner":"","timestamp":"00:00:01"}]}"#
        let summary = try SummarySchema.parse(MeetingSummary.self, from: json)
        #expect(summary.keyPoints.isEmpty && summary.decisions.isEmpty && summary.openQuestions.isEmpty)
        #expect(summary.actionItems.first?.owner == "Chưa rõ")
        #expect(summary.actionItems.first?.deadline == "Chưa rõ")
    }

    @Test func missingRequiredFieldIsAnError() {
        #expect(throws: LLMError.self) {
            try SummarySchema.parse(MeetingSummary.self, from: #"{"overview":"no title"}"#)
        }
    }

    @Test func brokenJSONIsAnError() {
        #expect(throws: LLMError.self) {
            try SummarySchema.parse(MeetingSummary.self, from: #"{"title": "T", "overview": "#)
        }
        #expect(throws: LLMError.self) {
            try SummarySchema.parse(MeetingSummary.self, from: "Xin lỗi, tôi không thể.")
        }
    }
}

// MARK: - SummaryWriter

struct SummaryWriterTests {
    @Test func rendersAllSectionsAndChecklist() throws {
        let summary = try SummarySchema.parse(MeetingSummary.self, from: validSummary)
        let start = try #require(ISO8601DateFormatter().date(from: "2026-11-25T07:30:00Z"))
        var md = SummaryWriter.markdown(summary, meetingStart: start, duration: 2_530,
                                        projectName: "2027", language: .vietnamese)
        // Date line uses local time; check the parts that don't depend on the time zone.
        #expect(md.hasPrefix("# Kế hoạch ra mắt\n\n2026-11-25 "))
        #expect(md.contains(" · 42 phút · 2027\n"))
        for heading in ["## Tóm tắt", "## Điểm chính", "## Quyết định", "## Việc cần làm", "## Câu hỏi mở"] {
            #expect(md.contains(heading))
        }
        #expect(md.contains("- Ra mắt tháng sau · [00:01:00]"))
        #expect(md.contains("- [ ] Gửi báo giá — Minh — Thứ Sáu · [00:02:10]"))
        #expect(md.contains("## Quyết định\n\n_Không có._"))

        md = SummaryWriter.markdown(summary, meetingStart: start, duration: 2_530,
                                    projectName: "2027", language: .english)
        #expect(md.contains("## Action items") && md.contains(" · 42 min · "))
    }
}

// MARK: - Pipeline with a mock LLM

struct SummaryPipelineTests {
    private func pipeline(_ client: LLMClient) -> SummaryPipeline {
        SummaryPipeline(client: client, model: "qwen3:8b", prompts: PromptStore.defaults,
                        myName: "Anh", language: .vietnamese)
    }

    @Test func shortMeetingUsesOnePass() async throws {
        let mock = MockLLMClient(replies: [validSummary])
        let lines = [line(0, 5, .mic, "Chào mọi người"), line(6, 9, .system, "Chào anh")]
        let summary = try await pipeline(mock).summarize(lines, duration: 60) { _, _ in }
        #expect(summary.title == "Kế hoạch ra mắt")
        #expect(mock.prompts.count == 1)
        #expect(mock.prompts[0].contains("[00:00:00] Anh: Chào mọi người")) // my name, not "Tôi"
    }

    @Test func longMeetingUsesTwoPasses() async throws {
        // 40 minutes of dense talk → several parts.
        let text = String(repeating: "nội dung cuộc họp ", count: 20)
        let lines = (0..<240).map { i in line(Double(i) * 10, Double(i) * 10 + 9, i % 2 == 0 ? .mic : .system, text) }
        let parts = TranscriptChunker.chunks(lines, myName: "Anh", maxTokens: SummaryPipeline.chunkTokenLimit).count
        #expect(parts > 1)

        let mock = MockLLMClient(replies: Array(repeating: validNotes, count: parts) + [validSummary])
        let seen = ProgressLog()
        let summary = try await pipeline(mock).summarize(lines, duration: 2_400) { part, total in
            seen.add(part, total)
        }
        #expect(summary.title == "Kế hoạch ra mắt")
        #expect(mock.prompts.count == parts + 1)
        #expect(mock.prompts.last?.contains("Ghi chú từng phần") == true)
        #expect(seen.last.map { $0.0 == $0.1 && $0.1 == parts + 1 } == true) // ends at "part N/N"
    }

    @Test func retriesOnceWhenJSONIsBroken() async throws {
        let mock = MockLLMClient(replies: ["{ không phải json", validSummary])
        let summary = try await pipeline(mock).summarize([line(0, 2, .mic, "Xin chào")], duration: 30) { _, _ in }
        #expect(summary.title == "Kế hoạch ra mắt")
        #expect(mock.prompts.count == 2)
        #expect(mock.prompts[1].contains("không phải JSON hợp lệ"))
    }

    @Test func failsAfterSecondBrokenReply() async {
        let mock = MockLLMClient(replies: ["broken", "still broken"])
        await #expect(throws: LLMError.self) {
            _ = try await pipeline(mock).summarize([line(0, 2, .mic, "Xin chào")], duration: 30) { _, _ in }
        }
    }

    @Test func emptyTranscriptIsAnError() async {
        await #expect(throws: (any Error).self) {
            _ = try await pipeline(MockLLMClient(replies: [])).summarize([], duration: 0) { _, _ in }
        }
    }
}
