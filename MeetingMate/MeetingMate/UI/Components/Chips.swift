import SwiftUI

/// "▶ 31:40" on foam. Click → transcript at that line + play.
struct TimestampChip: View {
    let seconds: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                    .font(.system(size: 6))
                Text(verbatim: LangFormat.clock(seconds))
                    .typeStyle(.monoSmall)
            }
            .foregroundStyle(.deep)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.timestamp, style: .continuous).fill(.foam))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nghe từ \(LangFormat.clock(seconds))")
        .accessibilityLabel("Nghe từ \(LangFormat.clock(seconds))")
    }
}

/// A source: optional mono number tag ("S1" on foam) + icon + title.
struct SourceChip: View {
    var number: String?
    let icon: String
    let title: String
    var tooltip: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let number {
                    Text(verbatim: number)
                        .typeStyle(.monoTiny)
                        .foregroundStyle(.deep)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.timestamp - 1, style: .continuous)
                            .fill(.foam))
                }
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.ink2)
                Text(verbatim: title)
                    .typeStyle(.small)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .cardBackground(radius: Theme.Radius.chip)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip ?? title)
    }
}

/// Segmented scope picker made of chips. Selected = deep fill + white text.
struct ScopeChips<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(Theme.Motion.standard) { selection = option.value }
                } label: {
                    Text(verbatim: option.label)
                        .typeStyle(.ui(12, .medium))
                        .foregroundStyle(selected ? Color.white : .ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            if selected {
                                shape.fill(.deep)
                            } else {
                                shape.fill(.white).overlay(shape.strokeBorder(.line, lineWidth: Theme.hairline))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Owner + deadline pill: "bạn · 02/12" (foam/deep) or "Minh · 03/12" (sand/sandInk).
struct OwnerPill: View {
    let text: String
    let isMe: Bool

    var body: some View {
        let kind: SpeakerKind = isMe ? .me : .others
        Text(verbatim: text)
            .typeStyle(.ui(11, .medium))
            .foregroundStyle(kind.tintInk)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(kind.tint))
            .lineLimit(1)
    }
}

/// Suggestion chip with a dashed border (Ask inspector).
struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .typeStyle(.small)
                .foregroundStyle(.ink2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(.line, style: StrokeStyle(lineWidth: Theme.hairline, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Chips") {
    @Previewable @State var scope = 0
    VStack(alignment: .leading, spacing: 14) {
        HStack { TimestampChip(seconds: 31 * 60 + 40) {}; TimestampChip(seconds: 3725) {} }
        FlowLayout(spacing: 6) {
            ForEach(SampleData.related, id: \.label) { s in
                SourceChip(number: s.label, icon: s.icon, title: s.title) {}
            }
            SourceChip(icon: "doc.text", title: "Kế hoạch Q4.md") {}
        }
        ScopeChips(options: [(0, "cuộc họp này"), (1, "cả dự án")], selection: $scope)
        HStack { OwnerPill(text: "bạn · 02/12", isMe: true); OwnerPill(text: "Minh · 03/12", isMe: false) }
        SuggestionChip(text: "Ai lo phần beta?") {}
    }
    .padding(20)
    .frame(width: 420)
    .background(.white)
}
