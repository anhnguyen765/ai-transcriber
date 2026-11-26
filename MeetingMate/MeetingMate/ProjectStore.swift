import AppKit

/// Remembers which project folder recordings go into.
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var folderURL: URL?

    /// Called when you pick a different project folder (used to start indexing it).
    var onFolderChanged: ((URL) -> Void)?

    private let bookmarkKey = "projectFolderBookmark"

    var projectName: String { folderURL?.lastPathComponent ?? "No project folder" }

    /// <project>/.meetings
    var meetingsFolderURL: URL? {
        folderURL?.appending(path: ".meetings", directoryHint: .isDirectory)
    }

    init() {
        restore()
    }

    /// Shows the standard macOS "choose folder" dialog.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the project folder. Recordings go into its .meetings subfolder."

        // A menu bar app is never "frontmost" by itself, so bring it forward
        // or the dialog can open hidden behind other windows.
        NSApp.activate()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(url)
        onFolderChanged?(url)
    }

    private func save(_ url: URL) {
        folderURL = url
        // A bookmark keeps working even if the folder is renamed or moved.
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return }
        folderURL = url
        if isStale { save(url) } // refresh an outdated bookmark
    }
}
