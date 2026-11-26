import SwiftUI

/// Recent meeting in the popover: water dot, title, relative time, mono duration.
/// Hover = foam background.
struct MeetingRow: View {
    let title: String
    let start: Date
    let duration: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.water)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .typeStyle(.bodyMedium)
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    Text(verbatim: LangFormat.relative(start))
                        .typeStyle(.caption)
                        .foregroundStyle(.ink2)
                }
                Spacer(minLength: 8)
                Text(verbatim: LangFormat.shortDuration(duration))
                    .typeStyle(.monoSmall)
                    .foregroundStyle(.ink3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(HoverRowStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Mở cuộc họp")
    }
}

#Preview("MeetingRow") {
    VStack(alignment: .leading, spacing: 2) {
        SectionLabel("gần đây").padding(.leading, 8).padding(.bottom, 4)
        ForEach(SampleData.recentMeetings) { meeting in
            MeetingRow(title: meeting.title, start: meeting.start, duration: meeting.duration) {}
        }
    }
    .padding(16)
    .frame(width: 320)
    .background(.white)
}
