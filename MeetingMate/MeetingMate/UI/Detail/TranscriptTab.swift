import SwiftUI

/// "Bản ghi" tab: chat-like bubbles per line. Click a line to play from there.
/// ⌘F shows a find field; matches are highlighted. The line being played is highlighted too.
/// (Inline editing comes later.)
struct TranscriptTab: View {
    let model: MeetingDetailModel
    @ObservedObject var player: MeetingViewerModel
    @Binding var showFind: Bool
    @Binding var findText: String
    @FocusState private var findFocused: Bool
    /// The search actually applied: updated ~0.12 s after typing stops, so typing stays smooth.
    @State private var query = ""
    /// Indices of the lines that match `query`.
    @State private var matches: Set<Int> = []

    var body: some View {
        let current = player.currentLine
        VStack(alignment: .leading, spacing: 10) {
            if showFind {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.ink3)
                    TextField("Tìm trong bản ghi", text: $findText)
                        .textFieldStyle(.plain)
                        .typeStyle(.small)
                        .foregroundStyle(.ink)
                        .focused($findFocused)
                        .onExitCommand { close() }
                        .onSubmit { }
                    if !query.isEmpty {
                        Text(verbatim: "\(matches.count) kết quả")
                            .typeStyle(.caption)
                            .foregroundStyle(.ink3)
                    }
                    Button("Xong", action: close)
                        .buttonStyle(.plain)
                        .typeStyle(.caption)
                        .foregroundStyle(.deep)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.input, style: .continuous)
                    .strokeBorder(.line, lineWidth: Theme.hairline))
                .onAppear { findFocused = true }
                .task(id: findText) {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    query = findText
                    matches = findText.isEmpty ? []
                        : Set(model.lines.indices.filter { model.lines[$0].text.localizedStandardContains(findText) })
                }
            }

            if model.lines.isEmpty {
                Text("Cuộc họp này chưa có bản chép lời.")
                    .typeStyle(.body)
                    .foregroundStyle(.ink3)
            }
            ForEach(Array(model.lines.enumerated()), id: \.offset) { index, line in
                TranscriptBubble(line: line, query: matches.contains(index) ? query : "", playing: current == index,
                                 action: { player.seek(to: line.start, play: true) },
                                 save: { model.editLine(index, to: $0) })
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    private func close() {
        showFind = false
        findText = ""
    }
}

private struct TranscriptBubble: View {
    let line: TranscriptLine
    let query: String
    let playing: Bool
    let action: () -> Void
    let save: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    private var kind: SpeakerKind { SpeakerKind(track: line.track) }

    var body: some View {
        if editing {
            editor
        } else {
            row
        }
    }

    private var editor: some View {
        HStack(alignment: .top, spacing: 12) {
            TimestampChip(seconds: line.start) {}
                .allowsHitTesting(false)
                .padding(.top, 2)
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .typeStyle(.answer)
                .foregroundStyle(.ink)
                .onSubmit(commit)
                .onExitCommand { editing = false }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
                    .strokeBorder(Color.deep, lineWidth: 1))
        }
    }

    private func commit() {
        save(draft)
        editing = false
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                TimestampChip(seconds: line.start) {}
                    .allowsHitTesting(false)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: line.speaker)
                        .typeStyle(.ui(11, .medium))
                        .foregroundStyle(kind.tintInk)
                    Text(highlighted(line.text, query))
                        .typeStyle(.answer)
                        .foregroundStyle(.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
                    .fill(kind.tint.opacity(playing ? 1 : 0.55)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
                    .strokeBorder(Color.deep.opacity(playing ? 0.8 : 0), lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Nghe từ đoạn này")
        Button {
            draft = line.text
            editing = true
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 11))
                .foregroundStyle(.ink3)
                .padding(.top, 10)
        }
        .buttonStyle(.plain)
        .help("Sửa lời này")
        }
    }

    /// The text with every match of `query` highlighted (accent and case insensitive).
    private func highlighted(_ text: String, _ query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var start = attributed.startIndex
        while start < attributed.endIndex,
              let range = attributed[start...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].backgroundColor = Color.water.opacity(0.35)
            start = range.upperBound
        }
        return attributed
    }
}
