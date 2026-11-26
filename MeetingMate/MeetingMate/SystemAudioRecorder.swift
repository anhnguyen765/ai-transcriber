import AVFoundation
import ScreenCaptureKit

/// Records everything the Mac plays (Zoom, Meet, browser…) at 48 kHz mono using ScreenCaptureKit,
/// into a crash-safe CAF file (Stop converts it to system.m4a). Needs the Screen Recording permission.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?

    // All sample handling happens on this queue; the values below are only touched on it.
    private let queue = DispatchQueue(label: "MeetingMate.systemAudio")
    private var startTime = CMTime.positiveInfinity
    private var stopTime = CMTime.positiveInfinity
    /// Where the previous buffer ended, to fill gaps with silence so the file stays in sync with the mic.
    private var nextExpected: CMTime?
    private var framesWritten: AVAudioFramePosition = 0

    /// What we store: 48 kHz mono float samples (the file encodes them as 16-bit PCM).
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000, channels: 1, interleaved: false)!

    /// Live loudness for the UI (read-only measurement, does not affect the file).
    let level = AudioLevelMeter()

    /// Called if macOS stops the capture by itself (e.g. permission revoked).
    var onStreamError: ((String) -> Void)?

    func prepare(url: URL) async throws {
        // Asking for shareable content is also what triggers/checks the Screen Recording permission.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw RecorderError("No display found to capture system audio from.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // SCStream always captures video too. Make it as cheap as possible: tiny frames, 1 per second.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        file = try AVAudioFile(forWriting: url, settings: RecordingFiles.pcmSettings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // We ignore video, but without a .screen output macOS logs a warning for every frame.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Start keeping audio from this moment (mach host time; the same clock ScreenCaptureKit uses).
    func beginWriting(at hostTime: UInt64) {
        queue.sync { startTime = CMClockMakeHostTimeFromSystemUnits(hostTime) }
    }

    /// Stops capture and closes the file. Returns false if no system audio was written.
    func stop(at hostTime: UInt64) async -> Bool {
        queue.sync { stopTime = CMClockMakeHostTimeFromSystemUnits(hostTime) }
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        return queue.sync {
            file = nil // closes the CAF
            converter = nil
            return framesWritten > 0
        }
    }

    // MARK: - SCStreamOutput (runs on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let file else { return }
        let time = sampleBuffer.presentationTimeStamp
        guard time >= startTime, time < stopTime, let buffer = Self.pcmBuffer(from: sampleBuffer),
              let samples = convertIfNeeded(buffer) else { return }
        level.ingest(samples)

        // A gap (e.g. nothing played for a moment) becomes silence, so system.m4a and mic.m4a stay aligned.
        if let expected = nextExpected {
            let gap = (time - expected).seconds
            if gap > 0.05, gap < 3_600 { writeSilence(seconds: gap, to: file) }
        }
        do {
            try file.write(from: samples)
            framesWritten += AVAudioFramePosition(samples.frameLength)
        } catch {
            onStreamError?("Writing system audio failed: \(error.localizedDescription)")
        }
        nextExpected = time + CMTime(seconds: Double(buffer.frameLength) / buffer.format.sampleRate,
                                     preferredTimescale: 48_000)
    }

    private func writeSilence(seconds: Double, to file: AVAudioFile) {
        var remaining = AVAudioFrameCount(seconds * outputFormat.sampleRate)
        while remaining > 0 {
            let count = min(remaining, 48_000)
            guard let silence = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: count) else { return }
            silence.frameLength = count // new buffers are zero-filled
            try? file.write(from: silence)
            framesWritten += AVAudioFramePosition(count)
            remaining -= count
        }
    }

    /// ScreenCaptureKit hands us CMSampleBuffers; AVAudioFile wants AVAudioPCMBuffers.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = basic.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// Converts to 48 kHz mono float if ScreenCaptureKit delivered something else.
    private func convertIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format != outputFormat else { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if handedOver { status.pointee = .noDataNow; return nil }
            handedOver = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?("System audio capture stopped: \(error.localizedDescription)")
    }
}
