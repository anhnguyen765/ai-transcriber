import SwiftUI

/// The near-black pill beside the notch while recording: rec dot, timer, tiny light-water waveform.
/// Click opens the popover.
struct NotchIslandView: View {
    @ObservedObject var recorder: Recorder
    let open: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.rec)
                    .frame(width: 7, height: 7)
                    .opacity(pulse ? 0.45 : 1)
                Text(verbatim: LangFormat.clock(recorder.elapsed))
                    .typeStyle(.mono(12, medium: true))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                MiniBars(values: recorder.levels.micHistory, color: Color(hex: 0x9CCBDD))
            }
            .padding(.horizontal, 12)
            .frame(width: NotchGeometry.pillSize.width, height: NotchGeometry.pillSize.height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.notch, style: .continuous).fill(Color.notch))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.notch, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Mở lắng")
        .accessibilityLabel("Đang ghi âm. Mở lắng")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

#if DEBUG
#Preview("NotchIsland") {
    NotchIslandView(recorder: Recorder()) {}
        .padding(20)
        .background(Color.black.opacity(0.85))
}
#endif
