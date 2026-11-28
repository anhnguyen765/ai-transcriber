import Foundation
import Testing
@testable import MeetingMate

struct WhisperModelTests {
    @Test func hubModelsLiveInTheArgmaxFolder() {
        let path = WhisperKitEngine.localFolder(WhisperModel.largeV3Turbo.rawValue).path
        #expect(path.hasSuffix("Models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo"))
    }

    @Test func handInstalledModelsLiveInTheLocalFolder() {
        let path = WhisperKitEngine.localFolder(WhisperModel.vietnameseTurbo.rawValue).path
        #expect(path.hasSuffix("Models/models/local/erax-ai_EraX-WoW-Turbo-V1.1"))
        #expect(WhisperModel.vietnameseTurbo.repo == nil)
    }
}

/// Opt-in: loads the Vietnamese model through the app's own engine and transcribes one file.
/// Run with TEST_RUNNER_LANG_TEST_WHISPER_AUDIO=<path to a Vietnamese .wav> (model must be installed).
struct VietnameseModelSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LANG_TEST_WHISPER_AUDIO"] != nil
                   && WhisperKitEngine.isDownloaded(WhisperModel.vietnameseTurbo.rawValue)))
    func transcribesVietnamese() async throws {
        let audio = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LANG_TEST_WHISPER_AUDIO"]!)
        let model = ProcessInfo.processInfo.environment["LANG_TEST_WHISPER_MODEL"]
            .flatMap(WhisperModel.init(rawValue:)) ?? .vietnameseTurbo
        let engine = WhisperKitEngine(model: model)
        try await engine.load { _ in }
        let segments = try await engine.transcribe(
            fileURL: audio, options: TranscriptionOptions(language: "vi", vocabularyPrompt: nil)) { _ in }
        await engine.unload()
        let text = segments.map(\.text).joined(separator: " ")
        print("VI_SMOKE:", text)
        #expect(!text.isEmpty)
    }
}
