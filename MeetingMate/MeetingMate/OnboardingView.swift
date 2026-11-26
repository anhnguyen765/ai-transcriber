import AVFoundation
import CoreGraphics
import SwiftUI

/// First-run setup: folder → microphone → screen recording → Ollama → models → 10-second test.
@MainActor
final class OnboardingModel: ObservableObject {
    static let doneKey = "onboardingDone"
    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    @Published private(set) var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published private(set) var screenRequested = false
    @Published private(set) var ollamaRunning = false
    @Published private(set) var ollamaInstalled = false
    @Published private(set) var installedModels: [String] = []
    @Published private(set) var whisperDownloaded = WhisperKitEngine.isDownloaded(AppSettings.model.rawValue)
    @Published private(set) var downloads: [String: Double] = [:] // model → progress
    @Published private(set) var downloadErrors: [String: String] = [:]
    @Published private(set) var testState: TestState = .notStarted

    enum TestState: Equatable {
        case notStarted
        case recording(secondsLeft: Int)
        case saving
        case done(folder: URL, summary: String, ok: Bool)
    }

    let recorder: Recorder
    let projectStore: ProjectStore
    private let ollama = OllamaClient()
    private var timer: Timer?

    init(recorder: Recorder, projectStore: ProjectStore) {
        self.recorder = recorder
        self.projectStore = projectStore
    }

    var llmModel: String { AppSettings.llmModel }
    var embeddingModel: String { AppSettings.embeddingModel }

    func isInstalled(_ model: String) -> Bool {
        installedModels.contains(model) || installedModels.contains("\(model):latest")
    }

    // MARK: Refreshing state (every 2 s while the window is open)

