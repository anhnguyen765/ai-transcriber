#if DEBUG
import SwiftUI

/// All base components on one page (debug builds only). Used by the snapshot test
/// and handy as a single Xcode preview.
struct ComponentGallery: View {
    @State private var scope = 0
    @State private var done = SampleData.actionItems.map(\.done)

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            // Popover-sized column
            VStack(alignment: .leading, spacing: 14) {
                ProjectHeader(name: SampleData.projectName, subtitle: SampleData.projectSubtitle,
                              status: .indexed) { EmptyView() }
                ProjectHeader(name: SampleData.projectName, subtitle: "đang ghi vào .meetings",
                              status: .recording) { EmptyView() }
                Text("Ghi âm").typeStyle(.recordCaption).foregroundStyle(.ink)
                Text("đang lắng…").typeStyle(.settlingCaption).foregroundStyle(.deep)
                Text(verbatim: "00:12:48").typeStyle(.timer).foregroundStyle(.ink)
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("gần đây").padding(.leading, 8).padding(.bottom, 4)
                    ForEach(SampleData.recentMeetings) {
                        MeetingRow(title: $0.title, start: $0.start, duration: $0.duration) {}
                    }
                }
                DoneToast(title: SampleData.meetingTitle, actionItemCount: 3) {}
                HStack {
                    Button("Tạm dừng") {}.buttonStyle(.lang(.secondary, fullWidth: true))
                    Button("Dừng & lưu") {}.buttonStyle(.lang(.record, fullWidth: true))
                }
                HStack {
                    Button("Mở lắng ⌘O") {}.buttonStyle(.lang(.pill, radius: Theme.Radius.pill))
                    Button("Hỏi ⌃⌥␣") {}.buttonStyle(.lang(.pill, radius: Theme.Radius.pill))
                    KeyCap("esc")
                }
            }
            .padding(16)
            .frame(width: 320)
            .panelBackground(radius: Theme.Radius.popover)

            // Main-window column
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: LangFormat.meetingMeta(start: SampleData.recentMeetings[0].start,
                                                      length: 48 * 60 + 10, people: 4))
                    .typeStyle(.small).foregroundStyle(.ink2)
                Text(verbatim: SampleData.meetingTitle).typeStyle(.meetingTitle).foregroundStyle(.ink)
                TalkTimeBar(meShare: SampleData.meShare)
                Text(verbatim: SampleData.overview).typeStyle(.summary).foregroundStyle(.ink)
                    .frame(maxWidth: 630, alignment: .leading)
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
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("liên quan")
                    HStack(spacing: 6) {
                        ForEach(SampleData.related, id: \.label) {
                            SourceChip(number: $0.label, icon: $0.icon, title: $0.title) {}
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        ScopeChips(options: [(0, "cuộc họp này"), (1, "cả dự án")], selection: $scope)
                        SpeakerQuoteCard(speaker: SampleData.quote.speaker,
                                         meta: LangFormat.clock(SampleData.quote.time),
                                         quote: SampleData.quote.text) {}
                        SuggestionChip(text: "Ai lo phần beta?") {}
                    }
                    SpeakerQuoteCard(speaker: SampleData.quote.speaker, meta: "Sprint review · 26/11 · 31:40",
                                     quote: SampleData.quote.text, style: .foam) {}
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 22)
            .frame(width: 760)
            .background(.white)
        }
        .padding(24)
        .background(Color.mist)
    }
}

#Preview("Gallery") { ComponentGallery() }
#endif
