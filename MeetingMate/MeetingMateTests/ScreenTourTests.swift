import AppKit
import SwiftUI
import Testing
@testable import MeetingMate

/// "Screen tour": renders every main-window section, for each test project and window width, to PNG.
/// Unlike ImageRenderer, this draws through a real (off-screen) window, so ScrollView, List and
/// TextField show up. Only runs when LANG_SNAPSHOT_DIR is set; see scripts/screens.sh.
///
/// It only reads: projects are opened without indexing, so "tài liệu đã đọc" stays empty.
@MainActor
@Suite(.serialized)
struct ScreenTourTests {
    static let outputFolder = ProcessInfo.processInfo.environment["LANG_SNAPSHOT_DIR"]
    /// Projects to tour (the folders must exist on this Mac); the first meetings project gets a meeting opened.
    static let projects = ["/Users/n3rd/project-x/2027", "/Users/n3rd/project-x/mkt-tester"]
    /// The main window's minimum width, and a wide external-display width.
    static let widths: [CGFloat] = [1080, 1600]
    static let height: CGFloat = 900

    @Test(.enabled(if: outputFolder != nil))
    func allScreens() async throws {
        let folder = try #require(Self.outputFolder)
        let keys = ["projectFolderBookmark", "recentProjectBookmarks"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }

        let store = ProjectStore()
        let app = AppState(recorder: Recorder(), projectStore: store, transcription: TranscriptionService(),
                           summary: SummaryService(), indexer: ProjectIndexer(), glossary: GlossaryModel())
        var rendered = 0
        for path in Self.projects {
            let project = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: project.path) else { continue }
            store.select(project)
            try await waitForMeetings(app)
            let name = project.lastPathComponent

            for section in MainSection.allCases {
                app.section = section
                app.selectedMeeting = section == .meetings ? app.meetings.first?.folder : nil
                for width in Self.widths {
                    let view = HStack(spacing: 0) {
                        MainSidebar(app: app).frame(width: 250)
                        Divider()
                        MainDetail(app: app)
                    }
                    .background(Color.white)
                    try await renderWindow(view, size: CGSize(width: width, height: Self.height),
                                           to: URL(fileURLWithPath: folder)
                                               .appending(path: "\(name)-\(section.rawValue)-\(Int(width)).png"))
                    rendered += 1
                }
            }
        }
        #expect(rendered > 0, "none of the tour projects exist on this Mac")
    }

    /// Meetings load in the background after a project switch.
    private func waitForMeetings(_ app: AppState) async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    /// Draws `view` in an off-screen window of `size` and writes a 2× PNG.
    private func renderWindow(_ view: some View, size: CGSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).preferredColorScheme(.light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless() // off-screen, but "visible" so AppKit draws it
        defer { window.orderOut(nil) }
        // Let SwiftUI lay out, load fonts and run onAppear.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
        }
        let bounds = host.bounds
        let scale: CGFloat = 2
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: Int(bounds.width * scale),
                                                pixelsHigh: Int(bounds.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
