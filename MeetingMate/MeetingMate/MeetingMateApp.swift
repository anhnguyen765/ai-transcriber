import SwiftUI
import UserNotifications

@main
struct MeetingMateApp: App {
    // The AppDelegate owns the services so it can wire them together and
    // stop/save them safely when the app quits.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(recorder: appDelegate.recorder,
                     projectStore: appDelegate.projectStore,
                     transcription: appDelegate.transcription,
                     summary: appDelegate.summary,
                     indexer: appDelegate.indexer,
                     glossary: appDelegate.glossary)
        } label: {
            MenuBarIcon(recorder: appDelegate.recorder) { appDelegate.openWindowAction = $0 }
        }
        .menuBarExtraStyle(.window) // a small panel instead of a plain menu

        Window("Indexed Files", id: "indexed-files") {
            IndexedFilesView(indexer: appDelegate.indexer)
        }
        .defaultLaunchBehavior(.suppressed) // only opens from the menu

        Window("Hỏi lắng", id: "ask") {
            AskWindow(model: appDelegate.ask, projectStore: appDelegate.projectStore)
        }
        .defaultLaunchBehavior(.suppressed)

        // Opened from an Ask answer's meeting source: transcript at the cited time + audio.
        WindowGroup("Cuộc họp", id: "meeting", for: MeetingRef.self) { $ref in
            if let ref {
                MeetingViewer(ref: ref)
            }
        }
        .defaultLaunchBehavior(.suppressed)

        Window("Cuộc họp", id: "meetings") {
            MeetingsLibraryView(model: appDelegate.library, transcription: appDelegate.transcription,
                                summary: appDelegate.summary)
        }
        .defaultLaunchBehavior(.suppressed)

        Window("Thiết lập lắng", id: "onboarding") {
            OnboardingView(model: appDelegate.onboarding, projectStore: appDelegate.projectStore)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Glossary", id: "glossary") {
            GlossaryView(model: appDelegate.glossary)
        }
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(indexer: appDelegate.indexer)
        }
    }
}

/// "waveform" when idle, red "record.circle.fill" while recording.
private struct MenuBarIcon: View {
    @ObservedObject var recorder: Recorder
    /// Hands SwiftUI's openWindow to the AppDelegate, so global hotkeys can open windows.
    let provideOpenWindow: (OpenWindowAction) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if recorder.isRecording, let red = Self.redRecordImage {
                Image(nsImage: red)
            } else {
                Image(systemName: "waveform")
            }
        }
        .onAppear { provideOpenWindow(openWindow) } // the icon exists from launch on
    }

    /// Menu bar icons are normally drawn black/white only. To get a red icon we build an
    /// NSImage with a red symbol color and mark it as "not a template".
    private static let redRecordImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(hierarchicalColor: .systemRed)
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }()
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
    lazy var library = MeetingsLibraryModel(indexer: indexer, transcription: transcription, summary: summary)
    lazy var onboarding = OnboardingModel(recorder: recorder, projectStore: projectStore)
    /// SwiftUI's window opener, handed over by the menu bar icon (for hotkeys).
    var openWindowAction: OpenWindowAction? {
        didSet {
            // First launch: show the setup window once SwiftUI can open windows.
            if oldValue == nil, openWindowAction != nil, !OnboardingModel.isDone {
                NSApp.activate()
                openWindowAction?(id: "onboarding")
            }
        }
    }
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

    /// ⌃⌥Space from any app.
    func openAskWindow() {
        NSApp.activate()
        openWindowAction?(id: "ask")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets us react when a "done" notification is clicked.
        UNUserNotificationCenter.current().delegate = self
        // Editable prompt files in Application Support/Lang/Prompts.
        PromptStore.createMissingDefaults()

        // Recording → transcript → summary (each step only if enabled in Settings).
        recorder.onRecordingSaved = { [weak self] folder in
            guard let self, !self.isQuitting, AppSettings.autoTranscribe else { return }
            self.transcription.transcribeMeeting(at: folder)
        }
        transcription.onTranscribed = { [weak self] folder in
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
