import Foundation

/// One piece of recognized speech. Times are seconds from the start of the audio file.
struct TranscribedSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
    /// The engine's estimate (0…1) that this piece is NOT speech. nil if the engine doesn't report it.
    var noSpeechProbability: Double? = nil
    /// Average log-probability of the text (closer to 0 = more confident). nil if not reported.
    var averageLogProbability: Double? = nil
}

struct TranscriptionOptions {
    var language = "vi"
    /// Names and jargon from glossary.txt, given to the model as a hint for spelling.
    var vocabularyPrompt: String?
}

/// Anything that can turn an audio/video file into text segments.
/// Today: WhisperKit. Later: e.g. whisper.cpp + PhoWhisper, without touching the rest of the app.
protocol TranscriptionEngine: AnyObject {
    /// Shown in meta.json.
    var modelName: String { get }

    /// Downloads the model if needed (reporting 0…1) and loads it into memory.
    func load(downloadProgress: @escaping @Sendable (Double) -> Void) async throws

    /// Transcribes one file, reporting progress 0…1.
    func transcribe(fileURL: URL, options: TranscriptionOptions,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> [TranscribedSegment]

    /// Frees the model's memory.
    func unload() async
}
