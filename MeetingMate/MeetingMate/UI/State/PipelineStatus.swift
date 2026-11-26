import Foundation

/// ghi âm → chép lời → tóm tắt → xong
enum PipelineStep: Int, CaseIterable, Comparable {
    case record, transcribe, summarize, done

    var label: String {
        switch self {
        case .record: String(localized: "ghi âm")
        case .transcribe: String(localized: "chép lời")
        case .summarize: String(localized: "tóm tắt")
        case .done: String(localized: "xong")
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A meeting that is being saved, transcribed or summarized.
struct PipelineProgress: Equatable {
    var folder: URL?
    var title: String
    var step: PipelineStep
    /// 0…1 over the whole pipeline (for the 4 pt bar).
    var fraction: Double
    /// "đang tóm tắt phần 2/3 · dùng 6 tài liệu dự án"
    var detail: String
    /// "~1 phút", or nil when unknown.
    var eta: String?
    /// Other meetings waiting in the queue.
    var waiting: Int
}

/// A meeting that just finished.
struct PipelineDone: Equatable {
    var folder: URL
    var title: String
    var actionItemCount: Int
    var at: Date
}

/// One model for the popover's pipeline card, the menu bar icon and the NotchIsland.
enum PipelineStatus: Equatable {
    case idle
    case recording
    case processing(PipelineProgress)
    case done(PipelineDone)

    /// How long a finished meeting stays on the popover (unless dismissed or viewed earlier).
    static let doneLifetime: TimeInterval = 10 * 60

    var isProcessing: Bool { if case .processing = self { true } else { false } }

    /// Everything the derivation needs, as plain values (so it can be unit tested).
    struct Inputs {
        var recorder: Recorder.State
        var transcription: TranscriptionService.Phase
        var transcriptionWaiting: Int = 0
        var summary: SummaryService.Phase
        var contextDocuments: Int?
        /// The meeting being worked on, and its display title.
        var folder: URL?
        var title: String = ""
        /// When the current step started (for the ETA).
        var stepStartedAt: Date?
        var done: PipelineDone?
        var now = Date()
    }

    static func derive(_ input: Inputs) -> PipelineStatus {
        func progress(_ step: PipelineStep, _ fraction: Double, _ detail: String, eta: String? = nil) -> PipelineStatus {
            .processing(PipelineProgress(folder: input.folder, title: input.title, step: step,
                                         fraction: min(max(fraction, 0), 1), detail: detail, eta: eta,
                                         waiting: input.transcriptionWaiting))
        }

        switch input.recorder {
        case .starting, .recording: return .recording
        case .stopping: return progress(.record, 0.05, String(localized: "đang lưu bản ghi…"))
        case .idle: break
        }

        let transcribing = input.transcription != .idle && input.transcription != .waitingForSummary
        let summarizing = input.summary != .idle
            && !(input.summary == .waitingForTranscription && input.transcription != .idle)

        if transcribing {
            switch input.transcription {
            case .preparing:
                return progress(.transcribe, 0.08, String(localized: "đang chuẩn bị file…"))
            case .downloading(let p):
                return progress(.transcribe, 0.1, String(localized: "đang tải model chép lời · \(Int(p * 100))%"))
            case .loadingModel:
                return progress(.transcribe, 0.1, String(localized: "đang nạp model chép lời…"))
            case .transcribing(let p):
                return progress(.transcribe, 0.1 + 0.6 * p, String(localized: "đang chép lời · \(Int(p * 100))%"),
                                eta: eta(fractionDone: p, since: input.stepStartedAt, now: input.now))
            case .idle, .waitingForSummary:
                break
            }
        }
        if summarizing {
            switch input.summary {
            case .waitingForTranscription:
                return progress(.summarize, 0.7, String(localized: "đang chờ chép lời xong…"))
            case .checking:
                return progress(.summarize, 0.7, String(localized: "đang kiểm tra Ollama…"))
            case .downloadingModel(let p):
                return progress(.summarize, 0.7, String(localized: "đang tải model tóm tắt · \(Int(p * 100))%"))
            case .summarizing(let part, let total):
                var detail = total > 1 ? String(localized: "đang tóm tắt phần \(part)/\(total)")
                    : String(localized: "đang tóm tắt")
                if let docs = input.contextDocuments, docs > 0 {
                    detail += " · " + String(localized: "dùng \(docs) tài liệu dự án")
                }
                let done = total > 0 ? Double(part - 1) / Double(total) : 0
                return progress(.summarize, 0.7 + 0.3 * done, detail,
                                eta: part > 1 ? eta(fractionDone: done, since: input.stepStartedAt, now: input.now) : nil)
            case .idle:
                break
            }
        }
        if input.transcription == .waitingForSummary {
            return progress(.transcribe, 0.1, String(localized: "đang chờ tóm tắt cuộc trước xong…"))
        }
        if let done = input.done, input.now.timeIntervalSince(done.at) < doneLifetime {
            return .done(done)
        }
        return .idle
    }

    /// Remaining time from how long the step has run and how far it got.
    static func eta(fractionDone: Double, since start: Date?, now: Date) -> String? {
        guard let start, fractionDone > 0.05, fractionDone < 1 else { return nil }
        let elapsed = now.timeIntervalSince(start)
        let remaining = elapsed * (1 - fractionDone) / fractionDone
        if remaining < 60 { return String(localized: "<1 phút") }
        return String(localized: "~\(Int((remaining / 60).rounded())) phút")
    }
}

/// The menu bar icon's look.
enum MenuBarMode: Equatable {
    case idle, recording, processing, justDone
}
