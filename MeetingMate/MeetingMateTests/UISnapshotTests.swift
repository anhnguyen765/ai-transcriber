import AppKit
import SwiftUI
import Testing
@testable import MeetingMate

/// Renders UI galleries to PNG for visual checks. Only runs when LANG_SNAPSHOT_DIR is set
/// (pass TEST_RUNNER_LANG_SNAPSHOT_DIR=/some/folder to xcodebuild).
@MainActor
struct UISnapshotTests {
    static let outputFolder = ProcessInfo.processInfo.environment["LANG_SNAPSHOT_DIR"]

    @Test func bundledFontsLoad() {
        #expect(FontRegistry.isRegistered)
        for name in FontRegistry.postScriptNames {
            #expect(NSFont(name: name, size: 12) != nil, "missing font \(name)")
        }
    }

    @Test(.enabled(if: outputFolder != nil))
    func componentGallery() throws {
        try render(ComponentGallery(), name: "a-components")
    }

    @Test(.enabled(if: outputFolder != nil))
    func ripples() throws {
        let view = HStack(spacing: 28) {
            VStack {
                RippleView(phase: .idle) { RecordButton(isRecording: false) {} }
                Text("Ghi âm").typeStyle(.recordCaption).foregroundStyle(.ink)
            }
            VStack {
                RippleView(phase: .recording, micLevel: 0.15, systemLevel: 0.1) { RecordButton(isRecording: true) {} }
                Text(verbatim: "quiet").typeStyle(.caption)
            }
            VStack {
                RippleView(phase: .recording, micLevel: 0.95, systemLevel: 0.8) { RecordButton(isRecording: true) {} }
                Text(verbatim: "loud").typeStyle(.caption)
            }
            VStack {
                RippleView(phase: .settling(done: false), size: 132)
                Text("đang lắng…").typeStyle(.settlingCaption).foregroundStyle(.deep)
            }
            VStack(spacing: 20) {
                RecordButton(isRecording: false, isBusy: true) {}
                RecordButton(isRecording: false, disabledReason: "x") {}
            }
        }
        .padding(24)
        .background(.white)
        try render(view, name: "b-ripples")
    }

