import AVFoundation
import Testing
@testable import MeetingMate

struct AudioLevelTests {
    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }
        return buffer
    }

    @Test func rmsOfSilenceAndSquareWave() {
        #expect(AudioLevelMeter.rms(of: buffer(Array(repeating: 0, count: 480))) == 0)
        let square = (0..<480).map { $0 % 2 == 0 ? Float(0.5) : -0.5 }
        #expect(abs(AudioLevelMeter.rms(of: buffer(square)) - 0.5) < 0.0001)
    }

    @Test func normalizedMapsDecibelsToZeroOne() {
        #expect(AudioLevelMeter.normalized(0) == 0)
        #expect(AudioLevelMeter.normalized(0.001) == 0)          // -60 dB: below the floor
        #expect(AudioLevelMeter.normalized(1) == 1)              // 0 dB: above the ceiling
        let mid = AudioLevelMeter.normalized(pow(10, -30 / 20))  // -30 dB: halfway
        #expect(abs(mid - 0.5) < 0.001)
    }

    @Test func smoothingRisesFastFallsSlow() {
        let up = AudioLevelMeter.smooth(current: 0, target: 1)
        let down = AudioLevelMeter.smooth(current: 1, target: 0)
        #expect(up > 0.25)              // rises noticeably in one frame
        #expect(down > 0.9)             // falls slowly
    }

    @Test func meterKeepsLoudestUntilTaken() {
        let meter = AudioLevelMeter()
        meter.ingest(buffer(Array(repeating: 0.1, count: 64)))
        meter.ingest(buffer(Array(repeating: 0.4, count: 64)))
        meter.ingest(buffer(Array(repeating: 0.2, count: 64)))
        #expect(abs(meter.take() - 0.4) < 0.0001)
        // Next buffer: only what arrived after the last read counts.
        meter.ingest(buffer(Array(repeating: 0.2, count: 64)))
        #expect(abs(meter.take() - 0.2) < 0.0001)
    }

    /// No flicker: between audio buffers the level is held, not dropped to zero.
    @Test func meterHoldsBetweenBuffersThenFades() {
        let meter = AudioLevelMeter()
        meter.ingest(buffer(Array(repeating: 0.4, count: 64)))
        _ = meter.take()
        for _ in 0..<AudioLevelMeter.holdTakes {
            #expect(abs(meter.take() - 0.4) < 0.0001)
        }
        var last = meter.take()
        #expect(last < 0.4)
        for _ in 0..<40 { last = meter.take() }
        #expect(last < 0.01)
    }

    @MainActor @Test func levelsKeepEightBarHistory() {
        let levels = AudioLevels()
        for _ in 0..<40 { levels.tick(mic: 1, system: 0) }
        #expect(levels.micHistory.count == AudioLevels.historyCount)
        #expect(levels.micHistory.last! > 0.9)
        #expect(levels.systemHistory.allSatisfy { $0 == 0 })
        levels.stop()
        #expect(levels.mic == 0)
    }
}
