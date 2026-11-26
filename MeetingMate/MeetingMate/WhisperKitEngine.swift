import AVFoundation
import Foundation
import WhisperKit

/// The Whisper models you can pick in Settings (exact folder names in argmaxinc/whisperkit-coreml).
enum WhisperModel: String, CaseIterable, Identifiable {
    /// OpenAI's large-v3 turbo (released 2024-09-30), the variant Argmax recommends on Mac.
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo"
    case small = "openai_whisper-small"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largeV3Turbo: "large-v3 turbo (best, ~1.6 GB)"
        case .small: "small (faster, for testing, ~0.5 GB)"
        }
    }
}

/// Speech-to-text with WhisperKit, fully on-device.
final class WhisperKitEngine: TranscriptionEngine {
    let modelName: String
    private var whisperKit: WhisperKit?

    /// ~/Library/Application Support/Lang/Models
    static var modelsFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Lang/Models", directoryHint: .isDirectory)
    }

    init(model: WhisperModel) {
        modelName = model.rawValue
    }

    // MARK: - Load / unload

    func load(downloadProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard whisperKit == nil else { return }
        let modelFolder = try await Self.download(modelName, progress: downloadProgress)
        let config = WhisperKitConfig(
            downloadBase: Self.modelsFolder, // the tokenizer is cached here too
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,                   // lower peak memory while macOS prepares the model
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
    }

    /// Where WhisperKit keeps a model, and whether a previous download finished.
    static func localFolder(_ modelName: String) -> URL {
        modelsFolder.appending(path: "models/argmaxinc/whisperkit-coreml/\(modelName)", directoryHint: .isDirectory)
    }

    static func isDownloaded(_ modelName: String) -> Bool {
        FileManager.default.fileExists(atPath: localFolder(modelName).appending(path: ".download-complete").path)
    }

    /// Downloads a model if needed (no loading). Used by load() and by the onboarding.
    static func download(_ modelName: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        if isDownloaded(modelName) {
            progress(1)
            return localFolder(modelName) // already downloaded: works offline
        }
        let folder = try await WhisperKit.download(variant: modelName, downloadBase: modelsFolder) { p in
            progress(p.fractionCompleted)
        }
        FileManager.default.createFile(atPath: folder.appending(path: ".download-complete").path, contents: nil)
        progress(1)
        return folder
    }

    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    // MARK: - Transcribe

    /// Audio is fed to Whisper ~2 minutes at a time so a 2-hour file never sits in memory at once.
    private static let pieceSeconds = 120.0

    func transcribe(fileURL: URL, options: TranscriptionOptions,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscribedSegment] {
        guard let kit = whisperKit else { throw RecorderError("The speech model is not loaded.") }

        var decode = DecodingOptions(
            task: .transcribe,
            language: options.language,
            temperatureFallbackCount: 5,   // retry hard parts with a higher temperature
            usePrefillPrompt: true,        // force Vietnamese instead of auto-detecting
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,      // we need segment timestamps
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad         // split long audio at silences (voice activity detection)
        )
        decode.promptTokens = promptTokens(for: options.vocabularyPrompt, kit: kit)

        let reader = try await AudioPieceReader(url: fileURL)
        let total = max(reader.duration, 1)
        var segments: [TranscribedSegment] = []

        while let piece = try reader.nextPiece(seconds: Self.pieceSeconds) {
            try Task.checkCancellation()
            let pieceStart = piece.startSeconds
            let pieceLength = Double(piece.samples.count) / 16_000

            // Called often while decoding; WhisperKit's own progress tells us how far into this piece we are.
            let pieceProgress = kit.progress
            let callback: TranscriptionCallback = { _ in
                let inPiece = pieceProgress.fractionCompleted
                progress(min(1, (pieceStart + pieceLength * inPiece) / total))
                return nil // nil = keep going
            }

            let results = try await kit.transcribe(audioArray: piece.samples, decodeOptions: decode,
                                                   callback: callback)
            for s in results.flatMap(\.segments) {
                segments.append(TranscribedSegment(
                    start: pieceStart + Double(s.start),
                    end: pieceStart + Double(s.end),
                    text: s.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    noSpeechProbability: Double(s.noSpeechProb),
                    averageLogProbability: Double(s.avgLogprob)))
            }
            progress(min(1, (pieceStart + pieceLength) / total))
        }
        progress(1)
        return segments.sorted { $0.start < $1.start }
    }

    /// Turns glossary text into prompt tokens, trimmed to fit Whisper's prompt limit.
    private func promptTokens(for text: String?, kit: WhisperKit) -> [Int]? {
        guard let text, !text.isEmpty, let tokenizer = kit.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        // Whisper allows at most 223 prompt tokens; keep the first ones (one term per line in the glossary).
        let limit = 220
        return tokens.isEmpty ? nil : Array(tokens.prefix(limit))
    }
}

// MARK: - Audio reading

/// Reads any audio or video file as 16 kHz mono samples (what Whisper expects), a few minutes at a time.
final class AudioPieceReader {
    struct Piece {
        let samples: [Float]
        let startSeconds: Double
    }

    let duration: Double
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var pending: [Float] = []
    private var consumedSamples = 0
    private var reachedEnd = false
    private static let rate = 16_000

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw RecorderError("\(url.lastPathComponent) has no audio.")
        }
        duration = try await asset.load(.duration).seconds
        reader = try AVAssetReader(asset: asset)
        // Ask AVFoundation to decode + resample + mix to mono for us.
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecorderError("Can't read audio from \(url.lastPathComponent).") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecorderError("Can't read audio from \(url.lastPathComponent).")
        }
    }

    /// Returns the next piece (about `seconds` long), cut at a quiet moment, or nil at the end.
    func nextPiece(seconds: Double) throws -> Piece? {
        let target = Int(seconds) * Self.rate
        let searchWindow = 10 * Self.rate // look for a quiet spot in the last 10 s

        while pending.count < target + searchWindow, !reachedEnd {
            if let buffer = output.copyNextSampleBuffer() {
                append(buffer)
            } else {
                if reader.status == .failed {
                    throw reader.error ?? RecorderError("Reading audio failed.")
                }
                reachedEnd = true
            }
        }
        guard !pending.isEmpty else { return nil }

        let cut = reachedEnd && pending.count <= target + searchWindow
            ? pending.count
            : quietestPoint(from: target - searchWindow, to: target)
        let piece = Piece(samples: Array(pending[0..<cut]),
                          startSeconds: Double(consumedSamples) / Double(Self.rate))
        pending.removeFirst(cut)
        consumedSamples += cut
        return piece
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let byteCount = CMBlockBufferGetDataLength(block)
        var floats = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
        floats.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                           destination: raw.baseAddress!)
        }
        pending.append(contentsOf: floats)
    }

    /// Index of the quietest 100 ms between `from` and `to`, so we don't cut in the middle of a word.
    private func quietestPoint(from: Int, to: Int) -> Int {
        let block = Self.rate / 10
        var bestIndex = to
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = max(0, from)
        while i + block <= min(to, pending.count) {
            var energy: Float = 0
            for j in i..<(i + block) { energy += pending[j] * pending[j] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestIndex = i + block / 2
            }
            i += block
        }
        return max(1, bestIndex)
    }
}