    /// The real popover (idle), pointed at the test meetings project if it exists on this Mac.
    @Test(.enabled(if: outputFolder != nil))
    func popoverIdle() async throws {
        let project = URL(fileURLWithPath: "/Users/n3rd/project-x/2027")
        if FileManager.default.fileExists(atPath: project.path),
           let bookmark = try? project.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "projectFolderBookmark") // test-only defaults domain
        }
        let app = AppState(recorder: Recorder(), projectStore: ProjectStore(), transcription: TranscriptionService(),
                           summary: SummaryService(), indexer: ProjectIndexer(), glossary: GlossaryModel())
        app.refreshMeetings()
        try await Task.sleep(for: .seconds(1)) // meetings load in the background
        try render(PopoverView(app: app).background(Color.mist), name: "c-popover-idle")
    }

    /// State B and C pieces with sample data (the live states need a real recording).
    @Test(.enabled(if: outputFolder != nil))
    func popoverStates() throws {
        let view = HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 14) {
                RippleView(phase: .recording, micLevel: 0.5, systemLevel: 0.3) { RecordButton(isRecording: true) {} }
                Text(verbatim: "12:48").typeStyle(.timer).foregroundStyle(.ink)
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Circle().fill(.water).frame(width: 6, height: 6)
                        Text("bạn").typeStyle(.caption).foregroundStyle(.ink2)
                        MiniBars(values: [0.2, 0.6, 0.9, 0.4, 0.7, 0.3, 0.8, 0.5], color: .water)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(.sandInk).frame(width: 6, height: 6)
                        Text("người khác").typeStyle(.caption).foregroundStyle(.ink2)
                        MiniBars(values: [0.1, 0.3, 0.2, 0.5, 0.2, 0.4, 0.1, 0.3], color: .sandInk)
                    }
                }
                HStack(spacing: 8) {
                    Button("Tạm dừng") {}.buttonStyle(.lang(.secondary, fullWidth: true)).disabled(true)
                    Button("Dừng & lưu") {}.buttonStyle(.lang(.record, fullWidth: true))
                }
            }
            .padding(16).frame(width: 320).background(.white)

            VStack(spacing: 14) {
                RippleView(phase: .settling(done: false), size: 132)
                Text("đang lắng…").typeStyle(.settlingCaption).foregroundStyle(.deep)
                PipelineCard(progress: PipelineProgress(folder: nil, title: SampleData.meetingTitle, step: .summarize,
                                                        fraction: 0.82,
                                                        detail: "đang tóm tắt phần 2/3 · dùng 6 tài liệu dự án",
                                                        eta: "~1 phút", waiting: 0))
                DoneToast(title: SampleData.meetingTitle, actionItemCount: 3) {}
                NoticeCard(text: "Ollama chưa chạy nên chưa tóm tắt được.",
                           actions: [.init(title: "Mở Ollama") {}, .init(title: "Thử lại") {}])
            }
            .padding(16).frame(width: 320).background(.white)
        }
        .padding(20)
        .background(Color.mist)
        try render(view, name: "c-popover-states")
    }

    @Test(.enabled(if: outputFolder != nil))
    func notchIsland() throws {
        let view = VStack(spacing: 12) {
            NotchIslandView(recorder: Recorder()) {}
            NotchIslandView(recorder: Recorder()) {}
        }
        .padding(20)
        .background(Color(hex: 0x2A3A42))
        try render(view, name: "d-notch-island")
    }

    /// The main window's sidebar and detail side by side at the default 1280×840 size.
    @Test(.enabled(if: outputFolder != nil))
    func mainWindow() async throws {
        let project = URL(fileURLWithPath: "/Users/n3rd/project-x/2027")
        if FileManager.default.fileExists(atPath: project.path),
           let bookmark = try? project.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "projectFolderBookmark")
        }
        let app = AppState(recorder: Recorder(), projectStore: ProjectStore(), transcription: TranscriptionService(),
                           summary: SummaryService(), indexer: ProjectIndexer(), glossary: GlossaryModel())
        app.refreshMeetings()
        try await Task.sleep(for: .seconds(1))
        app.selectedMeeting = app.meetings.first?.folder
        let view = HStack(spacing: 0) {
            MainSidebar(app: app).frame(width: 250)
            MainDetail(app: app)
        }
        .frame(width: 1280, height: 840)
        try render(view, name: "e-main-window")
    }

    /// The meeting detail for the first real meeting (needs the test project on this Mac).
    @Test(.enabled(if: outputFolder != nil))
    func meetingDetail() async throws {
        let project = URL(fileURLWithPath: "/Users/n3rd/project-x/2027")
        if FileManager.default.fileExists(atPath: project.path),
           let bookmark = try? project.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "projectFolderBookmark")
        }
        let app = AppState(recorder: Recorder(), projectStore: ProjectStore(), transcription: TranscriptionService(),
                           summary: SummaryService(), indexer: ProjectIndexer(), glossary: GlossaryModel())
        app.refreshMeetings()
        try await Task.sleep(for: .seconds(1))
        guard let folder = app.meetings.first(where: { $0.hasSummary })?.folder ?? app.meetings.first?.folder else { return }
        let view = MeetingDetailView(app: app, folder: folder)
            .frame(width: 1080, height: 840)
        try render(view, name: "f-meeting-detail")
    }

    /// The Dự án section, wide (two columns) and narrow (one column).
    @Test(.enabled(if: outputFolder != nil))
    func projectSection() async throws {
        let project = URL(fileURLWithPath: "/Users/n3rd/project-x/2027")
        if FileManager.default.fileExists(atPath: project.path),
           let bookmark = try? project.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "projectFolderBookmark")
        }
        let app = AppState(recorder: Recorder(), projectStore: ProjectStore(), transcription: TranscriptionService(),
                           summary: SummaryService(), indexer: ProjectIndexer(), glossary: GlossaryModel())
        app.refreshMeetings()
        try await Task.sleep(for: .seconds(1))
        for (width, name) in [(1500.0, "g-project-wide"), (950.0, "g-project-medium"), (560.0, "g-project-narrow")] {
            let view = ProjectSection(app: app, scrolls: false)
                .frame(width: width, alignment: .topLeading)
                .background(Color.white)
            try render(view, name: name)
        }
    }

    private func render(_ view: some View, name: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage, let folder = Self.outputFolder else {
            Issue.record("render failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
    }
}
