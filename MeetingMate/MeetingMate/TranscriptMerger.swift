import Foundation

/// Which recording a line came from.
enum TranscriptTrack: String, Codable {
    case mic, system, file

    /// The speaker label written in the transcript.
    var speaker: String {
        switch self {
        case .mic: "Tôi"
        case .system: "Người khác"
        case .file: "Người nói"
        }
    }
}

/// One line of the final transcript. Times are seconds from the start of the meeting.
struct TranscriptLine: Codable, Equatable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
    var track: TranscriptTrack
}

/// Cleans up raw segments from each track and merges them into one transcript.
/// Pure logic (no audio, no model), so it is covered by unit tests.
enum TranscriptMerger {
    /// Echo: mic text this similar to overlapping system text is dropped.
    static let echoSimilarity = 0.8
    /// Same speaker + gap shorter than this → one paragraph.
    static let paragraphGap = 2.0
    /// Whisper's own "this is not speech" rule.
    static let noSpeechProbability = 0.6
    static let lowConfidenceLogProb = -1.0

    /// Phrases Whisper invents during silence (YouTube outros it learned from). Compared without accents.
    static let hallucinationPhrases = [
        "hay subscribe cho kenh",
        "ghien mi go",
        "de khong bo lo nhung video hap dan",
        "cam on cac ban da theo doi",
        "cam on cac ban da xem video",
        "hay dang ky kenh",
        "nho like va subscribe",
        "dang ky kenh de ung ho",
        "subtitles by the amara",
    ]

    /// - Parameters:
    ///   - tracks: each track's raw segments plus its start offset (seconds after the meeting start;
    ///     0 for our recordings, because both files start at meta.json's startTime).
    ///   - leakage: loudness-based check that drops mic segments which are just the other side
    ///     coming out of the speakers (nil = skip this check).
    static func merge(_ tracks: [(track: TranscriptTrack, offset: Double, segments: [TranscribedSegment])],
                      leakage: LeakageDetector? = nil) -> [TranscriptLine]
    {
        // 1. Clean each track and convert to meeting time.
        var cleaned: [TranscriptTrack: [TranscriptLine]] = [:]
        for (track, offset, segments) in tracks {
            let lines = removeHallucinations(segments).map {
                TranscriptLine(start: $0.start + offset, end: $0.end + offset,
                               speaker: track.speaker, text: $0.text, track: track)
            }
            cleaned[track, default: []].append(contentsOf: lines)
        }

        // 2. Mic lines that are just the other side leaking from the speakers:
        //    first by loudness (most reliable), then by text similarity (catches the rest).
        if let leakage, let mic = cleaned[.mic] {
            cleaned[.mic] = relabelLeakage(mic: mic, system: cleaned[.system] ?? [], leakage: leakage)
        }
        if let mic = cleaned[.mic], let system = cleaned[.system] {
            cleaned[.mic] = removeEcho(mic: mic, system: system)
        }

        // 3. Time order (stable for equal start times).
        let all = cleaned.values.flatMap { $0 }
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)

        // 4. Join consecutive lines from the same speaker into paragraphs.
        return joinParagraphs(all)
    }

    // MARK: - Steps

    static func removeHallucinations(_ segments: [TranscribedSegment]) -> [TranscribedSegment] {
        var result: [TranscribedSegment] = []
        var index = 0
        let usable = segments.map { segment -> TranscribedSegment in
            var copy = segment
            copy.text = removeSoundTags(segment.text)
            return copy
        }.filter { segment in
            let text = normalize(segment.text)
            if text.isEmpty { return false }
            // Whisper says "probably no speech here" AND it isn't confident in the text.
            if let noSpeech = segment.noSpeechProbability, noSpeech > noSpeechProbability,
               let logProb = segment.averageLogProbability, logProb < lowConfidenceLogProb {
                return false
            }
            return !isKnownHallucination(segment.text)
        }

        // The same sentence 3+ times in a row is a decoding loop: keep only the first one.
        while index < usable.count {
            let text = normalize(usable[index].text)
            var runEnd = index + 1
            while runEnd < usable.count, normalize(usable[runEnd].text) == text { runEnd += 1 }
            let runLength = runEnd - index
            if runLength >= 3 {
                result.append(usable[index])
            } else {
                result.append(contentsOf: usable[index..<runEnd])
            }
            index = runEnd
        }
        return result
    }

    /// A mic line that loudness says is the other side's voice:
    /// - if the system track has text at that time → it's a duplicate, drop it;
    /// - if not (Whisper sometimes misses speech in system.m4a) → keep the mic's text,
    ///   but label it "Người khác", so nothing the other side said gets lost.
    static func relabelLeakage(mic: [TranscriptLine], system: [TranscriptLine],
                               leakage: LeakageDetector) -> [TranscriptLine] {
        mic.compactMap { line in
            guard leakage.isLeakage(start: line.start, end: line.end) else { return line }
            let length = max(line.end - line.start, 0.1)
            let covered = system.reduce(0.0) { sum, s in
                sum + max(0, min(s.end, line.end) - max(s.start, line.start))
            }
            if covered / length >= 0.3 { return nil }
            var relabeled = line
            relabeled.speaker = TranscriptTrack.system.speaker
            return relabeled // track stays .mic: the text came from the mic recording
        }
    }

    static func removeEcho(mic: [TranscriptLine], system: [TranscriptLine]) -> [TranscriptLine] {
        mic.filter { micLine in
            // Lines already identified as the other side (relabeled leakage) are kept.
            guard micLine.speaker == TranscriptTrack.mic.speaker else { return true }
            let overlapping = system.filter { $0.start < micLine.end && micLine.start < $0.end }
            guard !overlapping.isEmpty else { return true }
            let micText = normalize(micLine.text)
            // Compare with each overlapping system line and with all of them joined
            // (one mic segment can span two system segments).
            let candidates = overlapping.map { normalize($0.text) }
                + [normalize(overlapping.map(\.text).joined(separator: " "))]
            let best = candidates.map { similarity(micText, $0) }.max() ?? 0
            return best <= echoSimilarity
        }
    }

    static func joinParagraphs(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        for line in lines {
            if var last = result.last, last.speaker == line.speaker,
               line.start - last.end < paragraphGap {
                last.text += " " + line.text
                last.end = max(last.end, line.end)
                result[result.count - 1] = last
            } else {
                result.append(line)
            }
        }
        return result
    }

    // MARK: - Text helpers

    /// True for text Whisper typically invents during silence ("Hãy subscribe cho kênh…").
    static func isKnownHallucination(_ text: String) -> Bool {
        let normalized = normalize(text)
        return hallucinationPhrases.contains { normalized.contains($0) }
    }

    /// Whisper writes sounds as *chúi*, [Âm nhạc] or (cười). Remove those, keep the real words.
    static func removeSoundTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"\*[^*]*\*|\[[^\]]*\]|\([^)]*\)"#, with: " ",
                                  options: .regularExpression)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Lowercase, no accents (đ → d), no punctuation, single spaces.
    static func normalize(_ text: String) -> String {
        let folded = text.lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi_VN"))
        let kept = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// 1.0 = identical, 0.0 = completely different (based on edit distance).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return x.count == y.count ? 1 : 0 }
        // Classic Levenshtein edit distance, keeping only two rows in memory.
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}
