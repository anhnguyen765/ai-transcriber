import SwiftUI

/// "quyết định" row: 10 pt water diamond + text + timestamp.
struct DecisionRow: View {
    let text: String
    let seconds: Double?
    var onTimestamp: (Double) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Rectangle()
                .fill(.water)
                .frame(width: 7, height: 7) // ≈ 10 pt corner to corner once rotated
                .rotationEffect(.degrees(45))
                .frame(width: 10, height: 10)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(verbatim: text)
                .typeStyle(.ui(14, lineHeight: 20))
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let seconds { TimestampChip(seconds: seconds) { onTimestamp(seconds) } }
        }
    }
}

/// "việc cần làm" row: checkbox, text, owner pill, timestamp.
struct ActionItemRow: View {
    let text: String
    @Binding var isDone: Bool
    let owner: String?
    let ownerIsMe: Bool
    let seconds: Double?
    var onTimestamp: (Double) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? Theme.Motion.fade : Theme.Motion.standard) { isDone.toggle() }
            } label: {
                Checkbox(isOn: isDone)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Bỏ đánh dấu xong" : "Đánh dấu xong")

            Text(verbatim: text)
                .typeStyle(.ui(14, lineHeight: 20))
                .foregroundStyle(isDone ? Color.ink3 : .ink)
                .strikethrough(isDone, color: .ink3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let owner { OwnerPill(text: owner, isMe: ownerIsMe) }
            if let seconds { TimestampChip(seconds: seconds) { onTimestamp(seconds) } }
        }
    }
}

/// 17 pt checkbox, radius 5. Checked = water fill + white check.
struct Checkbox: View {
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.checkbox, style: .continuous)
        ZStack {
            shape.fill(isOn ? Color.water : .white)
            shape.strokeBorder(isOn ? Color.water : .ink3.opacity(0.6), lineWidth: 1.2)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 17, height: 17)
        .contentShape(Rectangle())
    }
}

/// "thay đổi so với trước" callout on sand 45 %.
struct ChangeCallout: View {
    let text: String
    var sourceTitle: String?
    var sourceNumber: String?
    var onSource: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("thay đổi so với trước", color: .sandInk)
                Text(verbatim: text)
                    .typeStyle(.ui(14, .medium, lineHeight: 20))
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let sourceTitle {
                SourceChip(number: sourceNumber, icon: "doc.text", title: sourceTitle, action: onSource)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.callout, style: .continuous)
            .fill(Color.sand.opacity(0.45)))
    }
}

#Preview("Summary rows") {
    @Previewable @State var done = SampleData.actionItems.map(\.done)
    VStack(alignment: .leading, spacing: 18) {
        ChangeCallout(text: SampleData.change, sourceTitle: SampleData.changeSource, sourceNumber: "S1")
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("quyết định")
            ForEach(SampleData.decisions, id: \.text) { DecisionRow(text: $0.text, seconds: $0.time) }
        }
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("việc cần làm")
            ForEach(SampleData.actionItems.indices, id: \.self) { i in
                let item = SampleData.actionItems[i]
                ActionItemRow(text: item.text, isDone: $done[i], owner: item.owner,
                              ownerIsMe: item.isMe, seconds: item.time)
            }
        }
    }
    .padding(36)
    .frame(width: 700)
    .background(.white)
}
