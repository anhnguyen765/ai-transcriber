import AppKit
import Foundation
import PDFKit

/// What kind of source a chunk comes from.
enum SourceType: String, Codable {
    case doc, code, meeting
}

/// A file in the project that we can index.
struct ProjectFile: Equatable {
    let url: URL
    /// Path relative to the project folder, e.g. "docs/plan.md".
    let relativePath: String
    let size: Int
    let modified: Date
    let sourceType: SourceType
    /// For past meetings: when the meeting happened (from the folder name).
    let meetingDate: Date?

    var fileExtension: String { url.pathExtension.lowercased() }
}

// MARK: - Finding files

enum ProjectScanner {
    static let docExtensions: Set<String> = ["md", "markdown", "txt", "rtf", "csv", "json", "pdf", "docx"]
    static let codeExtensions: Set<String> = ["swift", "js", "jsx", "mjs", "ts", "tsx", "py", "html", "css"]
    /// Files we read inside .meetings/<timestamp>/.
    static let meetingFiles: Set<String> = [SummaryWriter.markdownFileName, TranscriptWriter.markdownFileName]

    /// Folders that are never worth indexing.
    static let builtInIgnores = [
        ".git/", "node_modules/", "build/", "Build/", "DerivedData/", ".build/", "dist/", "out/",
        "Pods/", "Carthage/", "vendor/", "__pycache__/", ".venv/", "venv/", "*.xcodeproj/", "*.xcworkspace/",
    ]

    /// All indexable files under `root`. Never follows symlinks out of the project.
    static func scan(root: URL, maxFileSize: Int, extraPatterns: [String]) -> [ProjectFile] {
        var patterns = builtInIgnores + extraPatterns
        if let text = try? String(contentsOf: root.appending(path: ".langignore"), encoding: .utf8) {
            patterns += text.components(separatedBy: .newlines)
        }
        let rules = IgnoreRules(patterns: patterns)
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey,
                                      .contentModificationDateKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }

        var files: [ProjectFile] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            let relative = relativePath(of: url, in: root)
            let name = url.lastPathComponent
            let isDirectory = values.isDirectory == true

            if isDirectory {
                // Hidden folders are skipped, except the top-level .meetings folder.
                let hidden = name.hasPrefix(".") && relative != ".meetings"
                if hidden || rules.isIgnored(relative, isDirectory: true) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, !name.hasPrefix("."),
                  !rules.isIgnored(relative, isDirectory: false) else { continue }
            let size = values.fileSize ?? 0
            guard size > 0, size <= maxFileSize else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            let ext = url.pathExtension.lowercased()

            if relative.hasPrefix(".meetings/") {
                // Only .meetings/<timestamp>/summary.md and transcript.md.
                let parts = relative.split(separator: "/")
                guard parts.count == 3, meetingFiles.contains(name) else { continue }
                files.append(ProjectFile(url: url, relativePath: relative, size: size, modified: modified,
                                         sourceType: .meeting, meetingDate: meetingDate(String(parts[1]))))
            } else if docExtensions.contains(ext) {
                files.append(ProjectFile(url: url, relativePath: relative, size: size, modified: modified,
                                         sourceType: .doc, meetingDate: nil))
            } else if codeExtensions.contains(ext) {
                files.append(ProjectFile(url: url, relativePath: relative, size: size, modified: modified,
                                         sourceType: .code, meetingDate: nil))
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    /// "2026-11-25_22-07-16" → Date
    static func meetingDate(_ folderName: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.date(from: folderName)
    }
}

// MARK: - Reading text

enum DocumentLoader {
    /// Plain text of a file, whatever its format.
    static func text(of file: ProjectFile) throws -> String {
        switch file.fileExtension {
        case "pdf":
            guard let pdf = PDFDocument(url: file.url) else { throw RecorderError("Can't open this PDF.") }
            return pdf.string ?? "" // scanned PDFs without a text layer give no text
        case "docx":
            return try attributedText(file.url, type: .officeOpenXML)
        case "rtf":
            return try attributedText(file.url, type: .rtf)
        default:
            if let text = try? String(contentsOf: file.url, encoding: .utf8) { return text }
            return try String(contentsOf: file.url, encoding: .isoLatin1) // last resort for odd encodings
        }
    }

    private static func attributedText(_ url: URL, type: NSAttributedString.DocumentType) throws -> String {
        try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
    }
}

// MARK: - .langignore (gitignore-style)

/// Supports the common gitignore syntax: `*`, `**`, `?`, trailing `/` (folders only),
/// leading `/` or a `/` inside (relative to the project root), `!` (un-ignore) and `#` comments.
/// Later rules win, like in git.
struct IgnoreRules {
    private struct Rule {
        let regex: NSRegularExpression
        let negated: Bool
        let directoryOnly: Bool
        let matchesFullPath: Bool
    }

    private let rules: [Rule]

    init(patterns: [String]) {
        rules = patterns.compactMap(Self.rule)
    }

    func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        let name = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        var ignored = false
        for rule in rules where !rule.directoryOnly || isDirectory {
            let subject = rule.matchesFullPath ? relativePath : name
            let range = NSRange(subject.startIndex..., in: subject)
            if rule.regex.firstMatch(in: subject, range: range) != nil {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    private static func rule(_ raw: String) -> Rule? {
        var pattern = raw.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }
        let negated = pattern.hasPrefix("!")
        if negated { pattern.removeFirst() }
        let directoryOnly = pattern.hasSuffix("/")
        if directoryOnly { pattern.removeLast() }
        // A slash at the start or in the middle ties the pattern to the project root.
        let matchesFullPath = pattern.contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: "^" + globToRegex(pattern) + "$") else { return nil }
        return Rule(regex: regex, negated: negated, directoryOnly: directoryOnly, matchesFullPath: matchesFullPath)
    }

    private static func globToRegex(_ glob: String) -> String {
        var regex = ""
        var chars = Array(glob)[...]
        while let c = chars.popFirst() {
            switch c {
            case "*":
                if chars.first == "*" {
                    chars.removeFirst()
                    if chars.first == "/" {
                        chars.removeFirst()
                        regex += "(?:.*/)?" // "**/" = any number of folders (including none)
                    } else {
                        regex += ".*"       // "**" = anything, across folders
                    }
                } else {
                    regex += "[^/]*"        // "*" = anything inside one name
                }
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        return regex
    }
}
