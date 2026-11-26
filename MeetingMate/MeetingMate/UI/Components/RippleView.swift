import SwiftUI

/// "Mặt nước": four concentric water rings.
/// - idle: slow 4 s breathing.
/// - recording: inner rings (water) follow the mic, outer rings (sandInk) follow system audio.
/// - settling: ripples lose amplitude while lắng works, then go still with a small water dot.
/// Reduce Motion: no movement, only opacity changes.
struct RippleView<Center: View>: View {
    enum Phase: Equatable {
        case idle
        case recording
        /// `done` = processing finished: rings fade to still.
        case settling(done: Bool)
    }

    var phase: Phase
    /// 0…1, already smoothed (see `AudioLevels`).
    var micLevel: Double = 0
    var systemLevel: Double = 0
    var size: CGFloat = 196
    /// Shown in the middle for idle / recording (usually `RecordButton`).
    @ViewBuilder var center: Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phaseStart = Date()
    @State private var doneAt: Date?

    /// Ring diameters (fraction of `size`) and base opacities, inner → outer.
    static var rings: [(diameter: CGFloat, opacity: Double)] {
        [(0.50, 0.30), (0.67, 0.18), (0.84, 0.10), (1.00, 0.05)]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: timelinePaused)) { context in
            let t = context.date.timeIntervalSince(phaseStart)
            let sinceDone = doneAt.map { context.date.timeIntervalSince($0) }
            ZStack {
                ForEach(Self.rings.indices, id: \.self) { index in
                    let ring = Self.rings[index]
                    let look = ringLook(index: index, t: t, sinceDone: sinceDone)
                    Circle()
                        .fill(ringColor(index: index))
                        .frame(width: size * ring.diameter, height: size * ring.diameter)
                        .scaleEffect(look.scale)
                        .opacity(look.opacity)
                }
                if case .settling = phase {
                    Circle()
                        .fill(.water)
                        .frame(width: 10, height: 10)
                        .transition(.opacity)
                } else {
                    center
                }
            }
        }
        .frame(width: size, height: size)
        // Glide between the 30 fps level updates instead of stepping.
        .animation(.easeOut(duration: 0.15), value: micLevel)
        .animation(.easeOut(duration: 0.15), value: systemLevel)
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.standard, value: phase)
        .onChange(of: phase) { old, new in
            let now = Date()
            if case .settling(false) = old, case .settling(true) = new {
                doneAt = now // keep the running ripple, just start the fade-out
            } else {
                phaseStart = now
                doneAt = (new == .settling(done: true)) ? now : nil
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Look

    private var timelinePaused: Bool {
        if reduceMotion { return true }
        switch phase {
        case .recording: return true // audio levels drive the redraws
        case .settling(true): return doneAt.map { Date().timeIntervalSince($0) > Theme.Motion.settleDuration + 0.2 } ?? true
        default: return false
        }
    }

    private func ringColor(index: Int) -> Color {
        phase == .recording && index >= 2 ? .sandInk : .water
    }

    private func ringLook(index: Int, t: Double, sinceDone: Double?) -> (scale: CGFloat, opacity: Double) {
        let base = Self.rings[index].opacity
        switch phase {
        case .idle:
            guard !reduceMotion else { return (1, base) }
            // 0…1 ease-in-out breath, 4 s per loop, outer rings slightly behind.
            let b = (1 - cos(2 * .pi * (t - Double(index) * 0.25) / 4)) / 2
            return (1 + (Theme.Motion.breathingScale - 1) * b, base * (0.8 + 0.4 * b))

        case .recording:
            let level = index < 2 ? micLevel : systemLevel
            // Gentle brightness change; size carries most of the movement (less flicker).
            let opacity = base * (0.85 + 0.45 * level)
            guard !reduceMotion else { return (1, opacity) }
            // Outer ring of each pair moves a bit more, like a spreading ripple.
            let spread = index % 2 == 0 ? 0.75 : 1.0
            return (1 + (Theme.Motion.maxRingScale - 1) * level * spread, opacity)

        case .settling(let done):
            // Amplitude: 1 → 0.25 over ~1.5 s while working; → 0 over 1.5 s once done.
            var amplitude = 0.25 + 0.75 * exp(-t / (Theme.Motion.settleDuration / 3))
            var stillness = 1.0
            if done {
                let progress = min(max((sinceDone ?? Theme.Motion.settleDuration) / Theme.Motion.settleDuration, 0), 1)
                amplitude *= 1 - progress
                stillness = 1 - 0.4 * progress // rings fade to a calmer opacity
            }
            guard !reduceMotion else { return (1, base * (done ? 0.6 : 1)) }
            let wave = sin(2 * .pi * t / 2.4 - Double(index) * 0.9)
            return (1 + 0.05 * amplitude * wave, base * stillness * (0.85 + 0.3 * amplitude * wave))
        }
    }
}

extension RippleView where Center == EmptyView {
    init(phase: Phase, micLevel: Double = 0, systemLevel: Double = 0, size: CGFloat = 196) {
        self.init(phase: phase, micLevel: micLevel, systemLevel: systemLevel, size: size) { EmptyView() }
    }
}

// MARK: - Previews

#if DEBUG
/// Fake, speech-like levels so the canvas shows the recording ripple moving.
private struct FakeLevelsDriver<Content: View>: View {
    @State private var levels = AudioLevels()
    @ViewBuilder var content: (AudioLevels) -> Content

    var body: some View {
        content(levels)
            .task {
                var t = 0.0
                while !Task.isCancelled {
                    t += 1.0 / 30
                    let talk = max(0, sin(t * 2.3) * 0.6 + sin(t * 7.1) * 0.3 + .random(in: -0.1...0.2))
                    let other = max(0, sin(t * 0.9 + 1) * 0.5 + .random(in: -0.1...0.25))
                    levels.tick(mic: talk, system: other)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
    }
}

#Preview("Ripple · idle") {
    RippleView(phase: .idle) {
        RecordButton(isRecording: false) {}
    }
    .padding(40)
    .background(.white)
}

#Preview("Ripple · recording (fake levels)") {
    FakeLevelsDriver { levels in
        RippleView(phase: .recording, micLevel: levels.mic, systemLevel: levels.system) {
            RecordButton(isRecording: true) {}
        }
    }
    .padding(40)
    .background(.white)
}

#Preview("Ripple · settling → done") {
    @Previewable @State var done = false
    VStack(spacing: 16) {
        RippleView(phase: .settling(done: done), size: 132)
        Text("đang lắng…").typeStyle(.settlingCaption).foregroundStyle(.deep)
        Button(done ? "Làm lại" : "Xong") { done.toggle() }
    }
    .padding(40)
    .background(.white)
}
#endif
