import Foundation

/// One searchable piece of a file.
struct TextChunk: Equatable {
    var text: String
    /// Where it is in the file: a heading path ("Plan > Timeline"), a time range
    /// ("00:03:00–00:06:00") or a line range ("lines 1–80").
    var location: String
}

/// Splits file text into chunks, depending on the kind of file.
enum Chunker {
    static let wordsPerChunk = 500
    static let overlapWords = 50
    static let linesPerCodeChunk = 80
    static let transcriptWindow = 180.0 // seconds

    static func chunks(for file: ProjectFile, text: String) -> [TextChunk] {
        if file.sourceType == .meeting, file.url.lastPathComponent == TranscriptWriter.markdownFileName {
            return transcript(text)
        }
        switch file.sourceType {
        case .code:
            return code(text, fileExtension: file.fileExtension)
        case .doc, .meeting:
            return ["md", "markdown"].contains(file.fileExtension) || file.sourceType == .meeting
                ? markdown(text)
                : plain(text)
        }
    }

    // MARK: - Markdown: by heading, then ~500 words with 50 overlap

    static func markdown(_ text: String) -> [TextChunk] {
        var result: [TextChunk] = []
        var headings: [(level: Int, title: String)] = []
        var body: [String] = []
        var insideCodeBlock = false

        func flush() {
            defer { body = [] }
            // A heading with no text under it isn't worth its own chunk.
            let hasContent = body.contains { heading($0) == nil && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard hasContent else { return }
            let location = headings.map(\.title).joined(separator: " > ")
            result += words(body.joined(separator: "\n"), location: location)
        }

        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { insideCodeBlock.toggle() }
            if !insideCodeBlock, let heading = heading(line) {
                flush()
                headings.removeAll { $0.level >= heading.level }
                headings.append(heading)
                body.append(line) // keep the heading text in the chunk for search
            } else {
                body.append(line)
            }
        }
        flush()
        return result
    }

    private static func heading(_ line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Plain text (txt, pdf, docx, csv…): ~500 words with 50 overlap

    static func plain(_ text: String) -> [TextChunk] {
        words(text, location: "")
    }

    /// Windows of `wordsPerChunk` words, each starting `wordsPerChunk - overlapWords` after the last.
    static func words(_ text: String, location: String) -> [TextChunk] {
        let all = text.split(whereSeparator: \.isWhitespace)
        guard !all.isEmpty else { return [] }
        var result: [TextChunk] = []
        var start = 0
        let step = wordsPerChunk - overlapWords
        while start < all.count {
            let end = min(start + wordsPerChunk, all.count)
            let part = all[start..<end].joined(separator: " ")
            let suffix = all.count > wordsPerChunk ? " (\(result.count + 1))" : ""
            result.append(TextChunk(text: part, location: location.isEmpty ? "part\(suffix)" : location + suffix))
            if end == all.count { break }
            start += step
        }
        return result
    }

    // MARK: - Code: top-level functions/types, otherwise ~80 lines

    /// Lines that start a top-level declaration (no indentation).
    private static let topLevelStarts: [String: NSRegularExpression] = {
        let patterns: [String: String] = [
            "swift": #"^(@\w+\s+)*(public |private |fileprivate |internal |open |final )*(func|class|struct|enum|protocol|extension|actor|typealias)\b"#,
            "py": #"^(async\s+)?(def|class)\s"#,
            "js": #"^(export\s+)?(default\s+)?(async\s+)?(function|class|const|let|var)\b"#,
            "css": #"^[^\s{}/][^{]*\{"#,
            "html": #"^\s{0,2}<(head|body|section|main|header|footer|script|style|div)\b"#,
        ]
        var result: [String: NSRegularExpression] = [:]
        for (ext, pattern) in patterns { result[ext] = try? NSRegularExpression(pattern: pattern) }
        for ext in ["jsx", "mjs", "ts", "tsx"] { result[ext] = result["js"] }
        return result
    }()

    static func code(_ text: String, fileExtension: String) -> [TextChunk] {
        let lines = text.components(separatedBy: .newlines)
        guard !lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return [] }

        // Where top-level declarations start (0-based line numbers).
        var starts: [Int] = [0]
        if let regex = topLevelStarts[fileExtension] {
            for (i, line) in lines.enumerated() where i > 0 {
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { starts.append(i) }
            }
        }

        // Turn declaration starts into blocks; merge tiny neighbours, split huge ones.
        var blocks: [Range<Int>] = []
        let bounds = starts + [lines.count]
        var current = bounds[0]..<bounds[0]
        for i in 0..<(bounds.count - 1) {
            let next = bounds[i]..<bounds[i + 1]
            if current.count + next.count <= linesPerCodeChunk {
                current = current.lowerBound..<next.upperBound
            } else {
                if !current.isEmpty { blocks.append(current) }
                current = next
            }
        }
        if !current.isEmpty { blocks.append(current) }

        var result: [TextChunk] = []
        for block in blocks {
            var start = block.lowerBound
            while start < block.upperBound {
                let end = min(start + linesPerCodeChunk, block.upperBound)
                let text = lines[start..<end].joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(TextChunk(text: text, location: "lines \(start + 1)–\(end)"))
                }
                start = end
            }
        }
        return result
    }

    // MARK: - Meeting transcripts: ~3-minute windows, keeping timestamps

    static func transcript(_ text: String) -> [TextChunk] {
        var result: [TextChunk] = []
        var window: [String] = []
        var windowStart: Double?
        var lastTime = 0.0

        func flush() {
            guard let start = windowStart, !window.isEmpty else { return }
            let from = TranscriptWriter.timestamp(start), to = TranscriptWriter.timestamp(lastTime)
            result.append(TextChunk(text: window.joined(separator: "\n"), location: "\(from)–\(to)"))
            window = []
            windowStart = nil
        }

        for line in text.components(separatedBy: .newlines) {
            guard let time = timestamp(in: line) else { continue } // skips the title/duration header
            if let start = windowStart, time - start >= transcriptWindow { flush() }
            if windowStart == nil { windowStart = time }
            window.append(line)
            lastTime = time
        }
        flush()
        return result
    }

    /// "[00:12:30] Người khác: …" → 750
    static func timestamp(in line: String) -> Double? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let parts = line[line.index(after: line.startIndex)..<close].split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
