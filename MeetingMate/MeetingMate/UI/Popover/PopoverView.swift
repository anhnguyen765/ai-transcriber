import SwiftUI
import UniformTypeIdentifiers

/// The menu bar popover: header, one of three states (idle / recording / processing·done),
/// notices, footer. The whole popover accepts dropped audio/video files.
struct PopoverView: View {
    let app: AppState
    @ObservedObject var recorder: Recorder
    @ObservedObject var projectStore: ProjectStore
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var summary: SummaryService
    @ObservedObject var indexer: ProjectIndexer

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false

    init(app: AppState) {
        self.app = app
        recorder = app.recorder
        projectStore = app.projectStore
        transcription = app.transcription
        summary = app.summary
        indexer = app.indexer
    }

    private enum Mode: Equatable { case capture, processing }

    private var mode: Mode {
        if recorder.state == .recording || recorder.state == .starting { return .capture }
        switch app.status {
        case .processing, .done: return .processing
        default: return .capture
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Group {
                switch mode {
                case .capture: CaptureSection(app: app, recorder: recorder, close: { dismiss() })
                case .processing: ProcessingSection(app: app, close: { dismiss() })
                }
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            PopoverNotices(app: app, recorder: recorder, transcription: transcription,
                           summary: summary, indexer: indexer)
            PopoverFooter(app: app, close: { dismiss() })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 320)
        .background(Color.white.opacity(0.77))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                    .strokeBorder(Color.water, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard projectStore.folderURL != nil,
                  let file = urls.first(where: Self.isAudioOrVideo) else { return false }
            app.importAudio(file)
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.slow, value: mode)
        .animation(Theme.Motion.standard, value: app.status)
        .onAppear {
            recorder.refreshPermissionStatus()
            app.refreshMeetings()
        }
    }

    private var header: some View {
        ProjectHeader(name: app.projectName, subtitle: app.projectSubtitle, status: app.projectStatus) {
            ProjectSwitcherItems(app: app)
        }
    }

    static func isAudioOrVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }
}

// MARK: - State A (idle) + B (recording)

/// Idle and recording share one ripple, so the core morphs instead of being replaced.
private struct CaptureSection: View {
    let app: AppState
    @ObservedObject var recorder: Recorder
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recording: Bool { recorder.state == .recording || recorder.state == .starting }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                RecorderRipple(recorder: recorder, disabledReason: app.recordDisabledReason,
                               toggle: app.toggleRecording)
                if recording {
                    RecordingInfo(recorder: recorder)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 3) {
                        Text("Ghi âm")
                            .typeStyle(.recordCaption)
                            .foregroundStyle(.ink)
                        Text(app.recordDisabledReason == nil ? "chạm để bắt đầu · ⌃⌥R" : "chọn thư mục dự án để bắt đầu")
                            .typeStyle(.caption)
                            .foregroundStyle(.ink3)
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)

            if recording {
                RecordingControls(app: app, recorder: recorder)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            } else {
                IdleExtras(app: app, close: close)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.slow, value: recording)
    }
}

private struct IdleExtras: View {
    let app: AppState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OpenFileRow(disabledReason: app.recordDisabledReason.map { _ in
                String(localized: "Chọn thư mục dự án trước khi mở file.")
            }) {
                app.chooseAudioFile()
            }
            let recent = Array(app.meetings.prefix(3))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel("gần đây")
                        .padding(.leading, 8)
                        .padding(.bottom, 4)
                    ForEach(recent) { meeting in
                        MeetingRow(title: app.displayTitle(meeting), start: meeting.date, duration: meeting.duration) {
                            app.router.openMeeting(meeting.folder)
                            close()
                        }
                    }
                }
            }
        }
    }
}

/// Timer + "bạn" / "người khác" legend with live mini waveforms.
private struct RecordingInfo: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: LangFormat.clock(recorder.elapsed))
                .typeStyle(.timer)
                .foregroundStyle(.ink)
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel("Đã ghi \(LangFormat.duration(recorder.elapsed))")
            let levels = recorder.levels
            HStack(spacing: 16) {
                LegendItem(label: SpeakerKind.me.label, color: .water, values: levels.micHistory)
                LegendItem(label: SpeakerKind.others.label, color: .sandInk, values: levels.systemHistory)
            }
        }
    }

    private struct LegendItem: View {
        let label: String
        let color: Color
        let values: [Double]

        var body: some View {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(verbatim: label)
                    .typeStyle(.caption)
                    .foregroundStyle(.ink2)
                MiniBars(values: values, color: color)
            }
        }
    }
}

