import SwiftUI

// The Dự án section is a bento grid of tiles. Each tile has a small label, optional actions on the
// right of the label, and fills its grid cell so tiles in one row share the same height.

/// White card with a label row; fills the cell it is given.
struct BentoTile<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                SectionLabel(title)
                Spacer(minLength: 8)
                accessory
            }
            .frame(minHeight: 24)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(.line, lineWidth: Theme.hairline))
    }
}

extension BentoTile where Accessory == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// Grey "nothing here yet" text used inside tiles.
private struct TileEmptyText: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .typeStyle(.body)
            .foregroundStyle(.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Dự án này là gì

struct AboutTile: View {
    @Bindable var app: AppState
    private var model: ProjectOverviewModel { app.overview }

    var body: some View {
        BentoTile(title: "dự án này là gì") {
            HStack(spacing: 8) {
                if let overview = model.overview, !model.isWorking {
                    Text(verbatim: "cập nhật \(LangFormat.relative(overview.generatedAt))")
                        .typeStyle(.caption)
                        .foregroundStyle(.ink3)
                }
                if model.isWorking {
                    Button("Dừng") { model.stop() }
                        .buttonStyle(.lang(.pill))
                } else {
                    Button(model.overview == nil ? "Viết tổng quan" : "Cập nhật") {
                        model.refresh(store: app.indexer.store, projectName: app.projectName)
                    }
                    .buttonStyle(.lang(.pill))
                    .disabled(because: app.projectFolder == nil ? String(localized: "Chọn thư mục dự án trước.") : nil)
                }
            }
        } content: {
            if model.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.phase == .waitingForModel
                         ? "Đang chờ chép lời/tóm tắt xong…"
                         : "Đang đọc tài liệu và cuộc họp gần đây…")
                        .typeStyle(.small)
                        .foregroundStyle(.ink2)
                }
            }
            if let about = model.overview?.about, !about.isEmpty {
                Text(verbatim: about)
                    .typeStyle(.summary)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if !model.isWorking {
                TileEmptyText("Chưa có tổng quan. Bấm “Viết tổng quan” để lắng đọc tài liệu và các cuộc họp gần đây rồi tóm lại dự án.")
            }
            if model.isStale, !model.isWorking {
                Text("Có cuộc họp mới từ lần cập nhật trước. Bấm Cập nhật để xếp lại ưu tiên.")
                    .typeStyle(.caption)
                    .foregroundStyle(.sandInk)
            }
            if let note = model.note, !note.isEmpty {
                Text(verbatim: note)
                    .typeStyle(.caption)
                    .foregroundStyle(.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 3 ưu tiên

struct PrioritiesTile: View {
    @Bindable var app: AppState
    private var model: ProjectOverviewModel { app.overview }

    var body: some View {
        BentoTile(title: "3 ưu tiên") {
            let priorities = model.priorities
            if priorities.isEmpty {
                TileEmptyText("Chưa có việc nào từ các cuộc họp gần đây.")
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(priorities.enumerated()), id: \.offset) { index, priority in
                    row(index: index, priority: priority)
                }
            }
            if model.overview?.priorities.isEmpty ?? true, !priorities.isEmpty {
                Text("Lấy tạm từ việc cần làm. Bấm Cập nhật để lắng xếp hạng.")
                    .typeStyle(.caption)
                    .foregroundStyle(.ink3)
            }
        }
    }

    private func row(index: Int, priority: ProjectOverview.Priority) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(index + 1)")
                .typeStyle(.ui(12, .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(index == 0 ? Color.deep : .water))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: priority.title)
                    .typeStyle(.ui(14, .medium, lineHeight: 20))
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !priority.reason.isEmpty {
                    Text(verbatim: priority.reason)
                        .typeStyle(.small)
                        .foregroundStyle(.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let folder = meetingFolder(priority.meetingFolder) {
                    Button("Mở cuộc họp") { app.router.openMeeting(folder) }
                        .buttonStyle(.plain)
                        .typeStyle(.caption)
                        .foregroundStyle(.water)
                }
            }
        }
    }

    private func meetingFolder(_ name: String?) -> URL? {
        guard let name else { return nil }
        return model.recent.first { $0.folderName == name }?.folder
    }
}

// MARK: - Cập nhật gần đây

struct LatestMeetingsTile: View {
    @Bindable var app: AppState

    var body: some View {
        BentoTile(title: "cập nhật gần đây") {
            if app.overview.recent.isEmpty {
                TileEmptyText("Chưa có cuộc họp nào được tóm tắt.")
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(app.overview.recent, id: \.folder) { meeting in
                    Button {
                        app.router.openMeeting(meeting.folder)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: LangFormat.relative(meeting.date))
                                .typeStyle(.caption)
                                .foregroundStyle(.ink3)
                            Text(verbatim: meeting.summary.title)
                                .typeStyle(.bodyMedium)
                                .foregroundStyle(.ink)
                                .multilineTextAlignment(.leading)
                            Text(verbatim: meeting.summary.overview)
                                .typeStyle(.small)
                                .foregroundStyle(.ink2)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Mở cuộc họp")
                }
            }
        }
    }
}

// MARK: - Việc cần làm

struct OpenTasksTile: View {
    @Bindable var app: AppState

    var body: some View {
        BentoTile(title: "việc cần làm") {
            if !app.overview.openTasks.isEmpty {
                Text(verbatim: "\(app.overview.openTasks.count)")
                    .typeStyle(.monoSmall)
                    .foregroundStyle(.ink2)
            }
        } content: {
            if app.overview.openTasks.isEmpty {
                TileEmptyText("Không có việc nào đang mở trong các cuộc họp gần đây.")
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(app.overview.openTasks) { task in
                    ActionItemRow(text: task.item.task,
                                  isDone: Binding(get: { false }, set: { done in if done { tick(task) } }),
                                  owner: ownerText(task.item),
                                  ownerIsMe: MeetingList.myNames().contains(MeetingList.normalizeOwner(task.item.owner)),
                                  seconds: LangFormat.seconds(fromClock: task.item.timestamp)) { seconds in
                        app.router.openMeeting(task.folder, at: seconds)
                    }
                }
            }
        }
    }

    private func tick(_ task: ProjectOverviewBuilder.OpenTask) {
        app.overview.tick(task)
        app.refreshMeetings()
    }

    private func ownerText(_ item: ActionItem) -> String? {
        guard item.owner != ActionItem.unknown else { return nil }
        guard item.deadline != ActionItem.unknown else { return item.owner }
        return "\(item.owner) · \(item.deadline)"
    }
}

// MARK: - Tài liệu đã đọc

struct DocumentsTile: View {
    @Bindable var app: AppState
    @ObservedObject var indexer: ProjectIndexer
    /// false only for snapshot tests (ImageRenderer can't draw inside a ScrollView).
    var scrolls = true

    init(app: AppState, scrolls: Bool = true) {
        self.app = app
        self.indexer = app.indexer
        self.scrolls = scrolls
    }

    private var indexIsCurrent: Bool {
        indexer.projectFolder?.standardizedFileURL == app.projectFolder?.standardizedFileURL
    }

    private var documents: [IndexedFileInfo] {
        guard indexIsCurrent else { return [] }
        return indexer.files
            .filter { $0.sourceType != .meeting && !$0.path.hasPrefix(".meetings/") }
            .sorted { $0.path < $1.path }
    }

    var body: some View {
        BentoTile(title: "tài liệu đã đọc") {
            Button("Đọc lại") { indexer.reindex() }
                .buttonStyle(.lang(.pill))
                .disabled(because: indexer.isWorking ? String(localized: "Đang đọc dự án.")
                          : app.projectFolder == nil ? String(localized: "Chọn thư mục dự án trước.")
                          : nil)
        } content: {
            if documents.isEmpty {
                TileEmptyText("Chưa có tài liệu nào được đọc.")
            } else if scrolls {
                ScrollView { list }
                    .scrollIndicators(.automatic)
                    .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(documents) { document in
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.ink2)
                        .frame(width: 16)
                    Text(verbatim: document.path)
                        .typeStyle(.small)
                        .foregroundStyle(document.error == nil ? Color.ink : Color.rec)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(verbatim: document.error == nil ? "\(document.chunkCount) đoạn" : "không đọc được")
                        .typeStyle(.caption)
                        .foregroundStyle(.ink3)
                }
                .padding(.vertical, 5)
                .help(document.error ?? document.path)
            }
        }
    }
}

// MARK: - Thuật ngữ

struct GlossaryTile: View {
    @Bindable var app: AppState
    @ObservedObject var indexer: ProjectIndexer

    init(app: AppState) {
        self.app = app
        self.indexer = app.indexer
    }

    var body: some View {
        BentoTile(title: "thuật ngữ") {
            Button("Gợi ý từ dự án") {
                app.glossary.suggest(store: indexer.store, projectFolder: indexer.projectFolder)
            }
            .buttonStyle(.lang(.pill))
            .disabled(because: indexer.store == nil ? String(localized: "Chọn thư mục dự án trước.") : nil)
        } content: {
            GlossaryView(model: app.glossary, embedded: true)
        }
    }
}
