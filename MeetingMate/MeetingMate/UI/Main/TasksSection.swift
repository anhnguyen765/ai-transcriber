import SwiftUI

/// "Việc của tôi": my unchecked action items across the project's meetings.
/// Ticking one saves it to that meeting's summary.json; the item then leaves the list.
struct TasksSection: View {
    @Bindable var app: AppState
    @State private var tasks: [MeetingList.OpenTask] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Việc của tôi")
                .typeStyle(TypeStyle(family: .serif(italic: false), size: 28))
                .foregroundStyle(.ink)
            Text(verbatim: "\(tasks.count) việc chưa xong")
                .typeStyle(.caption)
                .foregroundStyle(.ink2)

            if tasks.isEmpty {
                Text("Không có việc nào đang chờ bạn. Việc có người phụ trách là “bạn”, “tôi” hoặc tên bạn trong Cài đặt sẽ hiện ở đây.")
                    .typeStyle(.body)
                    .foregroundStyle(.ink3)
                    .frame(maxWidth: 520, alignment: .leading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(tasks) { task in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: task.meetingTitle)
                                .typeStyle(.caption)
                                .foregroundStyle(.ink3)
                            ActionItemRow(text: task.item.task,
                                          isDone: Binding(get: { false },
                                                          set: { done in if done { tick(task) } }),
                                          owner: ownerText(task.item),
                                          ownerIsMe: true,
                                          seconds: LangFormat.seconds(fromClock: task.item.timestamp)) { seconds in
                                app.router.openMeeting(task.folder, at: seconds)
                            }
                        }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: reload)
        .onChange(of: app.meetings) { _, _ in reload() }
    }

    private func reload() {
        tasks = MeetingList.myOpenTasks(in: app.meetings, title: app.displayTitle)
    }

    private func tick(_ task: MeetingList.OpenTask) {
        MeetingList.setActionItemDone(folder: task.folder, index: task.index, done: true)
        app.refreshMeetings()
        reload()
    }

    private func ownerText(_ item: ActionItem) -> String? {
        guard item.owner != ActionItem.unknown else { return nil }
        guard item.deadline != ActionItem.unknown else { return item.owner }
        return "\(item.owner) · \(item.deadline)"
    }
}
