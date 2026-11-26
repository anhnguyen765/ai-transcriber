import AVFoundation
import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// Runs transcription jobs one at a time and publishes progress for the menu.
@MainActor
final class TranscriptionService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waitingForSummary         // the LLM is still in memory; wait for it to finish
        case preparing                 // importing a file
        case downloading(Double)       // model download 0…1
        case loadingModel
        case transcribing(Double)      // 0…1 over all tracks of the current meeting
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var waitingCount = 0
    @Published var errorMessage: String?
    @Published private(set) var lastTranscriptURL: URL?

    var isBusy: Bool { phase != .idle }

    /// Text for the menu, e.g. "Đang chép lời… 42%".
    var statusText: String? {
        switch phase {
        case .idle: nil
        case .waitingForSummary: "Đang chờ tóm tắt xong…"
        case .preparing: "Đang chuẩn bị file…"
        case .downloading(let p): "Đang tải model… \(Int(p * 100))%"
        case .loadingModel: "Đang nạp model… (lần đầu có thể mất vài phút)"
        case .transcribing(let p): "Đang chép lời… \(Int(p * 100))%"
        }
    }

    /// 0…1 for the progress bar, nil when there is no meaningful percentage.
    var progressValue: Double? {
        switch phase {
        case .downloading(let p), .transcribing(let p): p
        default: nil
        }
    }

    /// Called with the meeting folder after a transcript was saved (used to start the summary).
    var onTranscribed: ((URL) -> Void)?

    private var queue: [URL] = []       // meeting folders waiting to be transcribed
    private var runner: Task<Void, Never>?
    private var currentFolder: URL?

    // MARK: - Public actions

    /// Adds a meeting folder (with mic/system or audio files + meta.json) to the queue.
    func transcribeMeeting(at folder: URL) {
        guard !queue.contains(folder), folder != currentFolder else { return }
        errorMessage = nil
        queue.append(folder)
        waitingCount = queue.count
        startRunnerIfNeeded()
    }

    /// Asks for an audio/video file, copies its audio into a new meeting folder and transcribes it.
    func chooseAndTranscribeFile(projectFolder: URL?) {
        guard let projectFolder else {
            errorMessage = "Choose a project folder first."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mp3, .wav, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose an audio or video file to transcribe"
        NSApp.activate()
        guard panel.runModal() == .OK, let source = panel.url else { return }

        errorMessage = nil
        if phase == .idle { phase = .preparing }
        Task {
            do {
                let folder = try await Self.importFile(source, into: projectFolder)
                if phase == .preparing { phase = .idle }
                transcribeMeeting(at: folder)
            } catch {
                if phase == .preparing { phase = .idle }
                errorMessage = "Could not import \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Transcribes the newest folder in <project>/.meetings again.
    func retranscribeLastMeeting(projectFolder: URL?) {
        guard let projectFolder else {
            errorMessage = "Choose a project folder first."
            return
        }
        let meetings = projectFolder.appending(path: ".meetings", directoryHint: .isDirectory)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: meetings, includingPropertiesForKeys: nil)) ?? []
        // Folder names are timestamps (yyyy-MM-dd_HH-mm-ss), so name order = time order.
        guard let last = folders
            .filter({ FileManager.default.fileExists(atPath: $0.appending(path: MeetingMeta.fileName).path) })
            .max(by: { $0.lastPathComponent < $1.lastPathComponent })
        else {
            errorMessage = "No meetings found in \(projectFolder.lastPathComponent)/.meetings."
            return
        }
        transcribeMeeting(at: last)
    }

    /// Called when the app quits mid-transcription, so meta.json doesn't stay "transcribing".
    func markInterrupted() {
        guard let folder = currentFolder, var meta = try? MeetingMeta.load(from: folder) else { return }
        meta.status = .failed
        meta.error = "Interrupted: the app quit during transcription. Use Re-transcribe Last Meeting."
        try? meta.save(to: folder)
    }

    // MARK: - Queue

    private func startRunnerIfNeeded() {
        guard runner == nil else { return }
        runner = Task {
            // Never load WhisperKit while the summary LLM is still in memory.
            if phase == .idle { phase = .waitingForSummary }
            await HeavyWorkLock.shared.acquire()
            // The Ask window keeps the LLM warm for a few minutes; free it before WhisperKit loads.
            let ollama = OllamaClient()
            await ollama.unload(model: AppSettings.llmModel)
            await ollama.unload(model: AppSettings.embeddingModel)
            let engine: TranscriptionEngine = WhisperKitEngine(model: AppSettings.model)
            var finished: [URL] = []
            while !queue.isEmpty {
                let folder = queue.removeFirst()
                waitingCount = queue.count
                currentFolder = folder
                if await run(folder: folder, engine: engine) { finished.append(folder) }
                currentFolder = nil
            }
            // Free the model's memory (often 1–3 GB) as soon as the queue is empty…
            await engine.unload()
            await HeavyWorkLock.shared.release()
            phase = .idle
            runner = nil
            // …and only then hand the meetings to the summary step (which loads the LLM).
            finished.forEach { onTranscribed?($0) }
        }
    }

    /// Returns true if transcript.md was written.
    private func run(folder: URL, engine: TranscriptionEngine) async -> Bool {
        let began = Date()
        var meta: MeetingMeta
        do {
            meta = try MeetingMeta.load(from: folder)
        } catch {
            errorMessage = "Can't read meta.json in \(folder.lastPathComponent): \(error.localizedDescription)"
            return false
        }
        meta.status = .transcribing
        meta.model = engine.modelName
        meta.error = nil
        try? meta.save(to: folder)

        // The tracks to transcribe: system first, then mic (one after the other to save memory).
        var tracks: [(TranscriptTrack, URL)] = []
        if let name = meta.systemFile { tracks.append((.system, folder.appending(path: name))) }
        if let name = meta.micFile { tracks.append((.mic, folder.appending(path: name))) }
        if let name = meta.audioFile { tracks.append((.file, folder.appending(path: name))) }
        tracks = tracks.filter { FileManager.default.fileExists(atPath: $0.1.path) }

        do {
            guard !tracks.isEmpty else { throw RecorderError("No audio files found in this meeting folder.") }

            // "Loading" (the first time also prepares the model for this Mac's chip),
            // or "Downloading x%" while a model is still being downloaded.
            phase = .loadingModel
            try await engine.load { p in
                Task { @MainActor in
                    switch self.phase {
                    case .loadingModel, .downloading: self.phase = p < 1 ? .downloading(p) : .loadingModel
                    default: break // a late update after we already moved on
                    }
                }
            }

            let options = TranscriptionOptions(language: "vi", vocabularyPrompt: glossary(for: folder))
            var results: [(track: TranscriptTrack, offset: Double, segments: [TranscribedSegment])] = []
            for (index, (track, url)) in tracks.enumerated() {
                let count = Double(tracks.count)
                phase = .transcribing(Double(index) / count)
                let segments = try await engine.transcribe(fileURL: url, options: options) { p in
                    Task { @MainActor in
                        let overall = (Double(index) + p) / count
                        if case .transcribing(let old) = self.phase, overall > old {
                            self.phase = .transcribing(overall)
                        }
                    }
                }
                // Both recordings start at meta.startTime, so their offset is 0.
                results.append((track, 0, segments))
            }

            // Compare mic vs system loudness to spot the other side leaking from the speakers into the mic.
            var leakage: LeakageDetector?
            if let micURL = tracks.first(where: { $0.0 == .mic })?.1,
               let systemURL = tracks.first(where: { $0.0 == .system })?.1 {
                leakage = await LeakageDetector.make(micURL: micURL, systemURL: systemURL)
            }
            let lines = TranscriptMerger.merge(results, leakage: leakage)
            let projectName = URL(fileURLWithPath: meta.projectPath).lastPathComponent
            let transcriptURL = try TranscriptWriter.write(
                lines, meetingStart: meta.startTime, duration: meta.durationSeconds,
                projectName: projectName, to: folder)

            meta.status = .transcribed
            meta.transcriptionSeconds = (Date().timeIntervalSince(began) * 10).rounded() / 10
            try? meta.save(to: folder)

            if AppSettings.deleteAudioAfterTranscription {
                for (_, url) in tracks { try? FileManager.default.removeItem(at: url) }
            }
            lastTranscriptURL = transcriptURL
            Notifier.post(title: "Đã chép lời xong",
                          body: "\(folder.lastPathComponent) — bấm để mở transcript.md", open: transcriptURL)
            return true
        } catch {
            meta.status = .failed
            meta.error = error.localizedDescription
            meta.transcriptionSeconds = (Date().timeIntervalSince(began) * 10).rounded() / 10
            try? meta.save(to: folder)
            errorMessage = "Transcription failed (\(folder.lastPathComponent)): \(error.localizedDescription)"
            return false
        }
    }

    /// <project>/.meetings/glossary.txt → "Term1, Term2, …" (or nil if there is none).
    private func glossary(for meetingFolder: URL) -> String? {
        let file = meetingFolder.deletingLastPathComponent().appending(path: "glossary.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let terms = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    // MARK: - Import a file

    /// Creates .meetings/<timestamp>/, extracts the file's audio to audio.m4a and writes meta.json.
    private static func importFile(_ source: URL, into projectFolder: URL) async throws -> URL {
        let stamp = folderNameFormatter.string(from: Date())
        let folder = projectFolder
            .appending(path: ".meetings", directoryHint: .isDirectory)
            .appending(path: stamp, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            let asset = AVURLAsset(url: source)
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
                throw RecorderError("This file has no audio track.")
            }
            let duration = try await asset.load(.duration).seconds
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw RecorderError("Can't convert this file to audio.")
            }
            let audioName = "audio.m4a"
            try await export.export(to: folder.appending(path: audioName), as: .m4a)

            try MeetingMeta(startTime: Date(),
                            durationSeconds: (duration * 10).rounded() / 10,
                            projectPath: projectFolder.path,
                            sourceFile: source.path,
                            audioFile: audioName,
                            status: .recorded)
                .save(to: folder)
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static let folderNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

}

// MARK: - Notifications

/// "Done" notifications; clicking one opens the file (handled in AppDelegate).
enum Notifier {
    static let openPathKey = "openPath"

    /// - Parameters:
    ///   - category: adds buttons (see MeetingDetector's categories).
    ///   - id: a fixed id replaces the previous notification with the same id instead of stacking.
    static func post(title: String, body: String, open file: URL? = nil,
                     category: String? = nil, id: String? = nil) {
        let center = UNUserNotificationCenter.current()
        Task {
            // Asks for permission the first time; later calls return immediately.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let file { content.userInfo = [openPathKey: file.path] }
            if let category { content.categoryIdentifier = category }
            try? await center.add(UNNotificationRequest(identifier: id ?? UUID().uuidString,
                                                        content: content, trigger: nil))
        }
    }
}
