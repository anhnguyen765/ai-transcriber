import AppKit
import Combine
import Observation
import SwiftUI

/// Opens things from anywhere (popover, main window, Quick Ask, notifications, NotchIsland).
@MainActor
@Observable
final class Router {
    /// SwiftUI's window opener, handed over by the menu bar icon at launch.
    @ObservationIgnored var openWindow: OpenWindowAction?

    /// Opens meeting X at Y seconds.
    /// Until the new main window exists (step e) this opens the existing meeting viewer.
    /// Set by AppState: selects the meeting in the main window.
    @ObservationIgnored var onOpenMeeting: ((URL, Double) -> Void)?

    func openMeeting(_ folder: URL, at time: Double = 0) {
        if let onOpenMeeting {
            onOpenMeeting(folder, time)
            return
        }
        NSApp.activate()
        openWindow?(id: "meeting", value: MeetingRef(folderPath: folder.path, time: time))
    }

    /// "Mở lắng" (⌘O): the main window.
    func openMain() {
        open(windowID: "main")
    }

    /// Set by AppState: shows the Hỏi section of the main window.
    @ObservationIgnored var onOpenAsk: (() -> Void)?

    func openAsk() {
        if let onOpenAsk {
            onOpenAsk()
            return
        }
        NSApp.activate()
        openWindow?(id: "main")
    }

    func open(windowID: String) {
        NSApp.activate()
        openWindow?(id: windowID)
        if windowID == "main" { Self.bringMainToFront() }
    }

    /// The window can open behind other apps' windows; bring it forward once it exists.
    private static func bringMainToFront() {
        Task { @MainActor in
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(100))
                if let window = NSApp.windows.first(where: { $0.title == "lắng" && $0.canBecomeMain }) {
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    return
                }
            }
        }
    }
}

/// Shared UI state: what the popover, menu bar icon and (later) NotchIsland show.
/// Reads the existing services; never changes how they work.
@MainActor
@Observable
final class AppState {
    let recorder: Recorder
    let projectStore: ProjectStore
    let transcription: TranscriptionService
    let summary: SummaryService
    let indexer: ProjectIndexer
    let glossary: GlossaryModel
    /// "Tổng quan" in the Dự án section: about, top 3 priorities, latest meetings and to-dos.
    let overview = ProjectOverviewModel()
    let router = Router()
    /// The same Ask model as the "Hỏi lắng" window, so chats are shared.
    let ask: AskViewModel
    /// A meeting opened at a moment (from the popover); consumed by the detail view.
    var pendingSeek: (folder: URL, seconds: Double)?

    private(set) var status: PipelineStatus = .idle
    private(set) var menuBarMode: MenuBarMode = .idle

    // The current project. ProjectStore and ProjectIndexer are ObservableObjects, which @Observable views
    // can't see change; these copies are what every view reads, so a project switch updates everything at once.
    /// The current project folder (the one source of truth for views).
    private(set) var projectFolder: URL?
    /// Recently used project folders, newest first (project switcher).
    private(set) var recentProjects: [URL] = []
    private(set) var projectName = String(localized: "Chưa có dự án")
    private(set) var projectSubtitle = String(localized: "Chọn thư mục để bắt đầu")
    private(set) var projectStatus: ProjectStatus = .none
    /// Documents read by the index: distinct files, no read error, not a meeting.
    private(set) var documentCount = 0

    /// Newest first.
    private(set) var meetings: [MeetingInfo] = [] {
        didSet { recomputeProject() }
    }
    /// Undone-or-not action items across all meetings (shown as the "Việc của tôi" badge).
    private(set) var openTaskCount = 0
    /// Main window state.
    var section: MainSection = .meetings
    var selectedMeeting: URL?
    var searchText = ""
    /// Command palette (⌘K or click on the sidebar search).
    var paletteOpen = false

