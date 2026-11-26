import AVFoundation

/// Records the microphone (48 kHz, mono) to a crash-safe CAF file; Stop converts it to mic.m4a.
///
/// Sync trick: `prepare` starts the mic but writes nothing. Audio is only written
/// between the shared start and stop times that `Recorder` hands to both recorders,
/// so mic.m4a and system.m4a cover the same moment.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?

    // The tap runs on an audio thread; the lock protects the values it shares with stop().
    private let lock = NSLock()
    private var startHostTime: UInt64 = .max
    private var stopHostTime: UInt64 = .max
    private(set) var writeError: String?
    /// Live loudness for the UI (read-only measurement, does not affect the file).
    let level = AudioLevelMeter()

    /// What we write: 48 kHz mono float samples (AVAudioFile encodes them to AAC).
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000, channels: 1, interleaved: false)!

    func prepare(url: URL) throws {
        let input = engine.inputNode
        // The mic's own format (often 48 kHz or 44.1 kHz, 1+ channels).
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError("No microphone input found.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError("Can't convert the microphone audio to 48 kHz mono.")
        }
        converter.downmix = true // mix stereo/multi-channel mics down to mono
        self.converter = converter

        // Crash-safe 16-bit PCM CAF while recording; Recorder turns it into mic.m4a at Stop.
        file = try AVAudioFile(forWriting: url, settings: RecordingFiles.pcmSettings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.level.ingest(buffer)
            self?.handle(buffer, time: time)
        }
        engine.prepare()
        try engine.start()
    }

    /// Start keeping audio from this moment (mach host time).
    func beginWriting(at hostTime: UInt64) {
        lock.withLock { startHostTime = hostTime }
    }

    /// Stop capturing and close the file. Safe to call more than once.
    func stop(at hostTime: UInt64) {
        lock.withLock { stopHostTime = hostTime }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Releasing the AVAudioFile flushes the last audio and closes the file.
        lock.withLock {
            file = nil
            converter = nil
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, let converter else { return }

        let bufferTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
        guard bufferTime >= startHostTime, bufferTime < stopHostTime else { return }

        // Convert this chunk to 48 kHz mono.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var handedOver = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            // Give the converter our one buffer, then tell it "no more for now".
            if handedOver {
                status.pointee = .noDataNow
                return nil
            }
            handedOver = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            writeError = "Mic conversion failed: \(error.localizedDescription)"
            return
        }
        do {
            try file.write(from: converted)
        } catch {
            writeError = "Writing mic.m4a failed: \(error.localizedDescription)"
        }
    }
}
