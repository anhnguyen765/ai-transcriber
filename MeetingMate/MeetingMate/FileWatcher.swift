import CoreServices
import Foundation

/// Watches a folder with FSEvents and calls `onChange` (on the main thread) once files
/// have stopped changing for `delay` seconds. Changes to files we never index are ignored.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "MeetingMate.fileWatcher")
    private let delay: TimeInterval
    private let onChange: @MainActor () -> Void
    private var pending: DispatchWorkItem?

    init(folder: URL, delay: TimeInterval, onChange: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.onChange = onChange

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.received(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        pending?.cancel()
    }

    /// Runs on `queue`.
    private func received(_ paths: [String]) {
        guard paths.contains(where: Self.isRelevant) else { return }
        // Debounce: restart the countdown on every change.
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in
            Task { @MainActor in onChange() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Could this path matter to the index? (Recording audio files, .git internals etc. don't.)
    static func isRelevant(_ path: String) -> Bool {
        if path.contains("/.git/") || path.contains("/node_modules/") { return false }
        let name = (path as NSString).lastPathComponent
        if name == ".langignore" { return true }
        if name.hasPrefix(".") { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return true } // probably a folder (created, renamed or deleted)
        if path.contains("/.meetings/") { return ProjectScanner.meetingFiles.contains(name) }
        return ProjectScanner.docExtensions.contains(ext) || ProjectScanner.codeExtensions.contains(ext)
    }
}