    @ObservationIgnored private var done: PipelineDone?
    @ObservationIgnored private var stepKey: String?
    @ObservationIgnored private var stepStartedAt: Date?
    @ObservationIgnored private var titleCache: [URL: String] = [:]
    @ObservationIgnored private var lastSummaryURL: URL?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []

    init(recorder: Recorder, projectStore: ProjectStore, transcription: TranscriptionService,
         summary: SummaryService, indexer: ProjectIndexer, glossary: GlossaryModel,
         ask: AskViewModel? = nil) {
        self.ask = ask ?? AskViewModel(indexer: indexer)
        self.recorder = recorder
        self.projectStore = projectStore
        self.transcription = transcription
        self.summary = summary
        self.indexer = indexer
        self.glossary = glossary
        lastSummaryURL = summary.lastSummaryURL
        // Popover rows and "Xem" open the meeting in the main window.
        router.onOpenAsk = { [weak self] in
            self?.section = .ask
            self?.router.open(windowID: "main")
        }
        router.onOpenMeeting = { [weak self] folder, time in
            guard let self else { return }
            self.section = .meetings
            self.selectedMeeting = folder
            self.pendingSeek = (folder, time)
            self.router.open(windowID: "main")
        }

        // @Published fires before the value changes: hop to the next main-loop turn to read new values.
        let changes: [AnyPublisher<Void, Never>] = [
            recorder.$state.map { _ in () }.eraseToAnyPublisher(),
            transcription.$phase.map { _ in () }.eraseToAnyPublisher(),
            transcription.$waitingCount.map { _ in () }.eraseToAnyPublisher(),
            transcription.$currentFolder.map { _ in () }.eraseToAnyPublisher(),
            summary.$phase.map { _ in () }.eraseToAnyPublisher(),
            summary.$currentFolder.map { _ in () }.eraseToAnyPublisher(),
            summary.$contextDocumentCount.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.recompute() }
            .store(in: &subscriptions)
        summary.$lastSummaryURL
            .receive(on: RunLoop.main)
            .sink { [weak self] url in self?.summaryFinished(url) }
            .store(in: &subscriptions)
        // Runs before the project changes (no receive(on:)), so the old chat is saved to its own project.
        projectStore.$folderURL
            .dropFirst()
            .sink { [weak self] _ in self?.ask.newChat() }
            .store(in: &subscriptions)
        // @Published sends the new value before the property changes: use the value it sends.
        projectStore.$folderURL
            .sink { [weak self] url in self?.projectChanged(to: url) }
            .store(in: &subscriptions)
        projectStore.$recentFolders
            .sink { [weak self] folders in self?.recentProjects = folders }
            .store(in: &subscriptions)
        let headerChanges: [AnyPublisher<Void, Never>] = [
            indexer.$phase.map { _ in () }.eraseToAnyPublisher(),
            indexer.$files.map { _ in () }.eraseToAnyPublisher(),
            indexer.$problem.map { _ in () }.eraseToAnyPublisher(),
            recorder.$state.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(headerChanges)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.recomputeProject() }
            .store(in: &subscriptions)

        recompute()
    }

    // MARK: - Project

    /// Everything that belongs to one project starts over when you switch: header, meeting list,
    /// selection, overview, glossary and past chats.
    private func projectChanged(to url: URL?) {
        let isSame = url?.standardizedFileURL == projectFolder?.standardizedFileURL
        projectFolder = url
        if !isSame {
            selectedMeeting = nil
            pendingSeek = nil
            searchText = ""
            done = nil
            titleCache = [:]
            meetings = []
            openTaskCount = 0
            glossary.reset(for: url)
        }
        overview.reload(projectFolder: url, meetings: [])
        recomputeProject()
        recompute()
        refreshMeetings()
        // The indexer switches to the new folder right after this (ProjectStore.onFolderChanged).
        Task { @MainActor [weak self] in
            self?.ask.reloadPastChats()
            self?.recomputeProject()
        }
    }

