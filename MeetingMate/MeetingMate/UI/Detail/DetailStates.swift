import SwiftUI

/// Recording too short to summarize, or no speech found. A calm state instead of empty tabs.
struct ShortRecordingState: View {
    let duration: Double
    let noSpeech: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            RippleView(phase: .settling(done: true), size: 132)
            Text(verbatim: noSpeech ? "Không nghe thấy lời nói nào" : "Bản ghi này quá ngắn để tóm tắt")
                .typeStyle(TypeStyle(family: .serif(italic: false), size: 20))
                .foregroundStyle(.ink)
                .multilineTextAlignment(.center)
            Text(verbatim: noSpeech
                 ? "Thời lượng \(LangFormat.duration(duration)) · không có lời nói rõ ràng"
                 : "Thời lượng \(LangFormat.duration(duration))")
                .typeStyle(.caption)
                .foregroundStyle(.ink2)
            HStack(spacing: 8) {
                Button("Nghe lại", action: onPlay)
                    .buttonStyle(.lang(.secondary))
                Button("Xoá cuộc họp", action: onDelete)
                    .buttonStyle(.lang(.secondary))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

/// The summary failed: the error in a sand callout, with a retry button.
struct SummaryFailedBox: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("không tóm tắt được", color: .sandInk)
            Text(verbatim: message)
                .typeStyle(.ui(13, lineHeight: 19))
                .foregroundStyle(.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Thử lại", action: retry)
                .buttonStyle(.lang(.secondary, radius: Theme.Radius.pill))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.callout, style: .continuous)
            .fill(Color.sand.opacity(0.45)))
    }
}

/// Transcribed but no summary yet (or summarizing now): the pipeline card on top of the transcript.
struct SummaryPendingCard: View {
    let title: String
    let detail: String
    let canStart: Bool
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PipelineCard(progress: PipelineProgress(folder: nil, title: title, step: .summarize,
                                                    fraction: 0.7, detail: detail, eta: nil, waiting: 0))
            if canStart {
                Button("Tóm tắt ngay", action: start)
                    .buttonStyle(.lang(.secondary, radius: Theme.Radius.pill))
            }
        }
    }
}
