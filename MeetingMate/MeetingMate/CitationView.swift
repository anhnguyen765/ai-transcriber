import AppKit
import SwiftUI

/// Which meeting to show, and where to start (seconds from the meeting start).
struct MeetingRef: Codable, Hashable {
    var folderPath: String
    var time: Double
}

/// Where a source lives and how to open it.
enum SourceLink {
    static func fileURL(_ source: AnswerSource, projectFolder: URL) -> URL {
        projectFolder.appending(path: source.path)
    }

    /// ".meetings/2026-11-25_22-07-16/transcript.md" → ".meetings/2026-11-25_22-07-16"
    static func meetingFolder(_ source: AnswerSource) -> String? {
        let parts = source.path.split(separator: "/")
        guard source.sourceType == .meeting, parts.count >= 2, parts[0] == ".meetings" else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Where to start in the meeting: the chunk's time range, or the first [hh:mm:ss] in its text
    /// (summary chunks mention timestamps like "· [00:12:30]"), else the beginning.
    static func startTime(_ source: AnswerSource) -> Double {
        timestamp(in: source.location) ?? timestamp(in: source.preview) ?? 0
    }

    static func timestamp(in text: String) -> Double? {
        guard let match = text.range(of: #"\d{1,2}:\d{2}:\d{2}"#, options: .regularExpression) else { return nil }
        let parts = text[match].split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// Text for the hover tooltip: path, heading or meeting date, and a preview.
    static func tooltip(_ source: AnswerSource) -> String {
        var lines = [source.path]
        if source.sourceType == .meeting, let date = source.meetingDate {
            lines.append("Cuộc họp \(AnswerService.dateFormatter.string(from: date))")
        }
        if !source.location.isEmpty { lines.append(source.location) }
        let preview = source.preview.replacingOccurrences(of: "\n", with: " ").prefix(300)
        if !preview.isEmpty { lines.append("“\(preview)…”") }
        return lines.joined(separator: "\n")
    }

    /// A short label for a chip: file name, or the meeting date.
    static func shortName(_ source: AnswerSource) -> String {
        if source.sourceType == .meeting, let date = source.meetingDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "vi_VN")
            f.dateFormat = "dd/MM HH:mm"
            let time = SourceLink.timestamp(in: source.location).map { " · " + TranscriptWriter.timestamp($0) } ?? ""
            return "Họp \(f.string(from: date))\(time)"
        }
        return (source.path as NSString).lastPathComponent
    }
}

/// Answer text where every [S#] is a clickable, chip-styled citation.
struct CitationText: View {
    let text: String
    let sources: [AnswerSource]
    let open: (AnswerSource) -> Void

    var body: some View {
        Text(Self.attributed(text, labels: Set(sources.map(\.label))))
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "lang-source", let label = url.host(),
                      let source = sources.first(where: { $0.label == label }) else { return .systemAction }
                open(source)
                return .handled
            })
    }

    /// Markdown (bold, italics, links) with each known [S#] turned into a link "lang-source://S#".
    static func attributed(_ text: String, labels: Set<String>) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for label in labels {
            let needle = "[\(label)]"
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: needle) {
                result[range].link = URL(string: "lang-source://\(label)")
                result[range].foregroundColor = .accentColor
                result[range].backgroundColor = Color.accentColor.opacity(0.12)
                result[range].font = .caption.weight(.semibold)
                searchStart = range.upperBound
            }
        }
        return result
    }
}

/// The row of source chips under an answer. Cited sources come first; hover shows a preview.
struct LegacySourceChips: View {
    let answer: String
    let sources: [AnswerSource]
    let open: (AnswerSource) -> Void

    var body: some View {
        let cited = AnswerService.citations(in: answer)
        let ordered = sources.sorted { a, b in
            (cited.firstIndex(of: a.label) ?? 99, a.label.count, a.label) < (cited.firstIndex(of: b.label) ?? 99, b.label.count, b.label)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Nguồn · bấm để mở, ⌥-bấm để hiện trong Finder")
                .font(.caption2)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(ordered) { source in
                    LegacySourceChip(source: source, cited: cited.contains(source.label), open: open)
                }
            }
        }
    }
}

private struct LegacySourceChip: View {
    let source: AnswerSource
    let cited: Bool
    let open: (AnswerSource) -> Void

    var body: some View {
        Button { open(source) } label: {
            HStack(spacing: 4) {
                Text(source.label).fontWeight(.semibold)
                Image(systemName: source.sourceType == .meeting ? "waveform" : "doc.text")
                Text(SourceLink.shortName(source)).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(cited ? 0.15 : 0.05)))
            .foregroundStyle(cited ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(SourceLink.tooltip(source)) // hover: path, heading/date, preview
    }
}

/// Simple wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
