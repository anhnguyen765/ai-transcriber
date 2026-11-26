import Foundation

/// One source shown to the model as [S#].
struct AnswerSource: Equatable, Codable, Identifiable {
    var id: String { label }
    var label: String          // "S1"
    var path: String           // relative to the project folder
    var location: String       // heading, time range or line range
    var sourceType: SourceType
    var meetingDate: Date?
    var preview: String        // text the model saw (also shown on hover in step b)
}

/// One question + answer in the Ask window.
struct ChatTurn: Identifiable, Equatable {
    enum Status: Equatable {
        case searching, answering, done, notFound, stopped
        case failed(String)
    }

    let id = UUID()
    var question: String
    var answer: String = ""
    var sources: [AnswerSource] = []
    var status: Status = .searching
    /// e.g. "Cuộc họp 2026-11-17 → 2026-11-23" when the question implied dates.
    var scopeNote: String?
}

/// RAG answering: rules, prompt, "not found" decision and citation parsing.
enum AnswerService {
    static let notFoundMessage = "Mình không tìm thấy thông tin này trong dự án."
    /// Below this best cosine similarity (bge-m3), the sources are considered unrelated.
    /// Calibrated on the 2027 project: related questions scored 0.58–0.70, unrelated ones 0.31–0.47.
    static let minSimilarity: Float = 0.52
    static let maxSourceCharacters = 1_500
    static let sourceCount = 8

    /// Skip the LLM when nothing relevant was found.
    static func isNotFound(_ outcome: SearchOutcome) -> Bool {
        if outcome.chunks.isEmpty { return true }
        if let best = outcome.bestSimilarity { return best < minSimilarity }
        return outcome.keywordHits == 0 // no vectors available: rely on keyword matches
    }

    static func sources(from chunks: [RetrievedChunk]) -> [AnswerSource] {
        chunks.prefix(sourceCount).enumerated().map { i, c in
            AnswerSource(label: "S\(i + 1)", path: c.path, location: c.location, sourceType: c.sourceType,
                         meetingDate: c.meetingDate, preview: String(c.text.prefix(maxSourceCharacters)))
        }
    }

    /// Reply used when nothing relevant was found, with the closest sources as hints.
    static func notFoundReply(closest: [AnswerSource], query: String) -> String {
        var text = notFoundMessage
        if !closest.isEmpty {
            text += "\n\nCác nguồn gần nhất (có thể không liên quan):\n"
            text += closest.prefix(3).map { "- [\($0.label)] \(describe($0))" }.joined(separator: "\n")
        }
        text += "\n\nThử hỏi lại với tên riêng, tên tính năng hoặc khoảng thời gian cụ thể hơn"
        text += query.isEmpty ? "." : " (mình đã tìm: “\(query)”)."
        return text
    }

    static let systemPrompt = """
    Bạn là trợ lý trả lời câu hỏi về một dự án, CHỈ dựa trên các nguồn [S1]…[S8] được cung cấp (tài liệu của dự án và biên bản/bản chép lời các cuộc họp).

    Quy tắc:
    - Trả lời bằng ngôn ngữ của câu hỏi (mặc định tiếng Việt, đúng dấu).
    - Mỗi thông tin phải kèm trích dẫn ngay sau nó, dạng [S2] (có thể nhiều: [S1][S3]).
    - Nếu các nguồn không chứa câu trả lời, nói đúng câu: "Mình không tìm thấy thông tin này trong dự án." và gợi ý nên tìm gì thay thế.
    - Không bao giờ bịa thông tin, tên người, con số hay ngày tháng.
    - Phân biệt rõ điều đã được NÓI trong cuộc họp (nguồn là cuộc họp, nêu ngày họp) với điều được VIẾT trong tài liệu.
    - Ngắn gọn, đi thẳng vào câu trả lời; dùng gạch đầu dòng khi có nhiều ý.
    """

    /// "cuộc họp 2026-11-25 · 00:03:00–00:06:00 · .meetings/…/transcript.md"
    static func describe(_ source: AnswerSource) -> String {
        var parts: [String] = []
        if source.sourceType == .meeting, let date = source.meetingDate {
            parts.append("cuộc họp \(dateFormatter.string(from: date))")
        } else {
            parts.append(source.sourceType == .code ? "code" : "tài liệu")
        }
        if !source.location.isEmpty { parts.append(source.location) }
        parts.append(source.path)
        return parts.joined(separator: " · ")
    }

