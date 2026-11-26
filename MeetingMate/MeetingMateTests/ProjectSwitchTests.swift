import Foundation
import Testing
@testable import MeetingMate

/// Switching project must update every view at once: header, switcher tick, selection, glossary.
@MainActor
@Suite(.serialized)
struct ProjectSwitchTests {
    private func makeFolder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func switchingProjectUpdatesStateRightAway() throws {
        // ProjectStore saves bookmarks in the (test-only) defaults domain: put them back afterwards.
        let keys = ["projectFolderBookmark", "recentProjectBookmarks"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }

        let alpha = try makeFolder("alpha")
        let beta = try makeFolder("beta")
        let store = ProjectStore()
        let glossary = GlossaryModel()
        let app = AppState(recorder: Recorder(), projectStore: store, transcription: TranscriptionService(),
                           summary: SummaryService(), indexer: ProjectIndexer(), glossary: glossary)

        store.select(alpha)
        #expect(app.projectFolder == alpha)
        #expect(app.projectName == alpha.lastPathComponent)
        #expect(app.recentProjects.first == alpha)

        app.selectedMeeting = alpha.appending(path: ".meetings/2026-11-26_10-00-00")
        app.searchText = "báo giá"
        glossary.items = [GlossaryModel.Item(term: "Zalopay", count: 2, kind: "company", selected: true,
                                             alreadyInGlossary: false)]

        store.select(beta)
        #expect(app.projectFolder == beta)
        #expect(app.projectName == beta.lastPathComponent)
        #expect(app.recentProjects.first == beta)
        #expect(app.selectedMeeting == nil)
        #expect(app.searchText.isEmpty)
        #expect(app.meetings.isEmpty)
        #expect(glossary.items.isEmpty)
        #expect(glossary.projectFolder == beta)
        // The indexer hasn't switched yet in this test, so its old files must not be counted.
        #expect(app.documentCount == 0)
    }
}
