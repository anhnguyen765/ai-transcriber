import SwiftUI
import AppKit

/// What the menu bar icon shows. Drawn in points on an 18 × 18 canvas.
struct MenuBarGlyphState: Hashable {
    var layers = 3          // sediment bars shown, bottom up (0…3)
    var drop = true         // teardrop above the bowl
    var dot = false         // recording: a solid dot where the drop is
    var check = false       // done: a check where the drop is
    var recording = false   // recording tints the icon rec and is not a template

    static let idle = MenuBarGlyphState()
    static let recording = MenuBarGlyphState(layers: 3, drop: false, dot: true, recording: true)
    static let done = MenuBarGlyphState(layers: 3, drop: false, check: true)
    static func processing(_ layers: Int) -> MenuBarGlyphState {
        MenuBarGlyphState(layers: layers, drop: true)
    }
}

/// Builds menu bar images once per state and caches them.
/// Idle, processing and done are template images (macOS tints them for light or dark menu bars).
@MainActor
enum MenuBarGlyph {
    private static var cache: [MenuBarGlyphState: NSImage] = [:]

    static func image(for state: MenuBarGlyphState) -> NSImage {
        if let hit = cache[state] { return hit }
        let renderer = ImageRenderer(content: MenuBarGlyphView(state: state).frame(width: 18, height: 18))
        renderer.scale = 2 // Retina
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = !state.recording
        cache[state] = image
        return image
    }
}

struct MenuBarGlyphView: View {
    let state: MenuBarGlyphState

    var body: some View {
        Canvas { context, _ in
            let ink: Color = state.recording ? Color(langHex: LangPalette.recHex) : .black
            MenuBarGlyphDrawing.draw(state, ink: ink, into: context)
        }
    }
}

enum MenuBarGlyphDrawing {
    /// Positions in points. The bowl sits at the bottom, the drop at the upper right.
    static func draw(_ s: MenuBarGlyphState, ink: Color, into base: GraphicsContext) {
        var ctx = base

        // Bowl: a filled crescent, 1.5 pt walls.
        var bowl = Path()
        LangMarkScene.appendLowerHalf(&bowl, cx: 9, y: 7, rx: 7.6, ry: 6, closed: true)
        LangMarkScene.appendLowerHalf(&bowl, cx: 9, y: 7, rx: 6.1, ry: 4.5, closed: true)
        ctx.fill(bowl, with: .color(ink), style: FillStyle(eoFill: true))

        // Sediment bars, bottom (widest) to top (shortest). Each has a 0.9 pt stroke.
        let ys: [CGFloat] = [10.2, 8.8, 7.4]
        let halfWidths: [CGFloat] = [2.6, 2.0, 1.4]
        for i in 0..<min(max(s.layers, 0), 3) {
            var bar = Path()
            bar.move(to: CGPoint(x: 9 - halfWidths[i], y: ys[i]))
            bar.addLine(to: CGPoint(x: 9 + halfWidths[i], y: ys[i]))
            ctx.stroke(bar, with: .color(ink), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        }

        let spot = CGPoint(x: 12.3, y: 3.6)

        if s.drop {
            // Teardrop 4.2 pt tall, rotated 28° clockwise, same shape as the big mark.
            let transform = CGAffineTransform(scaleX: 4.2 / 184, y: 4.2 / 184)
                .concatenating(CGAffineTransform(rotationAngle: 28 * .pi / 180))
                .concatenating(CGAffineTransform(translationX: spot.x, y: spot.y))
            ctx.fill(LangMarkScene.teardrop().applying(transform), with: .color(ink))
        }
        if s.dot {
            let r: CGFloat = 1.3
            ctx.fill(Path(ellipseIn: CGRect(x: spot.x - r, y: spot.y - r, width: r * 2, height: r * 2)),
                     with: .color(ink))
        }
        if s.check {
            var tick = Path()
            tick.move(to: CGPoint(x: spot.x - 1.4, y: spot.y + 0.1))
            tick.addLine(to: CGPoint(x: spot.x - 0.4, y: spot.y + 1.1))
            tick.addLine(to: CGPoint(x: spot.x + 1.4, y: spot.y - 1.1))
            ctx.stroke(tick, with: .color(ink), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
        }
    }
}
