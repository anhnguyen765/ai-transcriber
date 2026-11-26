import Foundation

/// Writes transcript.md (for reading) and transcript.json (for later phases: search, summaries).
enum TranscriptWriter {
    static let markdownFileName = "transcript.md"
    static let jsonFileName = "transcript.json"

    /// Returns the URL of transcript.md.
    @discardableResult
    static func write(_ lines: [TranscriptLine], meetingStart: Date, duration: Double,
                      projectName: String, to folder: URL) throws -> URL {
        // transcript.json
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let rounded = lines.map { line -> TranscriptLine in
            var copy = line
            copy.start = (line.start * 100).rounded() / 100
            copy.end = (line.end * 100).rounded() / 100
            return copy
        }
        try encoder.encode(rounded).write(to: folder.appending(path: jsonFileName))

        // transcript.md
        var md = "# Cuộc họp \(titleFormatter.string(from: meetingStart))\n\n"
        md += "Thời lượng: \(formatDuration(duration)) · Project: \(projectName)\n\n"
        if lines.isEmpty {
            md += "_(Không nhận ra lời nói nào.)_\n"
        }
        for line in lines {
            md += "[\(timestamp(line.start))] \(line.speaker): \(line.text)\n\n"
        }
        let url = folder.appending(path: markdownFileName)
        try md.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 125.4 → "00:02:05"
    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// 2530 → "42:10", 3725 → "1:02:05"
    static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
