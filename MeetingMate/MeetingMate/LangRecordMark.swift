import SwiftUI

/// Small brand mark in the menu. When recording starts, the drop falls into the bowl and a
/// ripple spreads from the rim (0.6 s). With Reduce Motion on, the mark just shows the
/// drop in the bowl, with no movement.
struct LangRecordMark: View {
    var isRecording: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    private static let duration: TimeInterval = 0.6

    var body: some View {
        TimelineView(.animation(paused: startedAt == nil)) { timeline in
            let t = progress(at: timeline.date)
            ZStack {
                LangMark(params: markParams(fall: isRecording ? fallProgress(t) : 0))
                    .frame(width: 40, height: 40)
                if startedAt != nil, t > 0.4 {
                    ripple(progress: (t - 0.4) / 0.2)
                }
            }
            .frame(width: 40, height: 40)
        }
        .frame(width: 40, height: 40)
        .onChange(of: isRecording) { _, nowRecording in
            if nowRecording && !reduceMotion { startedAt = .now }
        }
        .task(id: startedAt) {
            guard startedAt != nil else { return }
            try? await Task.sleep(for: .seconds(Self.duration + 0.05))
            startedAt = nil
        }
    }

    /// 0…1 over the whole animation. 1 when idle.
    private func progress(at date: Date) -> Double {
        guard let start = startedAt else { return 1 }
        return min(1, max(0, date.timeIntervalSince(start) / Self.duration))
    }

    /// The fall takes the first 0.4 s (ease-in); the ripple takes the rest.
    private func fallProgress(_ t: Double) -> Double {
        let f = min(1, t / 0.66)
        return f * f
    }

    /// Mark params: flat, no trail. While recording, the drop moves from above the bowl
    /// down into it (`fall` goes 0 → 1). Otherwise the drop stays above the bowl.
    private func markParams(fall: Double) -> LangMarkParams {
        var p = LangMarkParams()
        p.variant = .flat
        p.showTrail = false
        p.showBackground = false
        p.dropOffsetY = 0.20 * fall
        return p
    }

    /// Ellipse on the rim, growing and fading out.
    private func ripple(progress r: Double) -> some View {
        let k = min(1, max(0, r))
        return Ellipse()
            .stroke(Color(langHex: LangPalette.waterHex, opacity: 0.8 * (1 - k)), lineWidth: 1)
            .frame(width: 14 + 16 * k, height: 4 + 4 * k)
            .position(x: 20, y: 23)
    }
}
