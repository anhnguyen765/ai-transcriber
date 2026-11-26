import AVFoundation
import Observation

/// Thread-safe "how loud was the last bit of audio" box.
/// The audio threads call `ingest`; the UI timer calls `take` about 30 times a second.
/// Only measures loudness; never touches what gets recorded.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    /// Loudest RMS of the buffers that arrived since the last `take`.
    private var peakRMS: Float = 0
    private var hasNew = false
    /// What `take` returned last; repeated while no new buffer has arrived.
    private var lastRMS: Float = 0
    private var emptyTakes = 0

    /// Audio arrives in chunks (~85 ms for the mic) but the UI reads 30×/s, so most reads
    /// see no new buffer. Holding the last value avoids flicker; after this many empty reads
    /// (≈ 0.3 s, e.g. ScreenCaptureKit sends nothing during silence) the level fades out.
    static let holdTakes = 10

    /// Called from the audio thread with every captured buffer.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(of: buffer)
        lock.withLock {
            peakRMS = hasNew ? max(peakRMS, rms) : rms
            hasNew = true
        }
    }

    /// The loudest RMS since the last call; without new audio, the previous value
    /// (held briefly, then fading toward silence).
    func take() -> Float {
        lock.withLock {
            if hasNew {
                lastRMS = peakRMS
                hasNew = false
                emptyTakes = 0
            } else {
                emptyTakes += 1
                if emptyTakes > Self.holdTakes { lastRMS *= 0.8 }
            }
            return lastRMS
        }
    }

    /// Root-mean-square of the first channel (float32 or int16 PCM).
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData {
            let stride = buffer.stride
            let samples = data[0]
            for i in 0..<frames {
                let s = samples[i * stride]
                sum += s * s
            }
        } else if let data = buffer.int16ChannelData {
            let stride = buffer.stride
            let samples = data[0]
            for i in 0..<frames {
                let s = Float(samples[i * stride]) / Float(Int16.max)
                sum += s * s
            }
        } else {
            return 0
        }
        return (sum / Float(frames)).squareRoot()
    }

    /// RMS → 0…1 for the UI: -50 dBFS (quiet room) = 0, -10 dBFS (loud voice) = 1.
    static func normalized(_ rms: Float, floorDB: Float = -50, ceilingDB: Float = -10) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return Double(min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1))
    }

    /// Fast rise, slow fall, so rings react quickly to speech and settle calmly.
    static func smooth(current: Double, target: Double, attack: Double = 0.3, release: Double = 0.08) -> Double {
        let factor = target > current ? attack : release
        return current + (target - current) * factor
    }
}

/// Live, smoothed mic and system levels for the UI (ripple rings, tiny waveforms, NotchIsland).
/// Kept separate from `Recorder` so 30 updates a second only redraw the views that show levels.
@MainActor
@Observable
final class AudioLevels {
    /// 0…1, smoothed.
    private(set) var mic: Double = 0
    private(set) var system: Double = 0
    /// The last few values (oldest first) for the 8-bar legend waveforms.
    private(set) var micHistory: [Double] = Array(repeating: 0, count: AudioLevels.historyCount)
    private(set) var systemHistory: [Double] = Array(repeating: 0, count: AudioLevels.historyCount)

    static let historyCount = 8
    /// Push a history bar every N frames (≈ 7.5 bars per second at 30 fps).
    private static let historyEvery = 4

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var frame = 0

    func start(mic micMeter: AudioLevelMeter, system systemMeter: AudioLevelMeter) {
        stop()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick(mic: AudioLevelMeter.normalized(micMeter.take()),
                           system: AudioLevelMeter.normalized(systemMeter.take()))
            }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps running while the popover is open
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        mic = 0
        system = 0
        micHistory = Array(repeating: 0, count: Self.historyCount)
        systemHistory = micHistory
        frame = 0
    }

    /// One 30 fps step (also used by previews and tests).
    func tick(mic newMic: Double, system newSystem: Double) {
        mic = AudioLevelMeter.smooth(current: mic, target: newMic)
        system = AudioLevelMeter.smooth(current: system, target: newSystem)
        frame += 1
        if frame % Self.historyEvery == 0 {
            micHistory = Array(micHistory.dropFirst()) + [mic]
            systemHistory = Array(systemHistory.dropFirst()) + [system]
        }
    }
}
