import SwiftUI

/// Setting keys and defaults in one place (stored in UserDefaults).
enum AppSettings {
    static let modelKey = "whisperModel"
    static let autoTranscribeKey = "autoTranscribe"
    static let notchIslandKey = "notchIsland"
    static let skipShortRecordingsKey = "skipShortRecordings"
    /// Recordings shorter than this are offered for discard (never deleted without asking).
    static let shortRecordingSeconds: Double = 15
    static var skipShortRecordings: Bool {
        UserDefaults.standard.object(forKey: skipShortRecordingsKey) as? Bool ?? true
    }
    static var notchIsland: Bool {
        UserDefaults.standard.object(forKey: notchIslandKey) as? Bool ?? true
    }
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
    @AppStorage(AppSettings.notchIslandKey) private var notchIsland = true
    @AppStorage(AppSettings.skipShortRecordingsKey) private var skipShortRecordings = true
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
            Section("Chung") {
                Button("Chạy lại thiết lập…") {
                    NSApp.activate()
                    openWindow(id: "onboarding")
                }
                LaunchAtLoginSettings()
                Toggle("Nhắc khi phát hiện cuộc họp", isOn: $meetingDetection)
                Toggle("Hiện ô nhỏ cạnh notch khi đang ghi", isOn: $notchIsland)
                Toggle("Hỏi trước khi bỏ bản ghi dưới 15 giây", isOn: $skipShortRecordings)
                Text("Khi Zoom, Teams, Webex hoặc trình duyệt (Google Meet) bắt đầu dùng micro, lắng hỏi \"Ghi lại không?\" (tối đa 10 phút một lần). Không bao giờ tự ghi nếu bạn không bấm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Lưu trữ & nhật ký") {
                StorageSettings(projectFolder: indexer.projectFolder)
            }
            Section("Phím tắt") {
                ShortcutSettings()
            }
            Section("Chép lời") {
                transcriptionSettings
            }
            Section("Tóm tắt") {
                Picker("Mô hình tóm tắt", selection: $llmModel) {
                    ForEach(llmChoices, id: \.self) { name in
                        Text(installedLLMs.contains(name) || installedLLMs.isEmpty ? name : "\(name) (not downloaded)")
                            .tag(name)
                    }
                }
                Text("qwen3:8b: chất lượng tốt nhất (~5 GB). qwen3:4b: nhanh hơn, chất lượng thấp hơn (~2.5 GB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Tên của tôi", text: $myName, prompt: Text("Tôi"))
                Text("Thay nhãn \"Tôi\" trong nội dung gửi cho mô hình, để bản tóm tắt biết bạn là ai.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Ngôn ngữ tóm tắt", selection: $summaryLanguage) {
                    Text("Tiếng Việt").tag(SummaryWriter.Language.vietnamese.rawValue)
                    Text("Tiếng Anh").tag(SummaryWriter.Language.english.rawValue)
                }
                Toggle("Tự tóm tắt sau khi chép lời", isOn: $autoSummarize)
                HStack {
                    Button("Mở thư mục prompt") {
                        PromptStore.createMissingDefaults()
                        NSWorkspace.shared.open(PromptStore.folder)
                    }
                    Button("Đặt lại prompt mặc định") {
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
            Section("Chỉ mục dự án") {
                Toggle("Dùng ngữ cảnh dự án khi tóm tắt", isOn: $useProjectContext)
                Text("Thêm tài liệu liên quan và cuộc họp trước làm ngữ cảnh, cùng các mục \"Liên quan tới tài liệu\" và \"Thay đổi so với trước\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Mô hình nhúng (embedding)", selection: $embeddingModel) {
                    ForEach(embeddingChoices, id: \.self) { Text($0).tag($0) }
                }
                Text("bge-m3 (~1.2 GB) hiểu tiếng Việt. Đổi mô hình sẽ nhúng lại toàn bộ dự án.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper(value: $maxFileSizeMB, in: 0.5...20, step: 0.5) {
                    Text("Cỡ file tối đa: \(maxFileSizeMB, specifier: "%.1f") MB")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mẫu bỏ qua thêm (mỗi dòng một mẫu, giống .gitignore)")
                    TextEditor(text: $extraIgnorePatterns)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 70)
                    Text("File .langignore trong thư mục dự án cũng được dùng. Thay đổi áp dụng khi đọc lại dự án.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Xoá chỉ mục dự án…", role: .destructive) { confirmDelete = true }
                    .disabled(indexer.projectFolder == nil)
                    .confirmationDialog("Delete the index of \(indexer.projectFolder?.lastPathComponent ?? "")?",
                                        isPresented: $confirmDelete) {
                        Button("Xoá chỉ mục", role: .destructive) { indexer.deleteIndex() }
                    } message: {
                        Text("Chỉ xoá chỉ mục trong Application Support. File dự án của bạn không bị động vào. Dùng \"Đọc lại dự án\" để tạo lại.")
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
        Picker("Mô hình", selection: $model) {
            ForEach(WhisperModel.allCases) { model in
                Text(model.displayName).tag(model.rawValue)
            }
        }
        Text("Mô hình được tải về lần đầu dùng, vào Application Support/Lang/Models.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Toggle("Tự chép lời sau khi ghi", isOn: $autoTranscribe)
        Toggle("Xoá audio sau khi chép lời", isOn: $deleteAudio)
        if deleteAudio {
            Text("mic.m4a và system.m4a chỉ bị xoá sau khi transcript.md được lưu thành công.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button("Mở thư mục mô hình trong Finder") {
            let folder = WhisperKitEngine.modelsFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}