    static func messages(question: String, sources: [AnswerSource],
                         history: [(question: String, answer: String)]) -> [LLMMessage] {
        var user = "Nguồn:\n\n"
        user += sources.map { "[\($0.label)] \(describe($0))\n\($0.preview)" }.joined(separator: "\n\n")
        if !history.isEmpty {
            user += "\n\nCác lượt hỏi đáp trước (chỉ để hiểu ngữ cảnh, KHÔNG phải nguồn):\n"
            user += history.suffix(QueryRewriter.historyTurns)
                .map { "- Hỏi: \($0.question)\n  Đáp: \($0.answer.prefix(300))" }
                .joined(separator: "\n")
        }
        user += "\n\nCâu hỏi: \(question)"
        return [.system(systemPrompt), .user(user)]
    }

    /// Labels cited in an answer, in order of first appearance: "… [S2] … [S1][S2]" → ["S2", "S1"].
    static func citations(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(S\d{1,2})\]"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let label = String(text[range])
            return seen.insert(label).inserted ? label : nil
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Chat history as Markdown (<project>/.meetings/chats/<yyyy-MM-dd_HH-mm>.md)

enum ChatExport {
    static func folder(projectFolder: URL) -> URL {
        projectFolder.appending(path: ".meetings/chats", directoryHint: .isDirectory)
    }

    static func newFileURL(projectFolder: URL, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        var url = folder(projectFolder: projectFolder).appending(path: "\(f.string(from: date)).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { // two chats in the same minute
            url = folder(projectFolder: projectFolder).appending(path: "\(f.string(from: date))-\(n).md")
            n += 1
        }
        return url
    }

    static func markdown(_ turns: [ChatTurn], projectName: String, started: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var md = "# Hỏi lắng — \(f.string(from: started))\n\nProject: \(projectName)\n"
        for turn in turns where turn.status != .searching && turn.status != .answering {
            md += "\n## Hỏi\n\n\(turn.question)\n\n## Trả lời\n\n\(turn.answer.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            if !turn.sources.isEmpty {
                md += "\n### Nguồn\n\n"
                md += turn.sources.map { "- [\($0.label)] \(AnswerService.describe($0))" }.joined(separator: "\n")
                md += "\n"
            }
        }
        return md
    }

    /// Reads a saved chat back (question, answer and source lines) for the sidebar.
    static func parse(_ markdown: String) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for block in markdown.components(separatedBy: "\n## Hỏi\n").dropFirst() {
            let parts = block.components(separatedBy: "\n## Trả lời\n")
            guard parts.count == 2 else { continue }
            let answerParts = parts[1].components(separatedBy: "\n### Nguồn\n")
            var turn = ChatTurn(question: parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
            turn.answer = answerParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            turn.status = turn.answer.hasPrefix(AnswerService.notFoundMessage) ? .notFound : .done
            if answerParts.count > 1 {
                turn.sources = answerParts[1].components(separatedBy: .newlines).compactMap(parseSourceLine)
            }
            turns.append(turn)
        }
        return turns
    }

    /// "- [S2] cuộc họp 2026-11-25 · 00:03:00–00:06:00 · .meetings/x/transcript.md"
    private static func parseSourceLine(_ line: String) -> AnswerSource? {
        guard line.hasPrefix("- ["), let close = line.firstIndex(of: "]") else { return nil }
        let label = String(line[line.index(line.startIndex, offsetBy: 3)..<close])
        let parts = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " · ")
        guard let path = parts.last else { return nil }
        let isMeeting = parts.first?.hasPrefix("cuộc họp ") == true
        let date = isMeeting ? AnswerService.dateFormatter.date(from: String(parts[0].dropFirst("cuộc họp ".count))) : nil
        let location = parts.count == 3 ? parts[1] : ""
        let type: SourceType = isMeeting ? .meeting : (parts.first == "code" ? .code : .doc)
        return AnswerSource(label: label, path: path, location: location, sourceType: type,
                            meetingDate: date, preview: "")
    }
}
