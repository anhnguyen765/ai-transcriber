import SwiftUI

/// The panel that opens when you click the menu bar icon.
struct MenuView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var projectStore: ProjectStore
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var summary: SummaryService
    @ObservedObject var indexer: ProjectIndexer
    @ObservedObject var glossary: GlossaryModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Project
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(projectStore.projectName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Choose Project Folder…") {
                projectStore.chooseFolder()
            }
            .disabled(recorder.state != .idle)

            // Project index status
            if let status = indexer.statusText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if let value = indexer.progressValue {
                        ProgressView(value: value).controlSize(.small)
                    }
                }
            }
            switch indexer.problem {
            case .ollamaNotRunning:
                HStack {
                    Text("Ollama chưa chạy: dự án chỉ tìm được theo từ khóa.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Ollama") { indexer.openOllamaAndRetry() }.controlSize(.small)
                }
            case .modelMissing(let model):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Model \(model) chưa được tải về.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Download") { indexer.downloadModel() }
                            .controlSize(.small)
                            .disabled(indexer.downloadProgress != nil)
                    }
                    if let p = indexer.downloadProgress {
                        ProgressView(value: p).controlSize(.small)
                        Text("Đang tải \(model)… \(Int(p * 100))%").font(.caption).monospacedDigit()
                    }
                }
            case nil:
                EmptyView()
            }
            if let error = indexer.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Record / Stop
            if recorder.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Recording  \(recorder.elapsedText)")
                        .monospacedDigit()
                }
            }
            Button(action: toggleRecording) {
                Label(recordButtonTitle,
                      systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(projectStore.folderURL == nil
                      || recorder.state == .starting || recorder.state == .stopping)

            Button {
                NSApp.activate()
                openWindow(id: "ask")
            } label: {
                Label("Hỏi về dự án…", systemImage: "bubble.left.and.text.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(projectStore.folderURL == nil)

            // Permission warnings
            if recorder.micPermissionMissing {
                PermissionWarning(
                    text: "Microphone access is off. Turn on lắng in Privacy & Security → Microphone.",
                    pane: "Privacy_Microphone")
            }
            if recorder.screenPermissionMissing {
                PermissionWarning(
                    text: "System audio needs Screen Recording access. Turn on lắng in Privacy & Security → Screen & System Audio Recording, then quit and reopen lắng.",
                    pane: "Privacy_ScreenCapture")
            }

            // Errors
            if let error = recorder.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if recorder.state == .idle, let last = recorder.lastSessionURL {
                Text("Saved: \(last.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Transcription status
            if let status = transcription.statusText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status)
                        .font(.callout)
                        .monospacedDigit()
                    if let value = transcription.progressValue {
                        ProgressView(value: value)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    if transcription.waitingCount > 0 {
                        Text("+ \(transcription.waitingCount) waiting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error = transcription.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !transcription.isBusy, let transcript = transcription.lastTranscriptURL {
                Button("Open Last Transcript") { NSWorkspace.shared.open(transcript) }
            }

            // Summary status
            if let status = summary.statusText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status)
                        .font(.callout)
                        .monospacedDigit()
                    if let value = summary.progressValue {
                        ProgressView(value: value)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            switch summary.problem {
            case .ollamaNotRunning:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Ollama chưa chạy. Mở Ollama để tóm tắt cuộc họp.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Ollama") { summary.openOllama() }
                        Button("Thử lại") { summary.retry() }
                    }
                }
            case .modelMissing(let model):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Model \(model) chưa được tải về.", systemImage: "arrow.down.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Download model") { summary.downloadModel() }
                        .disabled(summary.isBusy)
                }
            case nil:
                EmptyView()
            }
            if let error = summary.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Divider()

            Button("Meetings Library…") {
                NSApp.activate()
                openWindow(id: "meetings")
            }
            .disabled(projectStore.folderURL == nil)
            Button("Transcribe File…") {
                transcription.chooseAndTranscribeFile(projectFolder: projectStore.folderURL)
            }
            .disabled(projectStore.folderURL == nil)
            Button("Re-transcribe Last Meeting") {
                transcription.retranscribeLastMeeting(projectFolder: projectStore.folderURL)
            }
            .disabled(projectStore.folderURL == nil)
            Button("Summarize Last Meeting") {
                summary.summarizeLastMeeting(projectFolder: projectStore.folderURL)
            }
            .disabled(projectStore.folderURL == nil)
            Button("Open Last Summary") {
                summary.openLastSummary(projectFolder: projectStore.folderURL)
            }
            .disabled(projectStore.folderURL == nil)
            Button("Reindex Project") { indexer.reindex() }
                .disabled(projectStore.folderURL == nil || indexer.isWorking)
            Button("Show Indexed Files") {
                NSApp.activate()
                openWindow(id: "indexed-files")
            }
            .disabled(projectStore.folderURL == nil)
            Button("Suggest Glossary from Project") {
                glossary.suggest(store: indexer.store, projectFolder: indexer.projectFolder)
                NSApp.activate()
                openWindow(id: "glossary")
            }
            .disabled(indexer.store == nil || glossary.isWorking)
            Button("Open Recordings Folder", action: openRecordingsFolder)
                .disabled(projectStore.folderURL == nil)
            Button("Settings…") {
                NSApp.activate() // bring the Settings window to the front
                openSettings()
            }
            Button("Quit lắng") {
                // AppDelegate stops & saves any running recording before the app exits.
                NSApp.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { recorder.refreshPermissionStatus() }
    }

    private var recordButtonTitle: String {
        switch recorder.state {
        case .idle: "Record"
        case .starting: "Starting…"
        case .recording: "Stop"
        case .stopping: "Saving…"
        }
    }

    private func toggleRecording() {
        Task {
            if recorder.isRecording {
                await recorder.stop()
            } else {
                await recorder.start(projectFolder: projectStore.folderURL)
            }
        }
    }

    private func openRecordingsFolder() {
        // If we just recorded, show that session selected in Finder.
        if let last = recorder.lastSessionURL,
           FileManager.default.fileExists(atPath: last.path) {
            NSWorkspace.shared.activateFileViewerSelecting([last])
            return
        }
        guard let meetings = projectStore.meetingsFolderURL else { return }
        do {
            try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
            NSWorkspace.shared.open(meetings)
        } catch {
            recorder.errorMessage = "Could not open .meetings: \(error.localizedDescription)"
        }
    }
}

/// Orange warning text with a button that opens the right System Settings page.
private struct PermissionWarning: View {
    let text: String
    let pane: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                Recorder.openPrivacySettings(pane)
            }
        }
    }
}
