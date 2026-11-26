import SwiftUI

/// The core of the ripple: deep circle with a white mic (idle) that morphs into
/// a rec circle with a white rounded stop square (recording).
struct RecordButton: View {
    var isRecording: Bool
    /// Starting or saving: shows a spinner and ignores clicks.
    var isBusy = false
    /// Non-nil = disabled, and the reason is shown on hover.
    var disabledReason: String?
    /// 36 % of a 196 pt ripple.
    var diameter: CGFloat = 196 * 0.36
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fill: Color { isRecording ? .rec : .deep }
    private var glow: Color { isRecording ? .rec : .water }
    private var iconTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                // Soft white highlight near the top, like light on water.
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: diameter * 0.62, height: diameter * 0.34)
                    .offset(y: -diameter * 0.22)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .transition(.opacity)
                } else if isRecording {
                    RoundedRectangle(cornerRadius: diameter * 0.07, style: .continuous)
                        .fill(.white)
                        .frame(width: diameter * 0.3, height: diameter * 0.3)
                        .transition(iconTransition)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: diameter * 0.425, weight: .medium)) // 30 pt at 70 pt
                        .foregroundStyle(.white)
                        .transition(iconTransition)
                }
            }
            .frame(width: diameter, height: diameter)
            // Softer red glow while recording, so it doesn't muddy the water rings.
            .shadow(color: glow.opacity(isRecording ? 0.3 : 0.45), radius: diameter * (isRecording ? 0.14 : 0.2),
                    y: diameter * 0.06)
            .contentShape(Circle())
        }
        .buttonStyle(CorePressStyle(dimmed: disabledReason != nil && !isRecording))
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.morph, value: isRecording)
        .animation(Theme.Motion.fade, value: isBusy)
        .disabled(isBusy || disabledReason != nil)
        .help(disabledReason ?? (isRecording ? String(localized: "Dừng và lưu") : String(localized: "Bắt đầu ghi âm")))
        .accessibilityLabel(isRecording ? "Dừng ghi âm" : "Bắt đầu ghi âm")
    }
}

/// Slight shrink on press, a touch brighter on hover.
private struct CorePressStyle: ButtonStyle {
    /// Only a real "can't record" is dimmed; busy (starting/saving) keeps full color.
    var dimmed: Bool

    func makeBody(configuration: Configuration) -> some View {
        Pressable(pressed: configuration.isPressed, dimmed: dimmed) { configuration.label }
    }

    private struct Pressable<Content: View>: View {
        let pressed: Bool
        let dimmed: Bool
        @ViewBuilder let content: Content
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            content
                .scaleEffect(pressed ? 0.96 : 1)
                .brightness(hovering && isEnabled ? 0.04 : 0)
                .opacity(dimmed ? 0.55 : 1)
                .onHover { hovering = $0 }
                .animation(Theme.Motion.standard, value: pressed)
        }
    }
}

#Preview("RecordButton") {
    @Previewable @State var recording = false
    HStack(spacing: 32) {
        RecordButton(isRecording: recording) { recording.toggle() }
        RecordButton(isRecording: false, isBusy: true) {}
        RecordButton(isRecording: false, disabledReason: "Chọn thư mục dự án trước khi ghi âm.") {}
    }
    .padding(40)
    .background(.white)
}
