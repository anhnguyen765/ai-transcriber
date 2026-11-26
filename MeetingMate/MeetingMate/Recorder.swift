import AVFoundation
import AppKit
import CoreGraphics

/// Simple error with a human-readable message (shown in the menu).
struct RecorderError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Contents of meta.json, saved next to the audio files.
/// New fields are optional so meta.json files from Phase 1 still load.
struct MeetingMeta: Codable {
    enum Status: String, Codable {
        /// Still recording (or lắng crashed while recording: recovered at the next launch).
        case recording
        case recorded, transcribing, transcribed, failed
        case summarizing, summarized
        case summaryFailed = "summary_failed"
    }

    var startTime: Date
    var durationSeconds: Double
    var projectPath: String
    var micFile: String?
    var systemFile: String?
    /// For "Transcribe File…": the original file that was imported.
    var sourceFile: String?
    var audioFile: String?

    var status: Status?
    var model: String?
    var transcriptionSeconds: Double?
    var error: String?

    // Phase 3: summary (kept separate so a failed summary never hides transcript info)
    var summaryModel: String?
    var summarySeconds: Double?
    var summaryError: String?

    static let fileName = "meta.json"

    static func load(from folder: URL) throws -> MeetingMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingMeta.self, from: Data(contentsOf: folder.appending(path: fileName)))
    }

    func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: folder.appending(path: Self.fileName))
    }
}

/// Coordinates the two recorders, the timer, permissions and meta.json.
@MainActor
final class Recorder: ObservableObject {
    enum State { case idle, starting, recording, stopping }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String?
    @Published private(set) var micPermissionMissing = false
    @Published private(set) var screenPermissionMissing = false
    @Published private(set) var lastSessionURL: URL?

    var isRecording: Bool { state == .recording }

    /// Live mic/system loudness while recording (for the ripple animation). Separate object,
    /// so its 30 updates a second don't redraw everything that watches the recorder.
    let levels = AudioLevels()

    /// Called with the meeting folder after a recording is saved (used to start transcription).
    var onRecordingSaved: ((URL) -> Void)?
    /// The onboarding's 10-second test: saved, but not transcribed/summarized automatically.
    var isTestRecording = false

    private var mic: MicRecorder?
    private var system: SystemAudioRecorder?
    private var timer: Timer?
    private var startDate: Date?
    private var sessionURL: URL?
    private var projectURL: URL?

    nonisolated static let micFileName = "mic.m4a"
    nonisolated static let systemFileName = "system.m4a"

    // MARK: - Start

    func start(projectFolder: URL?) async {
        guard state == .idle else { return }
        errorMessage = nil
        guard let projectFolder else {
            errorMessage = "Choose a project folder first."
            return
        }
        state = .starting

        guard await requestPermissions() else {
            state = .idle
            return
        }

        let folderName = Self.folderNameFormatter.string(from: Date())
        let session = projectFolder
            .appending(path: ".meetings", directoryHint: .isDirectory)
            .appending(path: folderName, directoryHint: .isDirectory)

        let mic = MicRecorder()
        let system = SystemAudioRecorder()
        system.onStreamError = { [weak self] message in
            Task { @MainActor in await self?.stop(errorMessage: message) }
        }

        do {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            // While recording we write crash-safe CAF files; Stop turns them into .m4a.
            try mic.prepare(url: session.appending(path: RecordingFiles.micRaw))
            do {
                try await system.prepare(url: session.appending(path: RecordingFiles.systemRaw))
            } catch {
                mic.stop(at: mach_absolute_time())
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: session) // don't leave an empty session folder
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            state = .idle
            return
        }

        // Both captures are running. Pick ONE start moment for both; each recorder
        // drops any audio from before it, so the two files line up.
        let startHostTime = mach_absolute_time()
        mic.beginWriting(at: startHostTime)
        system.beginWriting(at: startHostTime)

        self.mic = mic
        self.system = system
        self.sessionURL = session
        self.projectURL = projectFolder
        let startDate = Date()
        self.startDate = startDate
        self.elapsed = 0
        // meta.json right away with status "recording": after a crash, the next launch finds
        // this meeting and recovers its audio.
        try? MeetingMeta(startTime: startDate, durationSeconds: 0, projectPath: projectFolder.path,
                         micFile: Self.micFileName, systemFile: Self.systemFileName, status: .recording)
            .save(to: session)
        Log.info("Recording started: \(session.lastPathComponent)")
        state = .recording
        startTimer()
        levels.start(mic: mic.level, system: system.level)
    }

    // MARK: - Stop

