import Foundation

/// A simple log file for debugging: ~/Library/Application Support/Lang/Logs/lang.log
/// (rotated to lang.1.log at 1 MB). Settings has a "Copy log" button.
enum Log {
    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Lang/Logs", directoryHint: .isDirectory)
    }
    static var fileURL: URL { folder.appending(path: "lang.log") }

    private static let queue = DispatchQueue(label: "MeetingMate.log")
    private static let maxSize = 1_000_000

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(timestamp()) [\(level)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxSize {
                let old = folder.appending(path: "lang.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: fileURL, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// The last ~200 KB of the log (for "Copy log").
    static func recentText() -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return "(log is empty)" }
            return String(decoding: data.suffix(200_000), as: UTF8.self)
        }
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
