import SwiftUI
import UserNotifications

@main
struct MeetingMateApp: App {
    // The AppDelegate owns the services so it can wire them together and
    // stop/save them safely when the app quits.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(app: appDelegate.appState)
        } label: {
            MenuBarIcon(app: appDelegate.appState) { appDelegate.openWindowAction = $0 }
        }
        .menuBarExtraStyle(.window) // a small panel instead of a plain menu

        Window("Indexed Files", id: "indexed-files") {
            IndexedFilesView(indexer: appDelegate.indexer)
        }
        .defaultLaunchBehavior(.suppressed) // only opens from the menu

        Window("lắng", id: "main") {
            MainWindow(app: appDelegate.appState)
        }
        .defaultSize(width: 1280, height: 840)
        .defaultLaunchBehavior(.suppressed)

        Window("Thiết lập lắng", id: "onboarding") {
            OnboardingView(model: appDelegate.onboarding, projectStore: appDelegate.projectStore)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)


        Settings {
            SettingsView(indexer: appDelegate.indexer)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let recorder = Recorder()
    let transcription = TranscriptionService()
    let summary = SummaryService()
    let projectStore = ProjectStore()
    let indexer = ProjectIndexer()
    let glossary = GlossaryModel()
    let meetingDetector = MeetingDetector()
    lazy var ask = AskViewModel(indexer: indexer)
    lazy var onboarding = OnboardingModel(recorder: recorder, projectStore: projectStore)
    /// Shared UI state + Router for the popover, menu bar icon and (later) main window / Quick Ask.
    /// ⌃⌥Space: the floating Quick Ask panel.
    lazy var quickAsk = QuickAskController(app: appState)
    lazy var appState = AppState(recorder: recorder, projectStore: projectStore, transcription: transcription,
                                 summary: summary, indexer: indexer, glossary: glossary, ask: ask)
    /// SwiftUI's window opener, handed over by the menu bar icon (for hotkeys).
    var openWindowAction: OpenWindowAction? {
        didSet {
            appState.router.openWindow = openWindowAction
            // First launch: show the setup window once SwiftUI can open windows.
            if oldValue == nil, openWindowAction != nil, !OnboardingModel.isDone {
                NSApp.activate()
                openWindowAction?(id: "onboarding")
            }
        }
    }
    /// The small recording pill beside the notch (created once at launch).
    private var notchIsland: NotchIslandController?
    private var isQuitting = false
    private var isPoweringOff = false

    /// ⌃⌥R from any app.
    func toggleRecordingFromHotkey() {
        Task {
            switch recorder.state {
            case .recording:
                await recorder.stop()
            case .idle:
                guard let folder = projectStore.folderURL else {
                    Notifier.post(title: "lắng", body: "Chọn thư mục dự án trước khi ghi âm.")
                    return
                }
                await recorder.start(projectFolder: folder)
                if let error = recorder.errorMessage {
                    Notifier.post(title: "Không ghi âm được", body: error)
                }
            case .starting, .stopping:
                break
            }
        }
    }

    /// After a crash/force quit: turn leftover CAFs into m4a and offer to finish the work.
    private func offerCrashRecovery() async {
        guard let project = projectStore.folderURL else { return }
        let stuck = CrashRecovery.findStuck(projectFolder: project)
        guard !stuck.isEmpty else { return }
        Log.info("Found \(stuck.count) unfinished meeting(s) after an unexpected quit")
        for meeting in stuck where meeting.status == .recording {
            await CrashRecovery.recoverRecording(meeting.folder)
        }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "lắng đã bị tắt đột ngột"
        alert.informativeText = "Có \(stuck.count) cuộc họp chưa xử lý xong: "
            + stuck.map { $0.folder.lastPathComponent }.joined(separator: ", ")
            + ". Audio đã được giữ lại. Chép lời và tóm tắt tiếp ngay?"
        alert.addButton(withTitle: "Xử lý tiếp")
        alert.addButton(withTitle: "Để sau")
        let resume = alert.runModal() == .alertFirstButtonReturn

        for meeting in stuck {
            if resume {
                if meeting.status == .summarizing {
                    summary.summarizeMeeting(at: meeting.folder)
                } else {
                    transcription.transcribeMeeting(at: meeting.folder)
                }
            } else {
                CrashRecovery.markForLater(meeting) // so we don't ask again on every launch
            }
        }
    }

    /// A recording under 15 seconds: ask before throwing it away. Returns true if it was deleted.
    private func askToDiscardShort(_ folder: URL, seconds: Double) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Bản ghi chỉ \(Int(seconds)) giây"
        alert.informativeText = "Bản ghi này quá ngắn để tóm tắt. Xoá bản ghi này, hay giữ lại?"
        alert.addButton(withTitle: "Xoá")
        alert.addButton(withTitle: "Giữ lại")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        try? FileManager.default.removeItem(at: folder)
        appState.refreshMeetings()
        return true
    }

    /// ⌃⌥Space from any app.
    func openAskWindow() {
        quickAsk.toggle()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets us react when a "done" notification is clicked.
        UNUserNotificationCenter.current().delegate = self
        notchIsland = NotchIslandController(app: appState)
        FontRegistry.logResolvedNames()
        // Editable prompt files in Application Support/Lang/Prompts.
        PromptStore.createMissingDefaults()

        // Recording → transcript → summary (each step only if enabled in Settings).
        recorder.onRecordingSaved = { [weak self] folder in
            guard let self, !self.isQuitting else { return }
            // Very short recordings: ask before discarding; "Giữ lại" transcribes as usual.
            if AppSettings.skipShortRecordings, let meta = try? MeetingMeta.load(from: folder),
               meta.durationSeconds < AppSettings.shortRecordingSeconds,
               self.askToDiscardShort(folder, seconds: meta.durationSeconds) {
                return
            }
            guard AppSettings.autoTranscribe else { return }
            self.transcription.transcribeMeeting(at: folder)
        }
        transcription.onTranscribed = { [weak self] folder in
            self?.appState.meetingTranscribed(folder)
            guard let self, !self.isQuitting, AppSettings.autoSummarize else { return }
            self.summary.summarizeMeeting(at: folder)
        }

        // Project index: pause while recording/transcribing/summarizing, to protect memory and CPU.
        indexer.canRun = { [weak self] in
            guard let self else { return false }
            return !self.recorder.isRecording && !self.transcription.isBusy && !self.summary.isBusy
                && PowerState.pauseReason() == nil
        }
        indexer.pauseReason = { [weak self] in
            guard let self else { return "" }
            if self.recorder.isRecording { return "đang ghi âm" }
            if self.transcription.isBusy { return "đang chép lời" }
            if let power = PowerState.pauseReason() { return power }
            return "đang tóm tắt"
        }
        // Summaries search the project index, but only for meetings of the indexed project.
        summary.retrieverProvider = { [weak self] projectPath in
            guard let self, let folder = self.indexer.projectFolder,
                  folder.standardizedFileURL.path == URL(fileURLWithPath: projectPath).standardizedFileURL.path
            else { return nil }
            return self.indexer.retriever
        }
        projectStore.onFolderChanged = { [weak self] folder in
            self?.indexer.index(projectFolder: folder)
        }
        indexer.index(projectFolder: projectStore.folderURL)

        // Global hotkeys (⌃⌥R record/stop, ⌃⌥Space Ask) and launch at login.
        HotkeyManager.install(toggleRecording: { [weak self] in self?.toggleRecordingFromHotkey() },
                              openAsk: { [weak self] in self?.openAskWindow() })
        LaunchAtLogin.applySetting()

        // Suggest recording when a call app uses the mic (never records by itself).
        MeetingDetector.registerNotificationCategories()
        meetingDetector.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        meetingDetector.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPoweringOff = true }
        }

        // Meetings left unfinished by a crash or force quit: recover audio and offer to continue.
        Task { await self.offerCrashRecovery() }
        Log.info("lắng started (\(Bundle.main.bundlePath))")
    }

    /// Makes sure a running recording is stopped and saved before the app exits
    /// (Quit button, logout, shutdown, or "Quit" from Activity Monitor).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting by hand while recording: ask first (not when the Mac shuts down or logs out).
        if recorder.isRecording, !isPoweringOff {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Đang ghi âm"
            alert.informativeText = "Dừng ghi, lưu file rồi thoát lắng?"
            alert.addButton(withTitle: "Dừng và thoát")
            alert.addButton(withTitle: "Tiếp tục ghi")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        isQuitting = true
        transcription.markInterrupted()
        summary.markInterrupted()
        Log.info("Quitting (recording: \(recorder.isRecording))")
        guard recorder.isRecording else { return .terminateNow }
        Task {
            await recorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater // "wait, I'm finishing up" — macOS waits for the reply above
    }

    // MARK: - Notifications

    /// Show the banner even though our (menu bar) app counts as "active".
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking the notification opens transcript.md or summary.md.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let path = userInfo[Notifier.openPathKey] as? String
        await MainActor.run {
            switch action {
            case MeetingDetector.recordAction: // "Ghi âm" on "Có vẻ bạn đang họp…"
                if !self.recorder.isRecording { self.toggleRecordingFromHotkey() }
            case MeetingDetector.stopAction:   // "Dừng ghi" on "Dừng ghi?"
                if self.recorder.isRecording { self.toggleRecordingFromHotkey() }
            default:
                if let path { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
        }
    }
}
