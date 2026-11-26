import Foundation

/// A question turned into something the search can use.
struct RewrittenQuery: Codable, Equatable {
    /// Standalone search text (follow-ups like "còn ai phụ trách?" get the missing subject).
    var query: String
    /// Meeting dates implied by the question ("tuần trước", "hôm qua"), as yyyy-MM-dd; nil if none.
    var meetingsFrom: String?
    var meetingsTo: String?

    /// [from, to) as dates; `to` is the day after meetingsTo so the whole last day is included.
    func dateRange(calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        let from = meetingsFrom.flatMap(Self.dayFormatter.date)
        let toDay = meetingsTo.flatMap(Self.dayFormatter.date)
        let to = toDay.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        if let from, let to, from >= to { return (nil, nil) } // nonsense range: ignore it
        return (from, to)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Rewrites a chat question into a standalone search query using the last 3 turns (short LLM call).
struct QueryRewriter {
    static let historyTurns = 3
    /// Words that suggest a time range; without history and without these, no LLM call is needed.
    static let timeWords = ["hôm", "tuần", "tháng", "năm", "qua", "trước", "nay", "sáng", "chiều", "mai",
                            "yesterday", "today", "week", "month", "year", "last", "ago", "recent"]

    let client: LLMClient
    let model: String

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string"],
            // Plain strings ("" = no date): simpler for Ollama's grammar than a string-or-null union.
            "meetingsFrom": ["type": "string"],
            "meetingsTo": ["type": "string"],
        ],
        "required": ["query", "meetingsFrom", "meetingsTo"],
    ]

    /// Never throws: if anything goes wrong, the question itself is the query.
    func rewrite(question: String, history: [(question: String, answer: String)],
                 today: Date = Date()) async -> RewrittenQuery {
        let plain = RewrittenQuery(query: question, meetingsFrom: nil, meetingsTo: nil)
        let recent = Array(history.suffix(Self.historyTurns))
        let lower = question.lowercased()
        guard !recent.isEmpty || Self.timeWords.contains(where: lower.contains) else { return plain }

        let options = LLMChatOptions(model: model, jsonSchema: Self.schema, contextLength: 4_096,
                                     temperature: 0, keepAlive: "5m")
        guard let reply = try? await client.chat(
            messages: [.system(Self.systemPrompt), .user(Self.prompt(question: question, history: recent, today: today))],
            options: options, onProgress: { _ in }),
            var result = try? SummarySchema.parse(RewrittenQuery.self, from: reply)
        else { return plain }

        result.query = result.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.query.isEmpty { result.query = question }
        // Keep only well-formed dates.
        if result.meetingsFrom.flatMap(RewrittenQuery.dayFormatter.date) == nil { result.meetingsFrom = nil }
        if result.meetingsTo.flatMap(RewrittenQuery.dayFormatter.date) == nil { result.meetingsTo = nil }
        return result
    }

    static let systemPrompt = """
    Bạn chuyển câu hỏi của người dùng thành câu tìm kiếm cho một kho tài liệu và biên bản họp của dự án.
    Chỉ trả lời bằng JSON đúng schema.
    """

    static func prompt(question: String, history: [(question: String, answer: String)], today: Date) -> String {
        let weekday = weekdayFormatter.string(from: today)
        var text = "Hôm nay là \(weekday), \(RewrittenQuery.dayFormatter.string(from: today)).\n\n"
        if !history.isEmpty {
            text += "Các lượt hỏi đáp gần đây:\n"
            for turn in history {
                text += "- Hỏi: \(turn.question)\n  Đáp: \(turn.answer.prefix(400))\n"
            }
            text += "\n"
        }
        text += """
        Câu hỏi mới: \(question)

        Hãy trả về:
        - query: câu tìm kiếm ĐỘC LẬP (tự hiểu được không cần lịch sử), giữ nguyên tên riêng và thuật ngữ, bỏ các từ chỉ thời gian. Cùng ngôn ngữ với câu hỏi.
        - meetingsFrom, meetingsTo: nếu câu hỏi nói tới một khoảng thời gian (ví dụ "tuần trước", "hôm qua", "tháng này"), ghi ngày bắt đầu và ngày kết thúc dạng yyyy-MM-dd (tuần bắt đầu từ thứ Hai). Nếu không có thì để chuỗi rỗng "".

        JSON schema:
        \(SummarySchema.text(schema))
        """
        return text
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "EEEE"
        return f
    }()
}