    func startWatching() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        screenAllowed = CGPreflightScreenCaptureAccess()
        whisperDownloaded = WhisperKitEngine.isDownloaded(AppSettings.model.rawValue)
        ollamaInstalled = FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
        Task {
            let running = await ollama.isRunning()
            ollamaRunning = running
            installedModels = running ? ((try? await ollama.installedModels()) ?? []) : []
        }
    }

    // MARK: Actions

    func requestMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        }
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess() // shows the macOS prompt / adds lắng to the list
        screenRequested = true
    }

    /// Screen Recording only takes effect after a relaunch.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    func openOllama() {
        if ollamaInstalled {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Ollama.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
        }
    }

    func downloadWhisper() {
        let model = AppSettings.model.rawValue
        guard downloads[model] == nil else { return }
        downloads[model] = 0
        downloadErrors[model] = nil
        Task {
            do {
                _ = try await WhisperKitEngine.download(model) { p in
                    Task { @MainActor in self.downloads[model] = p }
                }
            } catch {
                downloadErrors[model] = error.localizedDescription
            }
            downloads[model] = nil
            refresh()
        }
    }

    func downloadOllamaModel(_ model: String) {
        guard downloads[model] == nil else { return }
        downloads[model] = 0
        downloadErrors[model] = nil
        Task {
            do {
                try await ollama.pull(model: model) { p in
                    Task { @MainActor in self.downloads[model] = p }
                }
            } catch {
                downloadErrors[model] = error.localizedDescription
            }
            downloads[model] = nil
            refresh()
        }
    }

    /// Records 10 seconds (not transcribed automatically) and checks both files.
    func testRecording() {
        guard case .notStarted = testState, recorder.state == .idle, let folder = projectStore.folderURL else { return }
        Task {
            recorder.isTestRecording = true
            await recorder.start(projectFolder: folder)
            guard recorder.isRecording else {
                recorder.isTestRecording = false
                testState = .done(folder: folder, summary: recorder.errorMessage ?? "Could not start recording.", ok: false)
                return
            }
            for left in stride(from: 10, to: 0, by: -1) {
                testState = .recording(secondsLeft: left)
                try? await Task.sleep(for: .seconds(1))
            }
            testState = .saving
            await recorder.stop()
            guard let session = recorder.lastSessionURL else { return }
            let mic = Self.seconds(session.appending(path: Recorder.micFileName))
            let system = Self.seconds(session.appending(path: Recorder.systemFileName))
            var parts = [mic.map { String(format: "mic.m4a %.1f s", $0) } ?? "mic.m4a missing"]
            parts.append(system.map { String(format: "system.m4a %.1f s", $0) } ?? "system.m4a missing (nothing was playing?)")
            if let error = recorder.errorMessage { parts.append(error) }
            testState = .done(folder: session, summary: parts.joined(separator: " · "), ok: mic != nil)
        }
    }

    func deleteTestRecording() {
        if case .done(let folder, _, _) = testState, folder.path.contains("/.meetings/") {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
        testState = .notStarted
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
    }

    private static func seconds(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

// MARK: - Window

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var projectStore: ProjectStore
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chào mừng tới lắng").font(.largeTitle.bold())
                    Text("Ghi âm cuộc họp, chép lời và tóm tắt, tất cả chạy trên máy bạn. Làm lần lượt các bước dưới đây.")
                        .foregroundStyle(.secondary)
                }

                step(1, "Chọn thư mục dự án", done: projectStore.folderURL != nil,
                     detail: projectStore.folderURL?.path ?? "Bản ghi được lưu trong thư mục .meetings bên trong dự án.") {
                    Button(projectStore.folderURL == nil ? "Chọn thư mục…" : "Đổi…") { projectStore.chooseFolder() }
                }

                step(2, "Quyền micro", done: model.micStatus == .authorized,
                     detail: "Để ghi giọng của bạn vào mic.m4a.") {
                    if model.micStatus == .notDetermined {
                        Button("Cho phép micro") { model.requestMicrophone() }
                    } else if model.micStatus != .authorized {
                        Button("Mở Cài đặt hệ thống") { Recorder.openPrivacySettings("Privacy_Microphone") }
                    }
                }

                step(3, "Quyền ghi màn hình & âm thanh hệ thống", done: model.screenAllowed,
                     detail: "macOS chỉ cho thu âm thanh của Zoom/Meet/Teams qua quyền này. lắng không lưu hình ảnh nào. Sau khi bật, cần mở lại lắng.") {
                    if !model.screenAllowed {
                        Button("Cho phép") { model.requestScreenRecording() }
                        Button("Mở Cài đặt hệ thống") { Recorder.openPrivacySettings("Privacy_ScreenCapture") }
                        if model.screenRequested {
                            Button("Đã bật, mở lại lắng") { model.relaunch() }.buttonStyle(.borderedProminent)
                        }
                    }
                }

                step(4, "Ollama", done: model.ollamaRunning,
                     detail: model.ollamaRunning ? "Đang chạy." : model.ollamaInstalled
                        ? "Đã cài nhưng chưa chạy."
                        : "Cần cho phần tóm tắt và hỏi đáp. Cài từ ollama.com, hoặc: brew install --cask ollama-app") {
                    if !model.ollamaRunning {
                        Button(model.ollamaInstalled ? "Mở Ollama" : "Mở ollama.com") { model.openOllama() }
                    }
                }

                step(5, "Tải model", done: model.whisperDownloaded && model.isInstalled(model.llmModel)
                        && model.isInstalled(model.embeddingModel),
                     detail: "Chỉ tải một lần; sau đó chạy hoàn toàn offline.") {
                    EmptyView()
                }
                VStack(alignment: .leading, spacing: 8) {
                    modelRow("Whisper \(AppSettings.model.rawValue)", size: "~1.6 GB", key: AppSettings.model.rawValue,
                             done: model.whisperDownloaded, enabled: true) { model.downloadWhisper() }
                    modelRow(model.llmModel, size: "~5.2 GB", key: model.llmModel,
                             done: model.isInstalled(model.llmModel), enabled: model.ollamaRunning) {
                        model.downloadOllamaModel(model.llmModel)
                    }
                    modelRow(model.embeddingModel, size: "~1.2 GB", key: model.embeddingModel,
                             done: model.isInstalled(model.embeddingModel), enabled: model.ollamaRunning) {
                        model.downloadOllamaModel(model.embeddingModel)
                    }
                }
                .padding(.leading, 36)

                step(6, "Ghi thử 10 giây", done: { if case .done(_, _, true) = model.testState { return true }; return false }(),
                     detail: testDetail) {
                    switch model.testState {
                    case .notStarted:
                        Button("Ghi thử") { model.testRecording() }
                            .disabled(projectStore.folderURL == nil || model.micStatus != .authorized)
                    case .recording, .saving:
                        ProgressView().controlSize(.small)
                    case .done:
                        Button("Xóa bản ghi thử") { model.deleteTestRecording() }
                    }
                }

                HStack {
                    Spacer()
                    Button("Để sau") { dismissWindow(id: "onboarding") }
                    Button("Xong") {
                        model.finish()
                        dismissWindow(id: "onboarding")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .frame(width: 600, height: 680)
        .onAppear { model.startWatching() }
        .onDisappear { model.stopWatching() }
    }

    private var testDetail: String {
        switch model.testState {
        case .notStarted: "Mở một video có tiếng và nói vài câu, để kiểm tra cả micro lẫn âm thanh hệ thống."
        case .recording(let left): "Đang ghi… còn \(left) giây"
        case .saving: "Đang lưu…"
        case .done(_, let summary, _): summary
        }
    }

    private func step<Actions: View>(_ number: Int, _ title: String, done: Bool, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { actions() }.controlSize(.small)
            }
        }
    }

    private func modelRow(_ name: String, size: String, key: String, done: Bool, enabled: Bool,
                          download: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(done ? .green : .secondary)
            Text(name)
            Text(size).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let progress = model.downloads[key] {
                ProgressView(value: progress).frame(width: 120)
                Text("\(Int(progress * 100))%").font(.caption.monospacedDigit())
            } else if !done {
                Button("Tải") { download() }.controlSize(.small).disabled(!enabled)
            }
            if let error = model.downloadErrors[key] {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }
        }
    }
}