    /// Recomputes the header from the current project, index and recorder.
    func recomputeProject() {
        guard let projectFolder else {
            projectName = String(localized: "Chưa có dự án")
            projectSubtitle = String(localized: "Chọn thư mục để bắt đầu")
            projectStatus = .none
            documentCount = 0
            return
        }
        projectName = projectFolder.lastPathComponent
        // Until the indexer has switched, its files belong to the old project.
        let indexIsCurrent = indexer.projectFolder?.standardizedFileURL == projectFolder.standardizedFileURL
        documentCount = indexIsCurrent
            ? indexer.files.filter { $0.sourceType != .meeting && $0.error == nil && !$0.path.hasPrefix(".meetings/") }.count
            : 0

        if recorder.isRecording {
            projectSubtitle = String(localized: "đang ghi vào .meetings")
        } else if indexIsCurrent, case .reading(let done, let total) = indexer.phase {
            projectSubtitle = String(localized: "đang đọc dự án… \(done)/\(total)")
        } else {
            projectSubtitle = String(localized: "\(documentCount) tài liệu · \(meetings.count) cuộc họp")
        }

        if recorder.isRecording {
            projectStatus = .recording
        } else if !indexIsCurrent {
            projectStatus = .indexing
        } else {
            switch indexer.problem {
            case .ollamaNotRunning:
                projectStatus = .attention(String(localized: "Ollama chưa chạy: chỉ tìm được theo từ khóa."))
            case .modelMissing(let model):
                projectStatus = .attention(String(localized: "Chưa tải model \(model): chỉ tìm được theo từ khóa."))
            case nil:
                projectStatus = indexer.isWorking ? .indexing : documentCount == 0 ? .noDocuments : .indexed
            }
        }
    }

    /// Why recording can't start right now, or nil.
    var recordDisabledReason: String? {
        if projectFolder == nil { return String(localized: "Chọn thư mục dự án trước khi ghi âm.") }
        return nil
    }

    /// Why the project can't be switched right now, or nil.
    var switchProjectDisabledReason: String? {
        recorder.state == .idle ? nil : String(localized: "Không đổi dự án được khi đang ghi âm.")
    }

    // MARK: - Actions

    func toggleRecording() {
        Log.info("UI: toggle recording pressed (state=\(recorder.state))")
        Task {
            if recorder.isRecording {
                await recorder.stop()
                Log.info("UI: stop finished (state=\(recorder.state))")
            } else {
                dismissDone()
                await recorder.start(projectFolder: projectFolder)
            }
        }
    }

    /// Audio/video file chosen or dropped on the popover.
    func importAudio(_ url: URL) {
        dismissDone()
        transcription.transcribeFile(url, projectFolder: projectFolder)
    }

    func chooseAudioFile() {
        dismissDone()
        transcription.chooseAndTranscribeFile(projectFolder: projectFolder)
    }

    func viewDone() {
        guard case .done(let done) = status else { return }
        router.openMeeting(done.folder)
        dismissDone()
    }

    func dismissDone() {
        done = nil
        recompute()
    }

    /// Called by AppDelegate after a transcript was written.
    func meetingTranscribed(_ folder: URL) {
        titleCache[folder] = nil
        refreshMeetings()
        // Without auto-summary, the pipeline ends here.
        if !AppSettings.autoSummarize { finish(folder: folder, actionItems: 0) }
    }

    func refreshMeetings() {
        guard let folder = projectFolder else {
            meetings = []
            return
        }
        Task.detached(priority: .utility) {
            let list = MeetingLibrary.load(projectFolder: folder)
            // "Việc của tôi": only my action items that are not checked.
            let names = MeetingList.myNames()
            let counted = list.map { meeting in (meeting, MeetingList.myActionItems(in: meeting.folder, names: names)) }
            let tasks = counted.reduce(0) { $0 + $1.1.mine }
            print("[lắng] Việc của tôi = \(tasks) (tên khớp: \(names.sorted().joined(separator: ", ")))")
            for (meeting, counts) in counted where counts.all > 0 {
                print("  \(meeting.folder.lastPathComponent): \(counts.all) việc, của tôi \(counts.mine)")
            }
            await MainActor.run { [weak self] in
                guard let self, self.projectFolder == folder else { return }
                self.meetings = list.filter { $0.status != .recording }
                self.openTaskCount = tasks
                self.overview.reload(projectFolder: folder, meetings: self.meetings)
            }
        }
    }

