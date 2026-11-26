import AppKit

/// Opens a source from an answer the same way everywhere:
/// a meeting → that meeting in the main window at the cited moment; a document → its file.
@MainActor
enum SourceOpener {
    static func open(_ source: AnswerSource, projectFolder: URL?, router: Router) {
        guard let projectFolder else { return }
        if let folder = SourceLink.meetingFolder(source) {
            router.openMeeting(projectFolder.appending(path: folder), at: SourceLink.startTime(source))
            return
        }
        let url = SourceLink.fileURL(source, projectFolder: projectFolder)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep() // the file was moved or deleted since it was indexed
        }
    }
}