    /// Stops both recorders, finalizes the files and writes meta.json.
    /// `errorMessage` is shown if the stop was caused by a problem.
    func stop(errorMessage stopReason: String? = nil) async {
        guard state == .recording, let mic, let system, let sessionURL, let startDate else { return }
        state = .stopping
        let stopHostTime = mach_absolute_time()
        let duration = Date().timeIntervalSince(startDate)
        timer?.invalidate()
        timer = nil
        levels.stop()

        mic.stop(at: stopHostTime)
        _ = await system.stop(at: stopHostTime)

        // CAF → m4a (a few seconds even for long meetings).
        let saved = await RecordingFiles.finalize(folder: sessionURL)
        var problems: [String] = []
        if let stopReason { problems.append(stopReason) }
        if let micError = mic.writeError { problems.append(micError) }
        problems += saved.problems
        Log.info("Recording stopped: \(sessionURL.lastPathComponent), \(Int(duration)) s, problems: \(problems)")

        do {
            try MeetingMeta(startTime: startDate,
                            durationSeconds: ((saved.mic ?? duration) * 10).rounded() / 10,
                            projectPath: projectURL?.path ?? "",
                            micFile: Self.micFileName,
                            systemFile: Self.systemFileName,
                            status: .recorded)
                .save(to: sessionURL)
        } catch {
            problems.append("Could not write meta.json: \(error.localizedDescription)")
        }

        errorMessage = problems.isEmpty ? nil : problems.joined(separator: "\n")
        lastSessionURL = sessionURL
        self.mic = nil
        self.system = nil
        self.sessionURL = nil
        self.startDate = nil
        elapsed = 0
        state = .idle
        if isTestRecording {
            isTestRecording = false
        } else {
            onRecordingSaved?(sessionURL)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startDate = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(startDate)
            }
        }
        // .common keeps the timer ticking while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Permissions

    /// Updates the warning flags without showing any system prompt (used when the menu opens).
    func refreshPermissionStatus() {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micPermissionMissing = (micStatus == .denied || micStatus == .restricted)
        if !screenPermissionMissing { return } // only re-check after a failure, to avoid false alarms
        screenPermissionMissing = !CGPreflightScreenCaptureAccess()
    }

    /// Asks for mic + Screen Recording access if needed. Returns true if both are granted.
    private func requestPermissions() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionMissing = false
        case .notDetermined:
            micPermissionMissing = !(await AVCaptureDevice.requestAccess(for: .audio))
        default:
            micPermissionMissing = true
        }

        if CGPreflightScreenCaptureAccess() {
            screenPermissionMissing = false
        } else {
            // First time: shows the macOS prompt. After allowing, the app must be relaunched.
            CGRequestScreenCaptureAccess()
            screenPermissionMissing = true
        }
        return !micPermissionMissing && !screenPermissionMissing
    }

    static func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    private static let folderNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Recording files (crash-safe while recording, small after Stop)

/// While recording, audio goes into 16-bit PCM CAF files: a CAF stays readable even if the app
/// is killed mid-recording (an unfinished .m4a does not). Stop (or crash recovery) converts them
/// to the usual AAC mic.m4a / system.m4a and deletes the CAFs.
enum RecordingFiles {
    static let micRaw = "mic.caf"
    static let systemRaw = "system.caf"

    static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96_000,
    ]

    /// Converts whichever CAFs are in `folder`. Returns the seconds of each result.
    static func finalize(folder: URL) async -> (mic: Double?, system: Double?, problems: [String]) {
        await Task.detached(priority: .userInitiated) {
            var problems: [String] = []
            func run(_ raw: String, _ final: String, emptyMessage: String) -> Double? {
                let source = folder.appending(path: raw)
                guard FileManager.default.fileExists(atPath: source.path) else { return nil }
                do {
                    let seconds = try convert(source, to: folder.appending(path: final))
                    try? FileManager.default.removeItem(at: source)
                    return seconds
                } catch RecordingFilesError.empty {
                    try? FileManager.default.removeItem(at: source)
                    problems.append(emptyMessage)
                } catch {
                    // Keep the CAF so nothing is lost; it can be converted again later.
                    problems.append("Could not save \(final): \(error.localizedDescription) (kept \(raw)).")
                }
                return nil
            }
            let mic = run(micRaw, Recorder.micFileName, emptyMessage: "The microphone recorded nothing.")
            let system = run(systemRaw, Recorder.systemFileName,
                             emptyMessage: "No system audio was captured, so system.m4a was not saved.")
            return (mic, system, problems)
        }.value
    }

    /// CAF (PCM) → AAC .m4a, read in 1-second pieces. Returns the duration in seconds.
    static func convert(_ source: URL, to destination: URL) throws -> Double {
        let input = try AVAudioFile(forReading: source)
        guard input.length > 0 else { throw RecordingFilesError.empty }
        try? FileManager.default.removeItem(at: destination)
        let format = input.processingFormat
        // The writer is released at the end of this function, which finalizes the .m4a.
        let output = try AVAudioFile(forWriting: destination, settings: aacSettings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000) else {
            throw RecorderError("Out of memory while converting audio.")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        return Double(input.length) / input.fileFormat.sampleRate
    }
}

enum RecordingFilesError: Error {
    case empty
}
