import AppKit
import SwiftUI

/// One meeting folder in the library.
struct MeetingInfo: Identifiable, Equatable {
    var id: String { folder.path }
    let folder: URL
    let date: Date
    let title: String
    let duration: Double
    let status: MeetingMeta.Status?
    let hasTranscript: Bool
    let hasSummary: Bool

    var statusText: String {
        switch status {
        case .recording?: "Đang ghi"
        case .recorded?: "Đã ghi"
        case .transcribing?: "Đang chép lời"
        case .transcribed?: "Đã chép lời"
        case .failed?: "Lỗi chép lời"
        case .summarizing?: "Đang tóm tắt"
        case .summarized?: "Đã tóm tắt"
        case .summaryFailed?: "Lỗi tóm tắt"
        case nil: "—"
        }
    }
}

/// Reading, searching and exporting the meetings of a project (no UI).
enum MeetingLibrary {
    /// Every <project>/.meetings/<timestamp>/ with a meta.json, newest first.
    static func load(projectFolder: URL) -> [MeetingInfo] {
        let root = projectFolder.appending(path: ".meetings", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let meta = try? MeetingMeta.load(from: folder) else { return nil } // skips chats/, glossary.txt
            let summary = (try? Data(contentsOf: folder.appending(path: SummaryWriter.jsonFileName)))
                .flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: $0) }
            let fallbackTitle = meta.sourceFile.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? "Cuộc họp"
            return MeetingInfo(
                folder: folder, date: meta.startTime, title: summary?.title ?? fallbackTitle,
                duration: meta.durationSeconds, status: meta.status,
                hasTranscript: FileManager.default.fileExists(atPath: folder.appending(path: TranscriptWriter.markdownFileName).path),
                hasSummary: FileManager.default.fileExists(atPath: folder.appending(path: SummaryWriter.markdownFileName).path))
        }
        .sorted { $0.date > $1.date }
    }

    /// Meetings matching `query`, best first: FTS5 over the indexed summaries and transcripts,
    /// or (without an index) a plain accent-insensitive text scan.
    static func search(_ query: String, in meetings: [MeetingInfo], store: IndexStore?) -> [MeetingInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return meetings }
        let byName = Dictionary(meetings.map { ($0.folder.lastPathComponent, $0) }) { a, _ in a }
        var ordered: [MeetingInfo] = []
        var seen = Set<String>()

        if let store, let ids = try? store.keywordSearch(trimmed, limit: 300, filter: SearchFilter(sourceTypes: [.meeting])),
           let chunks = try? store.chunks(ids: ids) {
            let pathByID = Dictionary(chunks.compactMap { c in c.id.map { ($0, c.path) } }) { a, _ in a }
            for id in ids {
                guard let path = pathByID[id] else { continue }
                let parts = path.split(separator: "/")
                guard parts.count >= 2, let meeting = byName[String(parts[1])],
                      seen.insert(meeting.id).inserted else { continue }
                ordered.append(meeting)
            }
        }
        // Titles always count, and the text scan covers meetings that aren't indexed yet.
        let needle = TranscriptMerger.normalize(trimmed)
        for meeting in meetings where !seen.contains(meeting.id) {
            var haystack = meeting.title
            if store == nil {
                for name in [SummaryWriter.markdownFileName, TranscriptWriter.markdownFileName] {
                    haystack += " " + ((try? String(contentsOf: meeting.folder.appending(path: name), encoding: .utf8)) ?? "")
                }
            }
            if TranscriptMerger.normalize(haystack).contains(needle) {
                seen.insert(meeting.id)
                ordered.append(meeting)
            }
        }
        return ordered
    }

    /// One shareable Markdown file: the summary, then the transcript.
    static func exportMarkdown(_ meeting: MeetingInfo) throws -> String {
        let read = { (name: String) in try? String(contentsOf: meeting.folder.appending(path: name), encoding: .utf8) }
        let summary = read(SummaryWriter.markdownFileName)
        let transcript = read(TranscriptWriter.markdownFileName)
        guard summary != nil || transcript != nil else {
            throw RecorderError("This meeting has no summary or transcript yet.")
        }
        var parts: [String] = []
        if let summary { parts.append(summary.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let transcript {
            // The transcript's own "# Cuộc họp …" title becomes a section heading.
            let body = transcript.replacingOccurrences(of: #"^# .*\n"#, with: "", options: .regularExpression)
            parts.append("## Bản chép lời\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.joined(separator: "\n\n---\n\n") + "\n"
    }

    static func exportFileName(_ meeting: MeetingInfo) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let title = meeting.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(f.string(from: meeting.date)) \(title).md"
    }
}
