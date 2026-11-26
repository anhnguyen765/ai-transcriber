import SwiftUI

/// Setting keys and defaults in one place (stored in UserDefaults).
enum AppSettings {
    static let modelKey = "whisperModel"
    static let autoTranscribeKey = "autoTranscribe"
    static let deleteAudioKey = "deleteAudioAfterTranscription"

    static var model: WhisperModel {
        WhisperModel(rawValue: UserDefaults.standard.string(forKey: modelKey) ?? "") ?? .largeV3Turbo
    }
    static var autoTranscribe: Bool {
        UserDefaults.standard.object(forKey: autoTranscribeKey) as? Bool ?? true
    }
    static var deleteAudioAfterTranscription: Bool {
        UserDefaults.standard.object(forKey: deleteAudioKey) as? Bool ?? false
    }

    // Phase 3: summaries
    static let llmModelKey = "llmModel"
    static let myNameKey = "myName"
    static let summaryLanguageKey = "summaryLanguage"
    static let autoSummarizeKey = "autoSummarize"

    static let defaultLLMModels = ["qwen3:8b", "qwen3:4b"]

    static var llmModel: String {
        UserDefaults.standard.string(forKey: llmModelKey) ?? defaultLLMModels[0]
    }
    static var myName: String {
        UserDefaults.standard.string(forKey: myNameKey) ?? TranscriptTrack.mic.speaker
    }
    static var summaryLanguage: SummaryWriter.Language {
        SummaryWriter.Language(rawValue: UserDefaults.standard.string(forKey: summaryLanguageKey) ?? "")
            ?? .vietnamese
    }
    static var autoSummarize: Bool {
        UserDefaults.standard.object(forKey: autoSummarizeKey) as? Bool ?? true
    }

    // Phase 4: project index
    static let maxIndexFileSizeMBKey = "maxIndexFileSizeMB"
    static let extraIgnorePatternsKey = "extraIgnorePatterns"
    static let embeddingModelKey = "embeddingModel"
    static let defaultEmbeddingModel = "bge-m3"

    static let useProjectContextKey = "useProjectContext"
    static let meetingDetectionKey = "meetingDetection"

    static var meetingDetection: Bool {
        UserDefaults.standard.object(forKey: meetingDetectionKey) as? Bool ?? true
    }

    static var useProjectContext: Bool {
        UserDefaults.standard.object(forKey: useProjectContextKey) as? Bool ?? true
    }

    static var embeddingModel: String {
        UserDefaults.standard.string(forKey: embeddingModelKey) ?? defaultEmbeddingModel
    }

    /// In bytes (setting is in MB, default 2).
    static var maxIndexFileSize: Int {
        let mb = UserDefaults.standard.object(forKey: maxIndexFileSizeMBKey) as? Double ?? 2
        return Int(mb * 1_000_000)
    }
    /// One gitignore-style pattern per line.
    static var extraIgnorePatterns: [String] {
        (UserDefaults.standard.string(forKey: extraIgnorePatternsKey) ?? "").components(separatedBy: .newlines)
    }
}

