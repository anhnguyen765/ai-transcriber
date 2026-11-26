import SwiftUI

/// Meeting title + ETA, step indicator, 4 pt progress bar, and what is happening now.
struct PipelineCard: View {
    let progress: PipelineProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: progress.title)
                    .typeStyle(.bodyMedium)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let eta = progress.eta {
                    Text(verbatim: eta)
                        .typeStyle(.monoSmall)
                        .foregroundStyle(.ink3)
                        .contentTransition(.numericText())
                }
            }
            StepIndicator(current: progress.step)
            ProgressBar(fraction: progress.fraction)
            Text(verbatim: detailLine)
                .typeStyle(.caption)
                .foregroundStyle(.ink2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .padding(14)
        .cardBackground(radius: Theme.Radius.card, fill: 0.75)
        .animation(Theme.Motion.standard, value: progress)
        .accessibilityElement(children: .combine)
    }

    private var detailLine: String {
        guard progress.waiting > 0 else { return progress.detail }
        return progress.detail + " · " + String(localized: "còn \(progress.waiting) cuộc họp chờ")
    }
}

/// ghi âm → chép lời → tóm tắt → xong
struct StepIndicator: View {
    let current: PipelineStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PipelineStep.allCases, id: \.self) { step in
                if step != .record {
                    Capsule()
                        .fill(step <= current ? Color.water.opacity(0.5) : .line)
                        .frame(height: 1)
                        .frame(minWidth: 6)
                }
                HStack(spacing: 4) {
                    StepDot(state: state(of: step))
                    Text(verbatim: step.label)
                        .typeStyle(step == current ? .ui(11, .medium) : .caption)
                        .foregroundStyle(step == current ? Color.deep : step < current ? .ink2 : .ink3)
                        .fixedSize()
                }
            }
        }
    }

    private func state(of step: PipelineStep) -> StepDot.State {
        step < current ? .done : step == current ? (current == .done ? .done : .active) : .todo
    }
}

struct StepDot: View {
    enum State { case done, active, todo }
    let state: State

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(.water)
                Image(systemName: "checkmark")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(.white)
            case .active:
                Circle().fill(.foam)
                Circle().strokeBorder(.water, lineWidth: 1.5)
                Circle().fill(.water).frame(width: 4, height: 4)
            case .todo:
                Circle().strokeBorder(.line, lineWidth: 1.5)
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// 4 pt progress bar: water over a line-colored track.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.line)
                Capsule().fill(.water)
                    .frame(width: max(4, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

/// Tiny live waveform: 8 bars from recent levels (legend row "bạn" / "người khác").
struct MiniBars: View {
    let values: [Double]
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(values.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 3 + 9 * min(max(values[i], 0), 1))
            }
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.15), value: values)
        .accessibilityHidden(true)
    }
}

/// "Mở file âm thanh…" row with a dashed water border.
struct OpenFileRow: View {
    var disabledReason: String?
    var isTargeted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 15))
                    .foregroundStyle(.water)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mở file âm thanh…")
                        .typeStyle(.bodyMedium)
                        .foregroundStyle(.ink)
                    Text("hoặc kéo thả vào đây")
                        .typeStyle(.caption)
                        .foregroundStyle(.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.callout, style: .continuous)
                .fill(isTargeted ? Color.foam : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.callout, style: .continuous)
                .strokeBorder(Color.water.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(because: disabledReason)
    }
}

/// Something the user should know or fix (permissions, Ollama, errors). Sand callout.
struct NoticeCard: View {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let run: () -> Void
    }

    let text: String
    var actions: [Action] = []
    var progress: Double?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.sandInk)
                    .padding(.top, 1)
                Text(verbatim: text)
                    .typeStyle(.ui(12, lineHeight: 17))
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.ink3)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Ẩn")
                }
            }
            if let progress { ProgressBar(fraction: progress) }
            if !actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(actions) { action in
                        Button(action.title, action: action.run)
                            .buttonStyle(.lang(.secondary, radius: Theme.Radius.pill))
                            .controlSize(.small)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.callout, style: .continuous)
            .fill(Color.sand.opacity(0.45)))
    }
}

#Preview("Pipeline") {
    VStack(spacing: 14) {
        PipelineCard(progress: PipelineProgress(folder: nil, title: SampleData.meetingTitle, step: .summarize,
                                                fraction: 0.82, detail: "đang tóm tắt phần 2/3 · dùng 6 tài liệu dự án",
                                                eta: "~1 phút", waiting: 0))
        PipelineCard(progress: PipelineProgress(folder: nil, title: "Cuộc họp 10:00", step: .transcribe,
                                                fraction: 0.4, detail: "đang chép lời · 48%", eta: "~3 phút",
                                                waiting: 1))
        HStack { MiniBars(values: [0.1, 0.5, 0.9, 0.3, 0.6, 0.2, 0.8, 0.4], color: .water) }
        OpenFileRow {}
        NoticeCard(text: "Ollama chưa chạy. Mở Ollama để tóm tắt cuộc họp.",
                   actions: [.init(title: "Mở Ollama") {}, .init(title: "Thử lại") {}], onClose: {})
    }
    .padding(16)
    .frame(width: 320)
    .background(.white)
}
