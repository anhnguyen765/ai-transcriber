import SwiftUI

/// "Đã lắng xong" toast shown when a meeting finishes processing.
struct DoneToast: View {
    let title: String
    let actionItemCount: Int
    let onView: () -> Void

    private var detail: String {
        actionItemCount > 0
            ? String(localized: "\(title) · \(actionItemCount) việc cần làm")
            : title
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.moss)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text("Đã lắng xong")
                    .typeStyle(.bodyMedium)
                    .foregroundStyle(.ink)
                Text(verbatim: detail)
                    .typeStyle(.caption)
                    .foregroundStyle(.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Xem", action: onView)
                .buttonStyle(.lang(.primary, radius: Theme.Radius.pill))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.callout, style: .continuous)
            .fill(Color.foam.opacity(0.85)))
        .accessibilityElement(children: .contain)
    }
}

#Preview("DoneToast") {
    DoneToast(title: SampleData.meetingTitle, actionItemCount: 3) {}
        .padding(16)
        .frame(width: 320)
        .background(.white)
}