private struct RecordingControls: View {
    let app: AppState
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button("Tạm dừng") {}
                    .buttonStyle(.lang(.secondary, fullWidth: true))
                    .disabled(because: String(localized: "lắng chưa hỗ trợ tạm dừng. Bấm Dừng & lưu rồi ghi tiếp khi cần."))
                Button("Dừng & lưu", action: app.toggleRecording)
                    .buttonStyle(.lang(.record, fullWidth: true))
                    .disabled(because: recorder.state == .recording ? nil : String(localized: "Đang bắt đầu ghi…"))
            }
            Text("Đeo tai nghe để lắng tách giọng bạn rõ hơn.")
                .typeStyle(.caption)
                .foregroundStyle(.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - State C (processing / done)

private struct ProcessingSection: View {
    let app: AppState
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: PipelineProgress? {
        if case .processing(let p) = app.status { p } else { nil }
    }

    private var done: PipelineDone? {
        if case .done(let d) = app.status { d } else { nil }
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                RippleView(phase: .settling(done: done != nil), size: 132)
                Text(done == nil ? "đang lắng…" : "đã lắng")
                    .typeStyle(.settlingCaption)
                    .foregroundStyle(.deep)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)

            if let progress {
                PipelineCard(progress: progress)
                    .transition(.opacity)
            }
            if let done {
                DoneToast(title: done.title, actionItemCount: done.actionItemCount) {
                    app.viewDone()
                    close()
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }

            // Recording can always start again, even while the last meeting is processed.
            HStack {
                Button {
                    app.toggleRecording()
                } label: {
                    Label("Ghi cuộc mới", systemImage: "mic")
                }
                .buttonStyle(.lang(.pill, radius: Theme.Radius.pill))
                .disabled(because: app.recordDisabledReason)
                Spacer()
                if done != nil {
                    Button("Ẩn") { app.dismissDone() }
                        .buttonStyle(.plain)
                        .typeStyle(.caption)
                        .foregroundStyle(.ink3)
                }
            }
        }
    }
}

// MARK: - Notices

/// Permissions, Ollama/model problems and errors, as calm sand callouts.
private struct PopoverNotices: View {
    let app: AppState
    @ObservedObject var recorder: Recorder
    @ObservedObject var transcription: TranscriptionService
    @ObservedObject var summary: SummaryService
    @ObservedObject var indexer: ProjectIndexer

    var body: some View {
        VStack(spacing: 8) {
            if recorder.micPermissionMissing {
                NoticeCard(text: String(localized: "lắng chưa được dùng micro. Bật lắng trong Quyền riêng tư → Micrô."),
                           actions: [.init(title: String(localized: "Mở Cài đặt hệ thống")) {
                               Recorder.openPrivacySettings("Privacy_Microphone")
                           }])
            }
            if recorder.screenPermissionMissing {
                NoticeCard(text: String(localized: "Cần quyền Ghi màn hình để thu tiếng người khác. Bật lắng trong Quyền riêng tư → Ghi màn hình & âm thanh hệ thống, rồi mở lại lắng."),
                           actions: [.init(title: String(localized: "Mở Cài đặt hệ thống")) {
                               Recorder.openPrivacySettings("Privacy_ScreenCapture")
                           }])
            }
            switch summary.problem {
            case .ollamaNotRunning:
                NoticeCard(text: String(localized: "Ollama chưa chạy nên chưa tóm tắt được."),
                           actions: [.init(title: String(localized: "Mở Ollama"), run: summary.openOllama),
                                     .init(title: String(localized: "Thử lại"), run: summary.retry)])
            case .modelMissing(let model):
                NoticeCard(text: String(localized: "Chưa tải model tóm tắt \(model)."),
                           actions: summary.isBusy ? [] : [.init(title: String(localized: "Tải model"),
                                                                 run: summary.downloadModel)])
            case nil:
                EmptyView()
            }
            switch indexer.problem {
            case .ollamaNotRunning where summary.problem != .ollamaNotRunning:
                NoticeCard(text: String(localized: "Ollama chưa chạy: dự án chỉ tìm được theo từ khóa."),
                           actions: [.init(title: String(localized: "Mở Ollama"), run: indexer.openOllamaAndRetry)])
            case .modelMissing(let model):
                NoticeCard(text: String(localized: "Chưa tải model \(model) để đọc dự án."),
                           actions: indexer.downloadProgress == nil
                               ? [.init(title: String(localized: "Tải model"), run: indexer.downloadModel)] : [],
                           progress: indexer.downloadProgress)
            default:
                EmptyView()
            }
            ForEach(errors, id: \.text) { error in
                NoticeCard(text: error.text, onClose: error.clear)
            }
        }
    }

    private var errors: [(text: String, clear: () -> Void)] {
        var list: [(String, () -> Void)] = []
        if let e = recorder.errorMessage { list.append((e, { recorder.errorMessage = nil })) }
        if let e = transcription.errorMessage { list.append((e, { transcription.errorMessage = nil })) }
        if let e = summary.errorMessage { list.append((e, { summary.errorMessage = nil })) }
        if let e = indexer.errorMessage { list.append((e, { indexer.errorMessage = nil })) }
        return list
    }
}
