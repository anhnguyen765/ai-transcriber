import Foundation

/// Writes summary.md (for reading) and summary.json (raw, for later phases).
enum SummaryWriter {
    static let markdownFileName = "summary.md"
    static let jsonFileName = "summary.json"

    enum Language: String {
        case vietnamese = "vi", english = "en"
    }

    @discardableResult
    static func write(_ summary: MeetingSummary, meetingStart: Date, duration: Double, projectName: String,
                      language: Language, to folder: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary).write(to: folder.appending(path: jsonFileName))

        let url = folder.appending(path: markdownFileName)
        try markdown(summary, meetingStart: meetingStart, duration: duration, projectName: projectName,
                     language: language).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func markdown(_ s: MeetingSummary, meetingStart: Date, duration: Double, projectName: String,
                         language: Language) -> String {
        let vi = language == .vietnamese
        let minutes = max(1, Int((duration / 60).rounded()))
        let none = vi ? "_Không có._" : "_None._"

        func stamp(_ timestamp: String) -> String {
            timestamp.isEmpty ? "" : " · [\(timestamp)]"
        }
        let sourcesByLabel = Dictionary(s.sources.map { ($0.label, $0) }) { first, _ in first }
        /// " (xem: [plan.md](../../docs/plan.md))" for a point's optional sourceRefs.
        func refs(_ item: SummaryItem) -> String {
            let links = (item.sourceRefs ?? []).compactMap { sourcesByLabel[$0] }.map { link(to: $0.path) }
            return links.isEmpty ? "" : " (\(vi ? "xem" : "see"): \(links.joined(separator: ", ")))"
        }
        func section(_ title: String, _ items: [SummaryItem]) -> String {
            let body = items.isEmpty
                ? none
                : items.map { "- \($0.text)\(stamp($0.timestamp))\(refs($0))" }.joined(separator: "\n")
            return "## \(title)\n\n\(body)\n\n"
        }

        var md = "# \(s.title)\n\n"
        md += "\(dateFormatter.string(from: meetingStart)) · \(minutes) \(vi ? "phút" : "min") · \(projectName)"
        if let id = s.meetingID { md += " · \(vi ? "mã cuộc họp" : "meeting") `\(id)`" }
        md += "\n\n"
        md += "## \(vi ? "Tóm tắt" : "Summary")\n\n\(s.overview)\n\n"
        md += section(vi ? "Điểm chính" : "Key points", s.keyPoints)
        md += section(vi ? "Quyết định" : "Decisions", s.decisions)

        md += "## \(vi ? "Việc cần làm" : "Action items")\n\n"
        md += s.actionItems.isEmpty ? none : s.actionItems
            .map { "- [ ] \($0.task) — \($0.owner) — \($0.deadline)\(stamp($0.timestamp))" }
            .joined(separator: "\n")
        md += "\n\n"

        md += section(vi ? "Câu hỏi mở" : "Open questions", s.openQuestions)

        // Phase 4 sections, only when there is something to show.
        if !s.relatedDocs.isEmpty {
            md += "## \(vi ? "Liên quan tới tài liệu" : "Related documents")\n\n"
            md += s.relatedDocs.map { "- \(link(to: $0.path))\($0.reason.isEmpty ? "" : " — \($0.reason)")" }
                .joined(separator: "\n")
            md += "\n\n"
        }
        if !s.changesFromBefore.isEmpty {
            md += "## \(vi ? "Thay đổi so với trước" : "Changes from before")\n\n"
            md += s.changesFromBefore.map { change in
                let previous = sourcesByLabel[change.previousSource].map {
                    " — \(vi ? "trước đây" : "previously"): \(link(to: $0.path))"
                } ?? ""
                return "- \(change.text)\(stamp(change.timestamp))\(previous)"
            }.joined(separator: "\n")
            md += "\n\n"
        }
        return md
    }

    /// A Markdown link from summary.md (in .meetings/<timestamp>/) to a project file.
    static func link(to projectPath: String) -> String {
        let name = (projectPath as NSString).lastPathComponent
        let title = projectPath.hasPrefix(".meetings/")
            ? projectPath.split(separator: "/").dropFirst().first.map { "\($0)/\(name)" } ?? name
            : projectPath
        let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectPath
        return "[\(title)](../../\(encoded))"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
