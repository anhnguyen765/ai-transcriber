import SwiftUI

/// The meeting detail: top bar, meta line, title, talk time, tabs, audio bar, and the Ask inspector.
struct MeetingDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case summary, transcript, tasks
        var id: String { rawValue }
    }

    let app: AppState
    let folder: URL
    @State private var model: MeetingDetailModel
    @State private var tab: Tab = .summary
    @State private var showInspector = true
    @State private var confirmDelete = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var showFind = false
    @State private var findText = ""

    init(app: AppState, folder: URL) {
        self.app = app
        self.folder = folder
        _model = State(initialValue: MeetingDetailModel(folder: folder))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        topBar
                        Text(verbatim: LangFormat.meetingMeta(start: model.startDate, length: model.duration,
                                                              people: model.speakerCount))
                            .typeStyle(.small)
                            .foregroundStyle(.ink2)
                        titleView
                        stateBanner
                        if let share = model.meShare {
                            TalkTimeBar(meShare: share)
                        }
                        segmented
                        tabContent
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)

                AudioBar(player: model.player, peaks: model.peaks, barOwners: model.barOwnersMe, markers: markers)
            }

            if showInspector {
                InspectorAsk(ask: app.ask, projectFolder: app.projectStore.folderURL, router: app.router,
                             meetingFolder: folder)
                    .frame(width: 330)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .task(id: folder) {
            await model.load()
            // Transcribed but not summarized yet: open on the transcript.
            if !model.hasSummary && !model.lines.isEmpty { tab = .transcript }
            applyPendingSeek()
        }
        // Opening the same meeting again (e.g. from an answer's source) moves to the new moment.
        .onChange(of: app.pendingSeek.map { "\($0.folder.path)|\($0.seconds)" }) { _, _ in
            applyPendingSeek()
        }
        .onDisappear { model.player.stop() }
        .background {
            Button("") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .opacity(0)
                .frame(width: 0, height: 0)
            Button("") {
                tab = .transcript
                showFind = true
            }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .confirmationDialog("Xoá cuộc họp này?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Xoá cuộc họp", role: .destructive, action: deleteMeeting)
        } message: {
            Text("Audio, bản chép lời và bản tóm tắt sẽ bị xoá vĩnh viễn. Không hoàn tác được.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { app.selectedMeeting = nil } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.ink2)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quay lại danh sách")

            Text(verbatim: "cuộc họp / \(MeetingGroup.of(model.startDate, now: Date(), calendar: .current).title)")
                .typeStyle(.small)
                .foregroundStyle(.ink3)
            Spacer()
            Button("Xuất Markdown", action: exportMarkdown)
                .buttonStyle(.lang(.pill, radius: Theme.Radius.pill))
                .disabled(because: model.hasContent ? nil : String(localized: "Cuộc họp chưa có bản tóm tắt hay bản chép lời."))

            Menu {
                Button("Chép lời lại") { app.transcription.transcribeMeeting(at: folder) }
                Button("Tóm tắt lại") { app.summary.summarizeMeeting(at: folder) }
                Divider()
                Button("Hiện trong Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                Divider()
                Button("Xoá cuộc họp…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink2)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Thêm")
        }
    }

    // MARK: Title (double click to rename)

    @ViewBuilder private var titleView: some View {
        if editingTitle {
            TextField("Tên cuộc họp", text: $titleDraft)
                .textFieldStyle(.plain)
                .typeStyle(.meetingTitle)
                .foregroundStyle(.ink)
                .onSubmit {
                    model.setTitle(titleDraft)
                    editingTitle = false
                }
        } else {
            Text(verbatim: model.title)
                .typeStyle(.meetingTitle)
                .foregroundStyle(.ink)
                .textSelection(.enabled)
                .onTapGesture(count: 2) {
                    titleDraft = model.title
                    editingTitle = true
                }
                .help("Nhấp đúp để đổi tên")
        }
    }

    // MARK: Segmented control

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(Theme.Motion.standard) { tab = item }
                } label: {
                    Text(verbatim: label(item))
                        .typeStyle(.ui(12, .medium))
                        .foregroundStyle(tab == item ? Color.ink : Color.ink2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background {
                            let shape = RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            if tab == item {
                                shape.fill(.white)
                                    .shadow(color: Theme.Palette.shadow.opacity(Theme.Shadow.tiny.opacity),
                                            radius: Theme.Shadow.tiny.radius, y: Theme.Shadow.tiny.y)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.segmented, style: .continuous).fill(Color.mist))
    }

    private func label(_ item: Tab) -> String {
        switch item {
        case .summary: "Tóm tắt"
        case .transcript: "Bản ghi"
        case .tasks: "Việc cần làm · \(model.actionItems.count)"
        }
    }

    /// Short or silent recordings replace the tabs with a calm state.
    private var emptyKind: EmptyKind? {
        guard let meta = model.meta, meta.status != .recording else { return nil }
        if meta.durationSeconds < AppSettings.shortRecordingSeconds { return .short }
        if meta.status == .transcribed, model.lines.isEmpty { return .noSpeech }
        return nil
    }

    private enum EmptyKind { case short, noSpeech }

    /// Summary failed (with retry), or transcribed but not summarized (pipeline card).
    @ViewBuilder private var stateBanner: some View {
        if model.meta?.status == .summaryFailed, !model.hasSummary {
            SummaryFailedBox(message: model.meta?.summaryError ?? String(localized: "Không rõ lỗi.")) {
                app.summary.summarizeMeeting(at: folder)
            }
        } else if model.summaryIsStale, emptyKind == nil {
            NoticeCard(text: String(localized: "Bản chép lời đã được sửa sau khi tóm tắt. Bản tóm tắt có thể không còn khớp."),
                       actions: [.init(title: String(localized: "Tóm tắt lại")) {
                           app.summary.summarizeMeeting(at: folder)
                       }])
        } else if !model.hasSummary, model.hasContent, emptyKind == nil {
            let busy = app.summary.currentFolder == folder
            SummaryPendingCard(title: model.title,
                               detail: busy ? (app.summary.statusText ?? String(localized: "đang tóm tắt…"))
                                   : String(localized: "đã chép lời xong · chưa có bản tóm tắt"),
                               canStart: !busy && !app.summary.isBusy) {
                app.summary.summarizeMeeting(at: folder)
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        if let kind = emptyKind {
            ShortRecordingState(duration: model.duration, noSpeech: kind == .noSpeech,
                                onPlay: { model.player.seek(to: 0, play: true) },
                                onDelete: { confirmDelete = true })
        } else {
            tabBody
        }
    }

    @ViewBuilder private var tabBody: some View {
        switch tab {
        case .summary:
            SummaryTab(model: model, section: .summary, play: { model.player.seek(to: $0, play: true) },
                       openFile: openProjectFile)
        case .transcript:
            TranscriptTab(model: model, player: model.player, showFind: $showFind, findText: $findText)
        case .tasks:
            SummaryTab(model: model, section: .tasks, play: { model.player.seek(to: $0, play: true) },
                       openFile: openProjectFile)
        }
    }

    // MARK: Waveform markers

    private var markers: [WaveMarker] {
        let decisions = (model.summary?.decisions ?? []).compactMap { item -> WaveMarker? in
            guard let seconds = LangFormat.seconds(fromClock: item.timestamp) else { return nil }
            return WaveMarker(kind: .decision, seconds: seconds, label: item.text)
        }
        let actions = model.actionItems.compactMap { item -> WaveMarker? in
            guard let seconds = LangFormat.seconds(fromClock: item.timestamp) else { return nil }
            return WaveMarker(kind: .action, seconds: seconds, label: item.task)
        }
        return decisions + actions
    }

    // MARK: Actions

    /// Jumps to the moment asked for by the popover or an answer's source, if it is for this meeting.
    private func applyPendingSeek() {
        guard let pending = app.pendingSeek, pending.folder == folder else { return }
        model.player.seek(to: pending.seconds, play: false)
        app.pendingSeek = nil
    }

    private func exportMarkdown() {
        guard let text = try? model.markdownForExport() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.exportFileName
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func openProjectFile(_ relativePath: String) {
        guard let meta = model.meta, !relativePath.isEmpty else { return }
        let url = URL(fileURLWithPath: meta.projectPath).appending(path: relativePath)
        NSWorkspace.shared.open(url)
    }

    private func deleteMeeting() {
        model.player.stop()
        do {
            try FileManager.default.removeItem(at: folder)
            app.selectedMeeting = nil
            app.refreshMeetings()
        } catch {
            Log.error("Could not delete meeting: \(error.localizedDescription)")
        }
    }
}
