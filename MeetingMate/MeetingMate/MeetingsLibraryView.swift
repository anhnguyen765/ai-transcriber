import AppKit
import SwiftUI

/// One meeting folder in the library.
struct MeetingInfo: Identifiable, Equatable {
    var id: String { folder.path }
    let folder: URL
    let date: Date
    let title: String
    let duration: Double
    let status: MeetingMeta.Status?
    let hasTranscript: Bool
    let hasSummary: Bool

    var statusText: String {
        switch status {
        case .recording?: "Đang ghi"
        case .recorded?: "Đã ghi"
        case .transcribing?: "Đang chép lời"
        case .transcribed?: "Đã chép lời"
        case .failed?: "Lỗi chép lời"
        case .summarizing?: "Đang tóm tắt"
        case .summarized?: "Đã tóm tắt"
        case .summaryFailed?: "Lỗi tóm tắt"
        case nil: "—"
        }
    }
}

/// Reading, searching and exporting the meetings of a project (no UI).
enum MeetingLibrary {
    /// Every <project>/.meetings/<timestamp>/ with a meta.json, newest first.
    static func load(projectFolder: URL) -> [MeetingInfo] {
        let root = projectFolder.appending(path: ".meetings", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let meta = try? MeetingMeta.load(from: folder) else { return nil } // skips chats/, glossary.txt
            let summary = (try? Data(contentsOf: folder.appending(path: SummaryWriter.jsonFileName)))
                .flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: $0) }
            let fallbackTitle = meta.sourceFile.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                ?? "Cuộc họp"
            return MeetingInfo(
                folder: folder, date: meta.startTime, title: summary?.title ?? fallbackTitle,
                duration: meta.durationSeconds, status: meta.status,
                hasTranscript: FileManager.default.fileExists(atPath: folder.appending(path: TranscriptWriter.markdownFileName).path),
                hasSummary: FileManager.default.fileExists(atPath: folder.appending(path: SummaryWriter.markdownFileName).path))
        }
        .sorted { $0.date > $1.date }
    }

    /// Meetings matching `query`, best first: FTS5 over the indexed summaries and transcripts,
    /// or (without an index) a plain accent-insensitive text scan.
    static func search(_ query: String, in meetings: [MeetingInfo], store: IndexStore?) -> [MeetingInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return meetings }
        let byName = Dictionary(meetings.map { ($0.folder.lastPathComponent, $0) }) { a, _ in a }
        var ordered: [MeetingInfo] = []
        var seen = Set<String>()

        if let store, let ids = try? store.keywordSearch(trimmed, limit: 300, filter: SearchFilter(sourceTypes: [.meeting])),
           let chunks = try? store.chunks(ids: ids) {
            let pathByID = Dictionary(chunks.compactMap { c in c.id.map { ($0, c.path) } }) { a, _ in a }
            for id in ids {
                guard let path = pathByID[id] else { continue }
                let parts = path.split(separator: "/")
                guard parts.count >= 2, let meeting = byName[String(parts[1])],
                      seen.insert(meeting.id).inserted else { continue }
                ordered.append(meeting)
            }
        }
        // Titles always count, and the text scan covers meetings that aren't indexed yet.
        let needle = TranscriptMerger.normalize(trimmed)
        for meeting in meetings where !seen.contains(meeting.id) {
            var haystack = meeting.title
            if store == nil {
                for name in [SummaryWriter.markdownFileName, TranscriptWriter.markdownFileName] {
                    haystack += " " + ((try? String(contentsOf: meeting.folder.appending(path: name), encoding: .utf8)) ?? "")
                }
            }
            if TranscriptMerger.normalize(haystack).contains(needle) {
                seen.insert(meeting.id)
                ordered.append(meeting)
            }
        }
        return ordered
    }

    /// One shareable Markdown file: the summary, then the transcript.
    static func exportMarkdown(_ meeting: MeetingInfo) throws -> String {
        let read = { (name: String) in try? String(contentsOf: meeting.folder.appending(path: name), encoding: .utf8) }
        let summary = read(SummaryWriter.markdownFileName)
        let transcript = read(TranscriptWriter.markdownFileName)
        guard summary != nil || transcript != nil else {
            throw RecorderError("This meeting has no summary or transcript yet.")
        }
        var parts: [String] = []
        if let summary { parts.append(summary.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let transcript {
            // The transcript's own "# Cuộc họp …" title becomes a section heading.
            let body = transcript.replacingOccurrences(of: #"^# .*\n"#, with: "", options: .regularExpression)
            parts.append("## Bản chép lời\n\n" + body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.joined(separator: "\n\n---\n\n") + "\n"
    }

    static func exportFileName(_ meeting: MeetingInfo) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let title = meeting.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(f.string(from: meeting.date)) \(title).md"
    }
}

// MARK: - Window state

@MainActor
final class MeetingsLibraryModel: ObservableObject {
    @Published private(set) var meetings: [MeetingInfo] = []
    @Published var query = ""
    @Published var selection: Set<MeetingInfo.ID> = []
    @Published var message: String?

    let indexer: ProjectIndexer
    let transcription: TranscriptionService
    let summary: SummaryService

    init(indexer: ProjectIndexer, transcription: TranscriptionService, summary: SummaryService) {
        self.indexer = indexer
        self.transcription = transcription
        self.summary = summary
    }

    var shown: [MeetingInfo] {
        MeetingLibrary.search(query, in: meetings, store: indexer.store)
    }

    var selected: [MeetingInfo] {
        meetings.filter { selection.contains($0.id) }
    }

    func refresh() {
        guard let folder = indexer.projectFolder else { meetings = []; return }
        meetings = MeetingLibrary.load(projectFolder: folder)
        selection = selection.filter { id in meetings.contains { $0.id == id } }
    }

    func open(_ meeting: MeetingInfo, file: String) {
        let url = meeting.folder.appending(path: file)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { message = "\(file) không tồn tại cho cuộc họp này." }
    }

    func reveal(_ meeting: MeetingInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
    }

    func retranscribe(_ meetings: [MeetingInfo]) {
        meetings.forEach { transcription.transcribeMeeting(at: $0.folder) }
        message = "Đã thêm \(meetings.count) cuộc họp vào hàng đợi chép lời."
    }

    func resummarize(_ meetings: [MeetingInfo]) {
        meetings.forEach { summary.summarizeMeeting(at: $0.folder) }
        message = "Đã thêm \(meetings.count) cuộc họp vào hàng đợi tóm tắt."
    }

    /// Moves the folders to the Trash (recoverable) and removes their chunks from the index.
    func delete(_ meetings: [MeetingInfo]) {
        var failed: [String] = []
        for meeting in meetings {
            do {
                try FileManager.default.trashItem(at: meeting.folder, resultingItemURL: nil)
                let name = meeting.folder.lastPathComponent
                try? indexer.store?.delete(paths: [".meetings/\(name)/\(SummaryWriter.markdownFileName)",
                                                   ".meetings/\(name)/\(TranscriptWriter.markdownFileName)"])
            } catch {
                failed.append(meeting.folder.lastPathComponent)
            }
        }
        message = failed.isEmpty
            ? "Đã chuyển \(meetings.count) cuộc họp vào Thùng rác."
            : "Không xóa được: \(failed.joined(separator: ", "))"
        refresh()
    }

    func export(_ meeting: MeetingInfo) {
        do {
            let markdown = try MeetingLibrary.exportMarkdown(meeting)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = MeetingLibrary.exportFileName(meeting)
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
            NSApp.activate()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            message = "Đã xuất \(url.lastPathComponent)."
        } catch {
            message = "Không xuất được: \(error.localizedDescription)"
        }
    }
}

// MARK: - Window

struct MeetingsLibraryView: View {
    @ObservedObject var model: MeetingsLibraryModel
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var summary: SummaryService
    @Environment(\.openWindow) private var openWindow
    @State private var sortOrder = [KeyPathComparator(\MeetingInfo.date, order: .reverse)]
    @State private var pendingDelete: [MeetingInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cuộc họp · \(model.indexer.projectFolder?.lastPathComponent ?? "")").font(.headline)
                Text("\(model.meetings.count)").foregroundStyle(.secondary)
                Spacer()
                TextField("Tìm trong tiêu đề, tóm tắt, transcript…", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            if let status = transcription.statusText ?? summary.statusText {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            table
            HStack {
                actionButtons
                Spacer()
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 760, minHeight: 440)
        .onAppear { model.refresh() }
        .onChange(of: transcription.statusText) { model.refresh() }
        .onChange(of: summary.statusText) { model.refresh() }
        .confirmationDialog("Xóa \(pendingDelete.count) cuộc họp?", isPresented: Binding(
            get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Chuyển vào Thùng rác", role: .destructive) {
                model.delete(pendingDelete)
                pendingDelete = []
            }
        } message: {
            Text("Thư mục cuộc họp (audio, transcript, tóm tắt) được chuyển vào Thùng rác và gỡ khỏi index. Bạn vẫn khôi phục được từ Thùng rác.")
        }
    }

    private var table: some View {
        Table(model.shown.sorted(using: model.query.isEmpty ? sortOrder : []),
              selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Ngày", value: \.date) { m in
                Text(m.date, format: .dateTime.day().month().year().hour().minute())
            }
            .width(min: 120, ideal: 140)
            TableColumn("Tiêu đề", value: \.title) { m in
                Text(m.title).lineLimit(1)
            }
            TableColumn("Thời lượng", value: \.duration) { m in
                Text(TranscriptWriter.formatDuration(m.duration)).monospacedDigit()
            }
            .width(80)
            TableColumn("Trạng thái") { m in
                Text(m.statusText)
                    .foregroundStyle(m.status == .failed || m.status == .summaryFailed ? .red : .secondary)
            }
            .width(110)
        }
        .contextMenu(forSelectionType: MeetingInfo.ID.self) { ids in
            let items = model.meetings.filter { ids.contains($0.id) }
            if items.count == 1, let m = items.first {
                Button("Xem (transcript + audio)") { openViewer(m) }
                Button("Mở summary.md") { model.open(m, file: SummaryWriter.markdownFileName) }
                Button("Mở transcript.md") { model.open(m, file: TranscriptWriter.markdownFileName) }
                Button("Hiện thư mục") { model.reveal(m) }
                Button("Xuất Markdown…") { model.export(m) }
                Divider()
            }
            if !items.isEmpty {
                Button("Chép lời lại") { model.retranscribe(items) }
                Button("Tóm tắt lại") { model.resummarize(items) }
                Divider()
                Button("Xóa…", role: .destructive) { pendingDelete = items }
            }
        } primaryAction: { ids in
            // Double-click: open the meeting viewer.
            if let m = model.meetings.first(where: { ids.contains($0.id) }) { openViewer(m) }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        let items = model.selected
        let one = items.count == 1 ? items.first : nil
        Button("Xem") { one.map(openViewer) }.disabled(one == nil)
        Button("Summary") { one.map { model.open($0, file: SummaryWriter.markdownFileName) } }
            .disabled(one?.hasSummary != true)
        Button("Transcript") { one.map { model.open($0, file: TranscriptWriter.markdownFileName) } }
            .disabled(one?.hasTranscript != true)
        Button("Thư mục") { one.map(model.reveal) }.disabled(one == nil)
        Button("Xuất…") { one.map(model.export) }.disabled(one == nil)
        Button("Chép lời lại") { model.retranscribe(items) }.disabled(items.isEmpty)
        Button("Tóm tắt lại") { model.resummarize(items) }.disabled(items.isEmpty)
        Button("Xóa…", role: .destructive) { pendingDelete = items }.disabled(items.isEmpty)
    }

    private func openViewer(_ meeting: MeetingInfo) {
        openWindow(id: "meeting", value: MeetingRef(folderPath: meeting.folder.path, time: 0))
    }
}
