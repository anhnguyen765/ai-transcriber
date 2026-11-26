import Foundation
import Testing
@testable import MeetingMate

// MARK: - Chunker

struct ChunkerTests {
    @Test func markdownSplitsByHeadingAndKeepsHeadingPath() {
        let md = """
        # Kế hoạch
        Mở đầu ngắn.

        ## Timeline
        Ra mắt vào tháng 12.

        ## Ngân sách
        200 triệu.

        # Trống

        """
        let chunks = Chunker.markdown(md)
        #expect(chunks.map(\.location) == ["Kế hoạch", "Kế hoạch > Timeline", "Kế hoạch > Ngân sách"])
        #expect(chunks[1].text.contains("Ra mắt vào tháng 12."))
        #expect(chunks[1].text.contains("## Timeline")) // heading text stays searchable
    }

    @Test func markdownIgnoresHashesInsideCodeBlocks() {
        let md = "# Setup\nRun this:\n```\n# not a heading\nmake\n```\nDone."
        #expect(Chunker.markdown(md).count == 1)
    }

    @Test func longSectionsBecome500WordWindowsWith50Overlap() {
        let words = (0..<1_200).map { "w\($0)" }
        let chunks = Chunker.words(words.joined(separator: " "), location: "Doc")
        #expect(chunks.count == 3) // starts at 0, 450, 900
        #expect(chunks.allSatisfy { $0.text.split(separator: " ").count <= 500 })
        #expect(chunks[1].text.hasPrefix("w450 "))
        #expect(chunks[0].text.hasSuffix(" w499")) // 450…499 overlap with the next chunk
        #expect(chunks[2].text.hasSuffix("w1199"))
    }

    @Test func codeSplitsAtTopLevelDeclarations() {
        let function = { (name: String) in
            (["func \(name)() {"] + (0..<50).map { "    let v\($0) = \($0)" } + ["}"]).joined(separator: "\n")
        }
        let swift = [function("a"), function("b"), function("c")].joined(separator: "\n")
        let chunks = Chunker.code(swift, fileExtension: "swift")
        #expect(chunks.count == 3) // each 52-line function alone; two together would pass 80 lines
        #expect(chunks.map(\.location) == ["lines 1–52", "lines 53–104", "lines 105–156"])
        #expect(chunks[1].text.hasPrefix("func b()"))
    }

    @Test func codeFallsBackTo80LineWindows() {
        let text = (1...200).map { "    line \($0)" }.joined(separator: "\n") // no top-level declarations
        let chunks = Chunker.code(text, fileExtension: "swift")
        #expect(chunks.map(\.location) == ["lines 1–80", "lines 81–160", "lines 161–200"])
    }

    @Test func transcriptSplitsInto3MinuteWindowsWithTimestamps() {
        let md = """
        # Cuộc họp 2026-11-25 22:07

        Thời lượng: 05:14 · Project: 2027

        [00:00:05] Người khác: Chào mọi người

        [00:02:50] Tôi: Ok

        [00:03:10] Người khác: Tiếp theo

        [00:06:20] Tôi: Hết
        """
        let chunks = Chunker.transcript(md)
        #expect(chunks.map(\.location) == ["00:00:05–00:02:50", "00:03:10–00:03:10", "00:06:20–00:06:20"])
        #expect(chunks[0].text == "[00:00:05] Người khác: Chào mọi người\n[00:02:50] Tôi: Ok")
    }
}

// MARK: - Ignore rules

struct IgnoreRulesTests {
    private let rules = IgnoreRules(patterns: [
        "# comment",
        "*.log",
        "secret/",
        "/drafts",
        "docs/**/old.md",
        "!keep.log",
    ])

    @Test func globAnywhereByName() {
        #expect(rules.isIgnored("a/b/debug.log", isDirectory: false))
        #expect(!rules.isIgnored("a/b/debug.txt", isDirectory: false))
    }

    @Test func negationWins() {
        #expect(!rules.isIgnored("x/keep.log", isDirectory: false))
    }

    @Test func trailingSlashMeansFoldersOnly() {
        #expect(rules.isIgnored("sub/secret", isDirectory: true))
        #expect(!rules.isIgnored("sub/secret", isDirectory: false))
    }

    @Test func leadingSlashIsRelativeToRoot() {
        #expect(rules.isIgnored("drafts", isDirectory: true))
        #expect(!rules.isIgnored("notes/drafts", isDirectory: true))
    }

    @Test func doubleStarMatchesAnyDepth() {
        #expect(rules.isIgnored("docs/old.md", isDirectory: false))
        #expect(rules.isIgnored("docs/a/b/old.md", isDirectory: false))
        #expect(!rules.isIgnored("other/old.md", isDirectory: false))
    }
}

// MARK: - Scanner on a temporary folder

struct ProjectScannerTests {
    @Test func picksTheRightFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lang-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String = "hello") throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("README.md")
        try write("src/app.swift")
        try write("notes/ideas.txt")
        try write("photo.png")                        // not a text type
        try write("node_modules/lib/index.js")        // built-in ignore
        try write(".git/config.json")                 // hidden folder
        try write(".hidden/a.md")                     // hidden folder
        try write("big.txt", String(repeating: "x", count: 3_000))
        try write("private/plan.md")                  // .langignore
        try write(".langignore", "private/\n")
        try write(".meetings/2026-11-25_22-07-16/summary.md")
        try write(".meetings/2026-11-25_22-07-16/transcript.md")
        try write(".meetings/2026-11-25_22-07-16/meta.json") // only summary/transcript in meetings
        try write(".meetings/glossary.txt")

        let files = ProjectScanner.scan(root: root, maxFileSize: 2_000, extraPatterns: [])
        #expect(files.map(\.relativePath) == [
            ".meetings/2026-11-25_22-07-16/summary.md",
            ".meetings/2026-11-25_22-07-16/transcript.md",
            "README.md",
            "notes/ideas.txt",
            "src/app.swift",
        ])
        #expect(files.first?.sourceType == .meeting)
        #expect(files.first?.meetingDate != nil)
        #expect(files.last?.sourceType == .code)
    }
}
