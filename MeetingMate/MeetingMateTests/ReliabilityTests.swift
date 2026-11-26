import AVFoundation
import Foundation
import Testing
@testable import MeetingMate

struct ReliabilityTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "lang-rel-\(UUID().uuidString)")

    private func meeting(_ name: String, status: MeetingMeta.Status) throws -> URL {
        let folder = root.appending(path: ".meetings/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MeetingMeta(startTime: ProjectScanner.meetingDate(name)!, durationSeconds: 0, projectPath: root.path,
                        micFile: Recorder.micFileName, systemFile: Recorder.systemFileName, status: status).save(to: folder)
        return folder
    }

    /// Writes `seconds` of a 440 Hz tone as 16-bit PCM CAF, like the recorders do.
    private func writeCAF(_ url: URL, seconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: RecordingFiles.pcmSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sin(Float(i) * 2 * .pi * 440 / 48_000) * 0.3 }
        try file.write(from: buffer)
    }

    @Test func findsOnlyMeetingsLeftInProgress() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try meeting("2026-11-20_10-00-00", status: .recording)
        _ = try meeting("2026-11-21_10-00-00", status: .transcribing)
        _ = try meeting("2026-11-22_10-00-00", status: .summarizing)
        _ = try meeting("2026-11-23_10-00-00", status: .summarized)
        _ = try meeting("2026-11-24_10-00-00", status: .failed)
        let stuck = CrashRecovery.findStuck(projectFolder: root)
        #expect(stuck.map(\.status) == [.recording, .transcribing, .summarizing])
    }

    @Test func recoversACrashedRecordingFromCAF() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try meeting("2026-11-20_10-00-00", status: .recording)
        try writeCAF(folder.appending(path: RecordingFiles.micRaw), seconds: 3)
        try writeCAF(folder.appending(path: RecordingFiles.systemRaw), seconds: 3)

        #expect(await CrashRecovery.recoverRecording(folder))
        let meta = try MeetingMeta.load(from: folder)
        #expect(meta.status == .recorded)
        #expect(abs(meta.durationSeconds - 3) < 0.1)
        // CAFs became playable AAC files and were removed.
        let mic = try AVAudioFile(forReading: folder.appending(path: Recorder.micFileName))
        #expect(abs(Double(mic.length) / mic.fileFormat.sampleRate - 3) < 0.1)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: Recorder.systemFileName).path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: RecordingFiles.micRaw).path))
        #expect(CrashRecovery.findStuck(projectFolder: root).isEmpty)
    }

    @Test func emptySystemAudioIsReportedNotSaved() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try meeting("2026-11-20_10-00-00", status: .recording)
        try writeCAF(folder.appending(path: RecordingFiles.micRaw), seconds: 1)
        _ = try AVAudioFile(forWriting: folder.appending(path: RecordingFiles.systemRaw), settings: RecordingFiles.pcmSettings)

        let result = await RecordingFiles.finalize(folder: folder)
        #expect(result.mic != nil && result.system == nil)
        #expect(result.problems.contains { $0.contains("No system audio") })
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: RecordingFiles.systemRaw).path))
    }

    @Test func laterMarksInterruptedWorkAsFailedSoItIsNotAskedAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try meeting("2026-11-21_10-00-00", status: .summarizing)
        CrashRecovery.markForLater(StuckMeeting(folder: folder, status: .summarizing))
        #expect(try MeetingMeta.load(from: folder).status == .summaryFailed)
        #expect(CrashRecovery.findStuck(projectFolder: root).isEmpty)
    }

    @Test func oldAudioOnlyFromTranscribedMeetings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-40 * 86_400), recent = now.addingTimeInterval(-5 * 86_400)
        let files = [
            StorageReport.AudioFile(url: URL(fileURLWithPath: "/a/mic.m4a"), meetingDate: old, size: 10, hasTranscript: true),
            StorageReport.AudioFile(url: URL(fileURLWithPath: "/b/mic.m4a"), meetingDate: old, size: 10, hasTranscript: false),
            StorageReport.AudioFile(url: URL(fileURLWithPath: "/c/mic.m4a"), meetingDate: recent, size: 10, hasTranscript: true),
        ]
        #expect(StorageReport.oldAudio(files, olderThanDays: 30, now: now).map(\.url.path) == ["/a/mic.m4a"])
    }

    @Test func indexingPausesOnLowBatteryOrLowPowerMode() {
        #expect(PowerState.pauseReason(lowPowerMode: true, onBattery: false, percent: 100) == "Low Power Mode")
        #expect(PowerState.pauseReason(lowPowerMode: false, onBattery: true, percent: 19) == "pin dưới 20%")
        #expect(PowerState.pauseReason(lowPowerMode: false, onBattery: true, percent: 20) == nil)
        #expect(PowerState.pauseReason(lowPowerMode: false, onBattery: false, percent: 5) == nil) // charging
    }
}