/// The Settings window (menu → Settings…).
struct SettingsView: View {
    @ObservedObject var indexer: ProjectIndexer
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettings.modelKey) private var model = WhisperModel.largeV3Turbo.rawValue
    @AppStorage(AppSettings.autoTranscribeKey) private var autoTranscribe = true
    @AppStorage(AppSettings.deleteAudioKey) private var deleteAudio = false

    @AppStorage(AppSettings.llmModelKey) private var llmModel = AppSettings.defaultLLMModels[0]
    @AppStorage(AppSettings.myNameKey) private var myName = TranscriptTrack.mic.speaker
    @AppStorage(AppSettings.summaryLanguageKey) private var summaryLanguage = SummaryWriter.Language.vietnamese.rawValue
    @AppStorage(AppSettings.autoSummarizeKey) private var autoSummarize = true
    @AppStorage(AppSettings.maxIndexFileSizeMBKey) private var maxFileSizeMB = 2.0
    @AppStorage(AppSettings.extraIgnorePatternsKey) private var extraIgnorePatterns = ""
    @AppStorage(AppSettings.embeddingModelKey) private var embeddingModel = AppSettings.defaultEmbeddingModel
    @State private var confirmDelete = false
    @AppStorage(AppSettings.meetingDetectionKey) private var meetingDetection = true
    @AppStorage(AppSettings.useProjectContextKey) private var useProjectContext = true
    @State private var installedLLMs: [String] = []
    @State private var promptMessage: String?

    /// bge-m3 plus installed models (and the current choice).
    private var embeddingChoices: [String] {
        var all = [AppSettings.defaultEmbeddingModel]
        for name in installedLLMs + [embeddingModel] where !all.contains(name) && !name.hasPrefix("qwen") {
            all.append(name)
        }
        return all
    }

    /// qwen3:8b, qwen3:4b, plus whatever else is installed in Ollama (and the current choice).
    private var llmChoices: [String] {
        var all = AppSettings.defaultLLMModels
        for name in installedLLMs + [llmModel] where !all.contains(name) { all.append(name) }
        return all
    }

    var body: some View {
        Form {
            Section("General") {
                Button("Run setup again…") {
                    NSApp.activate()
                    openWindow(id: "onboarding")
                }
                LaunchAtLoginSettings()
                Toggle("Nhắc khi phát hiện cuộc họp", isOn: $meetingDetection)
                Text("When Zoom, Teams, Webex or a browser (Google Meet) starts using the microphone, lắng asks \"Ghi lại không?\" (at most every 10 minutes). It never records without your click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Storage & logs") {
                StorageSettings(projectFolder: indexer.projectFolder)
            }
            Section("Shortcuts") {
                ShortcutSettings()
            }
            Section("Transcription") {
                transcriptionSettings
            }
            Section("Summary") {
                Picker("LLM model", selection: $llmModel) {
                    ForEach(llmChoices, id: \.self) { name in
                        Text(installedLLMs.contains(name) || installedLLMs.isEmpty ? name : "\(name) (not downloaded)")
                            .tag(name)
                    }
                }
                Text("qwen3:8b: best quality (~5 GB). qwen3:4b: faster, lower quality (~2.5 GB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("My name", text: $myName, prompt: Text("Tôi"))
                Text("Replaces the \"Tôi\" label in what the model reads, so the summary knows who you are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Summary language", selection: $summaryLanguage) {
                    Text("Tiếng Việt").tag(SummaryWriter.Language.vietnamese.rawValue)
                    Text("English").tag(SummaryWriter.Language.english.rawValue)
                }
                Toggle("Auto-summarize after transcription", isOn: $autoSummarize)
                HStack {
                    Button("Open Prompts Folder") {
                        PromptStore.createMissingDefaults()
                        NSWorkspace.shared.open(PromptStore.folder)
                    }
                    Button("Reset prompts to default") {
                        do {
                            try PromptStore.resetToDefaults()
                            promptMessage = "Prompts reset."
                        } catch {
                            promptMessage = "Could not reset prompts: \(error.localizedDescription)"
                        }
                    }
                }
                if let promptMessage {
                    Text(promptMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Project index") {
                Toggle("Use project context in summaries", isOn: $useProjectContext)
                Text("Adds related docs and earlier meetings as background, plus \"Liên quan tới tài liệu\" and \"Thay đổi so với trước\" sections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Embedding model", selection: $embeddingModel) {
                    ForEach(embeddingChoices, id: \.self) { Text($0).tag($0) }
                }
                Text("bge-m3 (~1.2 GB) understands Vietnamese. Changing the model re-embeds the whole project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: $maxFileSizeMB, in: 0.5...20, step: 0.5) {
                    Text("Max file size: \(maxFileSizeMB, specifier: "%.1f") MB")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extra ignore patterns (one per line, like .gitignore)")
                    TextEditor(text: $extraIgnorePatterns)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 70)
                    Text("A .langignore file in the project folder works too. Changes apply on the next Reindex.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Delete project index…", role: .destructive) { confirmDelete = true }
                    .disabled(indexer.projectFolder == nil)
                    .confirmationDialog("Delete the index of \(indexer.projectFolder?.lastPathComponent ?? "")?",
                                        isPresented: $confirmDelete) {
                        Button("Delete Index", role: .destructive) { indexer.deleteIndex() }
                    } message: {
                        Text("Only the index in Application Support is deleted. Your project files are not touched. Use Reindex Project to build it again.")
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // List models installed in Ollama (empty if Ollama isn't running).
            installedLLMs = (try? await OllamaClient().installedModels()) ?? []
        }
    }

    @ViewBuilder private var transcriptionSettings: some View {
        Picker("Model", selection: $model) {
            ForEach(WhisperModel.allCases) { model in
                Text(model.displayName).tag(model.rawValue)
            }
        }
        Text("A model is downloaded the first time you use it, into Application Support/Lang/Models.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Auto-transcribe after recording", isOn: $autoTranscribe)
        Toggle("Delete audio after transcription", isOn: $deleteAudio)
        if deleteAudio {
            Text("mic.m4a and system.m4a are deleted only after transcript.md was saved successfully.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button("Show Models Folder in Finder") {
            let folder = WhisperKitEngine.modelsFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}