    // MARK: - Pipeline

    private func summaryFinished(_ url: URL?) {
        guard let url, url != lastSummaryURL else { return }
        lastSummaryURL = url
        let folder = url.deletingLastPathComponent()
        titleCache[folder] = nil
        let summary = (try? Data(contentsOf: folder.appending(path: SummaryWriter.jsonFileName)))
            .flatMap { try? JSONDecoder().decode(MeetingSummary.self, from: $0) }
        refreshMeetings()
        finish(folder: folder, actionItems: summary?.actionItems.count ?? 0, title: summary?.title)
    }

    private func finish(folder: URL, actionItems: Int, title: String? = nil) {
        done = PipelineDone(folder: folder, title: title ?? self.title(for: folder),
                            actionItemCount: actionItems, at: Date())
        recompute()
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4)) // brief check mark in the menu bar
            self?.recompute()
            try? await Task.sleep(for: .seconds(PipelineStatus.doneLifetime))
            self?.recompute()
        }
    }

    func recompute() {
        let folder = transcription.currentFolder ?? summary.currentFolder
            ?? (recorder.state == .stopping ? recorder.lastSessionURL : nil)
        var input = PipelineStatus.Inputs(recorder: recorder.state, transcription: transcription.phase,
                                          transcriptionWaiting: transcription.waitingCount,
                                          summary: summary.phase,
                                          contextDocuments: summary.contextDocumentCount,
                                          folder: folder,
                                          title: folder.map(title(for:)) ?? String(localized: "Cuộc họp mới"),
                                          done: done)
        // Remember when the current step began (for the ETA).
        let first = PipelineStatus.derive(input)
        if case .processing(let p) = first {
            let key = "\(p.step.rawValue)|\(folder?.path ?? "")"
            if key != stepKey {
                stepKey = key
                stepStartedAt = Date()
            }
            input.stepStartedAt = stepStartedAt
        } else {
            stepKey = nil
            stepStartedAt = nil
        }
        let new = PipelineStatus.derive(input)
        if new != status { status = new }

        let mode: MenuBarMode = switch new {
        case .recording: .recording
        case .processing: .processing
        case .done(let d) where Date().timeIntervalSince(d.at) < 4: .justDone
        default: .idle
        }
        if mode != menuBarMode { menuBarMode = mode }
        if case .idle = new, done != nil, done.map({ Date().timeIntervalSince($0.at) >= PipelineStatus.doneLifetime }) == true {
            done = nil
        }
    }

    /// Library rows without a summary are all called "Cuộc họp": add the time so they can be told apart.
    func displayTitle(_ meeting: MeetingInfo) -> String {
        meeting.hasSummary || meeting.title != "Cuộc họp" ? meeting.title
            : String(localized: "Cuộc họp \(LangFormat.time(meeting.date))")
    }

    /// Meeting title for the UI: summary title, imported file name, or "Cuộc họp 10:00".
    func title(for folder: URL) -> String {
        if let cached = titleCache[folder] { return cached }
        var title: String?
        if let data = try? Data(contentsOf: folder.appending(path: SummaryWriter.jsonFileName)),
           let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
            title = summary.title
        }
        let meta = try? MeetingMeta.load(from: folder)
        if title == nil, let source = meta?.sourceFile {
            title = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
        }
        let result = title ?? String(localized: "Cuộc họp \(LangFormat.time(meta?.startTime ?? Date()))")
        titleCache[folder] = result
        return result
    }
}
