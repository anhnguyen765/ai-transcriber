import Foundation

/// Turns transcript.json into text for the LLM and splits long meetings into parts.
enum TranscriptChunker {
    /// One part of a long meeting.
    struct Chunk: Equatable {
        var lines: [String]
        var start: Double
        var end: Double
        var text: String { lines.joined(separator: "\n") }
    }

    /// Vietnamese averages roughly 2.5 characters per token; we round up to stay on the safe side.
    static func estimateTokens(_ text: String) -> Int {
        Int((Double(text.count) / 2.5).rounded(.up))
    }

    /// "[00:12:30] Anh: text". The "Tôi" label is replaced with my name so the model knows who I am.
    static func format(_ line: TranscriptLine, myName: String) -> String {
        var speaker = line.speaker
        let name = myName.trimmingCharacters(in: .whitespaces)
        if speaker == TranscriptTrack.mic.speaker, !name.isEmpty { speaker = name }
        return "[\(TranscriptWriter.timestamp(line.start))] \(speaker): \(line.text)"
    }

    static func fullText(_ lines: [TranscriptLine], myName: String) -> String {
        lines.map { format($0, myName: myName) }.joined(separator: "\n")
    }

    /// Splits into parts of about `maxSeconds`, never cutting a line in two, and never exceeding
    /// `maxTokens` per part. A single line longer than `maxTokens` (a very long monologue) is the
    /// only thing ever split, at word boundaries, keeping its timestamp on each piece.
    static func chunks(_ lines: [TranscriptLine], myName: String,
                       maxSeconds: Double = 600, maxTokens: Int = 4_500) -> [Chunk] {
        var result: [Chunk] = []
        var current: Chunk?
        var currentTokens = 0

        for line in lines {
            for piece in pieces(of: line, myName: myName, maxTokens: maxTokens) {
                let tokens = estimateTokens(piece) + 1 // +1 for the newline
                if let chunk = current,
                   line.start - chunk.start >= maxSeconds || currentTokens + tokens > maxTokens {
                    result.append(chunk)
                    current = nil
                    currentTokens = 0
                }
                var chunk = current ?? Chunk(lines: [], start: line.start, end: line.end)
                chunk.lines.append(piece)
                chunk.end = max(chunk.end, line.end)
                current = chunk
                currentTokens += tokens
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// The formatted line, split at word boundaries only if it alone is over the token limit.
    private static func pieces(of line: TranscriptLine, myName: String, maxTokens: Int) -> [String] {
        let full = format(line, myName: myName)
        guard estimateTokens(full) > maxTokens else { return [full] }

        let prefix = String(full.prefix(upTo: full.range(of: ": ")?.upperBound ?? full.startIndex))
        let budget = max(1, maxTokens - estimateTokens(prefix) - 1)
        var pieces: [String] = []
        var words: [Substring] = []
        for word in line.text.split(separator: " ") {
            let candidate = (words + [word]).joined(separator: " ")
            if !words.isEmpty, estimateTokens(candidate) > budget {
                pieces.append(prefix + words.joined(separator: " "))
                words = [word]
            } else {
                words.append(word)
            }
        }
        if !words.isEmpty { pieces.append(prefix + words.joined(separator: " ")) }
        return pieces
    }
}
