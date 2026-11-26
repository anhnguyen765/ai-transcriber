import Foundation

/// Tells "I am speaking" apart from "the other side's voice coming out of the Mac speakers
/// and leaking into the mic", using only loudness (no AI).
///
/// Idea: when only the other side talks, the mic hears a quieter copy of system.m4a. We learn how
/// much quieter (the "leak gain") from the recording itself. A moment counts as ME speaking when
/// the mic is clearly louder than that expected leak.
struct LeakageDetector {
    /// Loudness is measured in 100 ms frames.
    static let frameSeconds = 0.1
    /// Mic must be 2× (6 dB) louder than the expected leak to count as my voice.
    static let userMargin: Float = 2.0
    /// A mic segment is leakage if the other side was talking during ≥ 25% of it
    /// and I was audible during < 25% of it.
    static let minSystemActive = 0.25
    static let maxUserActive = 0.25

    /// Loudness (RMS, 0…1) per frame.
    let mic: [Float]
    let system: [Float]
    /// mic loudness ≈ leakGain × system loudness, when only the other side talks.
    let leakGain: Float
    /// Below this the mic is just background noise.
    let micNoiseGate: Float
    /// Above this the system track has sound (the other side is talking).
    let systemGate: Float = 0.003 // about -50 dBFS

    /// Returns nil if there is too little system audio to learn the leak gain from.
    init?(mic: [Float], system: [Float]) {
        self.mic = mic
        self.system = system

        // Learn the leak gain from frames where the system track is clearly playing.
        let ratios = zip(mic, system)
            .filter { $0.1 > 0.01 } // louder than about -40 dBFS
            .map { $0.0 / $0.1 }
            .sorted()
        guard ratios.count >= 30 else { return nil } // need at least ~3 s of the other side
        leakGain = ratios[ratios.count / 2] // median: robust against moments where we both talk

        // Noise gate: twice the mic's background level, measured while the other side is silent
        // (so the leak doesn't count as "background"). At least about -46 dBFS.
        let micWhileSystemSilent = zip(mic, system)
            .filter { $0.1 <= 0.003 }
            .map(\.0)
            .sorted()
        let background = micWhileSystemSilent.count >= 10 ? micWhileSystemSilent[micWhileSystemSilent.count / 5] : 0
        micNoiseGate = max(0.005, background * 2)
    }

    /// Is my voice audible in this frame (more than noise and more than the expected leak)?
    func isUserFrame(_ i: Int) -> Bool {
        let m = mic[i]
        let s = i < system.count ? system[i] : 0
        return m > micNoiseGate && m > Self.userMargin * leakGain * s
    }

    func isSystemFrame(_ i: Int) -> Bool {
        i < system.count && system[i] > systemGate
    }

    /// True if a mic segment (seconds) is just the other side leaking through the speakers.
    func isLeakage(start: Double, end: Double) -> Bool {
        let first = max(0, Int(start / Self.frameSeconds))
        let last = min(mic.count, Int((end / Self.frameSeconds).rounded(.up)))
        guard last > first else { return false }
        let frames = first..<last
        let count = Double(frames.count)
        let systemActive = Double(frames.filter(isSystemFrame).count) / count
        let userActive = Double(frames.filter(isUserFrame).count) / count
        return systemActive >= Self.minSystemActive && userActive < Self.maxUserActive
    }

    // MARK: - Measuring loudness from files

    /// Builds a detector from mic.m4a and system.m4a (nil if it can't learn anything useful).
    static func make(micURL: URL, systemURL: URL) async -> LeakageDetector? {
        guard let mic = try? await loudness(of: micURL),
              let system = try? await loudness(of: systemURL) else { return nil }
        return LeakageDetector(mic: mic, system: system)
    }

    /// RMS loudness per 100 ms frame, reading the file a few minutes at a time.
    static func loudness(of url: URL) async throws -> [Float] {
        let reader = try await AudioPieceReader(url: url)
        let frameSize = Int(16_000 * frameSeconds)
        var result: [Float] = []
        var leftover: [Float] = []
        while let piece = try reader.nextPiece(seconds: 120) {
            let samples = leftover + piece.samples
            var i = 0
            while i + frameSize <= samples.count {
                var sum: Float = 0
                for j in i..<(i + frameSize) { sum += samples[j] * samples[j] }
                result.append((sum / Float(frameSize)).squareRoot())
                i += frameSize
            }
            leftover = Array(samples[i...])
        }
        return result
    }
}
