import SwiftUI

// The "lắng" mark: a shallow glass bowl (the breve), 3 sediment layers inside it,
// and a teardrop of sound falling in (the acute accent).
//
// All geometry is written in a 1024 × 1024 design space and scaled to the view.
// Parameters that are fractions are fractions of the canvas (0…1).

enum LangVariant: String, CaseIterable, Identifiable {
    case glass, flat, lines
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: return "A · glass"
        case .flat: return "B · flat"
        case .lines: return "C · lines"
        }
    }
}

/// Export/draw groups. The drop group includes its trail dots.
enum LangPart: String, CaseIterable, Identifiable {
    case background, bowl, layers, drop
    var id: String { rawValue }
}

struct LangMarkParams: Equatable {
    var variant: LangVariant = .glass
    var bowlWidth: Double = 0.56        // bowl width, fraction of canvas
    var bowlDepth: Double = 0.20        // bowl depth (vertical radius), fraction of canvas
    var wallThickness: Double = 0.049   // glass wall thickness, fraction of canvas
    var layerCount: Int = 3             // 2 or 3
    var layerHeight: Double = 0.029     // thickness of each sediment bar
    var wobble: Double = 0.004          // wave amplitude of each bar
    var dropAngle: Double = 28          // degrees, clockwise
    var dropOffsetX: Double = 0         // added to the default drop position
    var dropOffsetY: Double = 0
    var showTrail: Bool = true
    var showBackground: Bool = true
}

// MARK: - Shape description (shared by the Canvas view and the SVG export)

enum LangFill {
    case none
    case solid(UInt32, Double)
    /// Vertical gradient from `top` at y0 to `bottom` at y1 (design space).
    case linear(UInt32, UInt32, CGFloat, CGFloat)
}

struct LangStroke {
    var color: UInt32
    var opacity: Double = 1
    var width: CGFloat
    var round: Bool = true
}

struct LangShape {
    var part: LangPart
    var path: Path
    var fill: LangFill = .none
    var evenOdd: Bool = false
    var stroke: LangStroke? = nil
    var blur: CGFloat = 0
}

enum LangMarkScene {
    static let unit: CGFloat = 1024

    /// Builds every shape of the mark for the given parameters.
    /// `layers` is 2 or 3. `boost` thickens walls and bars for small sizes (1 = normal).
    static func shapes(_ p: LangMarkParams, layers count: Int, boost: CGFloat) -> [LangShape] {
        let g = Geometry(p, boost: boost)
        let v = p.variant
        let u = unit
        var out: [LangShape] = []

        // Background: squircle (≈22.5% corner radius).
        if p.showBackground {
            let squircle = Path(roundedRect: CGRect(x: 0, y: 0, width: u, height: u),
                                cornerRadius: 230, style: .continuous)
            switch v {
            case .glass:
                out.append(LangShape(part: .background, path: squircle,
                                     fill: .linear(LangPalette.mistHex, LangPalette.foamHex, 0, u)))
                let inner = Path(roundedRect: CGRect(x: 4, y: 4, width: u - 8, height: u - 8),
                                 cornerRadius: 226, style: .continuous)
                out.append(LangShape(part: .background, path: inner,
                                     stroke: LangStroke(color: 0xFFFFFF, opacity: 0.4, width: 3)))
            case .flat, .lines:
                out.append(LangShape(part: .background, path: squircle,
                                     fill: .solid(LangPalette.mistHex, 1)))
            }
        }

        // Bowl: glass shadow, filled crescent (glass/flat) or centre-line stroke (lines).
        if v == .glass {
            let shadow = Path(ellipseIn: CGRect(x: g.cx - g.rx * 0.9, y: g.yc + g.ry - 6,
                                                width: g.rx * 1.8, height: 36))
            out.append(LangShape(part: .bowl, path: shadow,
                                 fill: .solid(LangPalette.deepHex, 0.22), blur: 12))
        }
        switch v {
        case .glass, .flat:
            var crescent = Path()
            appendLowerHalf(&crescent, cx: g.cx, y: g.yc, rx: g.rx, ry: g.ry, closed: true)
            appendLowerHalf(&crescent, cx: g.cx, y: g.yc, rx: g.irx, ry: g.iry, closed: true)
            let fill: LangFill = v == .glass
                ? .linear(0x3F7891, LangPalette.deepHex, g.yc, g.yc + g.ry)
                : .solid(LangPalette.deepHex, 1)
            out.append(LangShape(part: .bowl, path: crescent, fill: fill, evenOdd: true))
            if v == .glass {
                // Thin light rim where the glass opens.
                let rm = (g.rx + g.irx) / 2
                let rim = Path(ellipseIn: CGRect(x: g.cx - rm, y: g.yc - 16, width: rm * 2, height: 32))
                out.append(LangShape(part: .bowl, path: rim,
                                     stroke: LangStroke(color: LangPalette.mistHex, opacity: 0.9, width: 5)))
            }
        case .lines:
            var centre = Path()
            let rc = (g.rx + g.irx) / 2
            let rcy = (g.ry + g.iry) / 2
            appendLowerHalf(&centre, cx: g.cx, y: g.yc, rx: rc, ry: rcy, closed: false)
            out.append(LangShape(part: .bowl, path: centre,
                                 stroke: LangStroke(color: LangPalette.deepHex, width: g.t)))
        }

        // Layers: bottom (deep, widest) → top (sand, shortest). Each is a slightly wavy bar.
        let n = min(max(count, 2), 3)
        let halfWidthFactor: [CGFloat] = [0.44, 0.33, 0.22]
        let colors: [UInt32] = [LangPalette.deepHex, LangPalette.waterHex,
                                v == .lines ? LangPalette.sandInkHex : LangPalette.sandHex]
        let step = g.layerH + g.gap
        let yBottom = g.yc + g.iry * 0.72
        for i in 0..<n {
            let y = yBottom - CGFloat(i) * step
            let hw = g.irx * halfWidthFactor[i]
            let amp = g.wave * (i % 2 == 0 ? 1 : -1)
            let bar = wavyBar(cx: g.cx, y: y, halfWidth: hw, amplitude: amp)
            out.append(LangShape(part: .layers, path: bar,
                                 stroke: LangStroke(color: colors[i], width: g.layerH)))
            if v == .glass {
                // Soft highlight on the top edge of each bar.
                let hl = wavyBar(cx: g.cx, y: y - g.layerH * 0.25, halfWidth: hw * 0.9, amplitude: amp)
                out.append(LangShape(part: .layers, path: hl,
                                     stroke: LangStroke(color: 0xFFFFFF, opacity: 0.35, width: g.layerH * 0.22)))
            }
        }

        // Drop: teardrop rotated clockwise, centred at dropCenter.
        let transform = CGAffineTransform(rotationAngle: CGFloat(p.dropAngle) * .pi / 180)
            .concatenating(CGAffineTransform(translationX: g.dropCenter.x, y: g.dropCenter.y))
        let drop = teardrop().applying(transform)
        switch v {
        case .glass:
            out.append(LangShape(part: .drop, path: drop,
                                 fill: .linear(0x7DB3CB, LangPalette.waterHex,
                                               g.dropCenter.y - 100, g.dropCenter.y + 90)))
            let shine = Path(ellipseIn: CGRect(x: -36, y: 0, width: 16, height: 40)).applying(transform)
            out.append(LangShape(part: .drop, path: shine, fill: .solid(0xFFFFFF, 0.45)))
        case .flat:
            out.append(LangShape(part: .drop, path: drop, fill: .solid(LangPalette.waterHex, 1)))
        case .lines:
            out.append(LangShape(part: .drop, path: drop,
                                 stroke: LangStroke(color: LangPalette.waterHex, width: 14)))
        }

        // Trail: two small dots up-right of the drop, showing it is falling.
        if p.showTrail {
            let c = g.dropCenter
            let dots: [(CGPoint, CGFloat, Double)] = [
                (CGPoint(x: c.x + 100, y: c.y - 120), 17, 0.6),
                (CGPoint(x: c.x + 140, y: c.y - 158), 10, 0.4),
            ]
            for (pt, r, opacity) in dots {
                let dot = Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2))
                if v == .lines {
                    out.append(LangShape(part: .drop, path: dot,
                                         stroke: LangStroke(color: LangPalette.waterHex, opacity: opacity, width: 8)))
                } else {
                    out.append(LangShape(part: .drop, path: dot,
                                         fill: .solid(LangPalette.waterHex, opacity)))
                }
            }
        }
        return out
    }

    // MARK: Geometry helpers

    private struct Geometry {
        let cx: CGFloat = 512
        let yc: CGFloat = 590          // rim line of the bowl
        let rx: CGFloat                // outer bowl radius, horizontal
        let ry: CGFloat                // outer bowl radius, vertical
        let t: CGFloat                 // wall thickness
        let irx: CGFloat               // inner radius, horizontal
        let iry: CGFloat               // inner radius, vertical
        let layerH: CGFloat
        let gap: CGFloat = 14
        let wave: CGFloat
        let dropCenter: CGPoint

        init(_ p: LangMarkParams, boost: CGFloat) {
            let u = LangMarkScene.unit
            rx = u * CGFloat(p.bowlWidth) / 2
            ry = u * CGFloat(p.bowlDepth)
            t = u * CGFloat(p.wallThickness) * boost
            irx = rx - t
            iry = ry - t
            layerH = u * CGFloat(p.layerHeight) * boost
            wave = u * CGFloat(p.wobble)
            dropCenter = CGPoint(x: 512 + 108 + u * CGFloat(p.dropOffsetX),
                                 y: 590 - 200 + u * CGFloat(p.dropOffsetY))
        }
    }

    /// Lower half of an ellipse from (cx+rx, y) through the bottom to (cx-rx, y).
    /// Uses cubic curves (kappa ≈ 0.5523), so the path exports cleanly to SVG.
    static func appendLowerHalf(_ path: inout Path, cx: CGFloat, y: CGFloat,
                                rx: CGFloat, ry: CGFloat, closed: Bool) {
        let k: CGFloat = 0.5523
        path.move(to: CGPoint(x: cx + rx, y: y))
        path.addCurve(to: CGPoint(x: cx, y: y + ry),
                      control1: CGPoint(x: cx + rx, y: y + ry * k),
                      control2: CGPoint(x: cx + rx * k, y: y + ry))
        path.addCurve(to: CGPoint(x: cx - rx, y: y),
                      control1: CGPoint(x: cx - rx * k, y: y + ry),
                      control2: CGPoint(x: cx - rx, y: y + ry * k))
        if closed { path.closeSubpath() }
    }

    /// A horizontal bar with one gentle S-wave. Stroked with round caps.
    static func wavyBar(cx: CGFloat, y: CGFloat, halfWidth: CGFloat, amplitude: CGFloat) -> Path {
        let x0 = cx - halfWidth
        let x1 = cx + halfWidth
        let w = x1 - x0
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y))
        p.addCurve(to: CGPoint(x: x1, y: y),
                   control1: CGPoint(x: x0 + w / 3, y: y - amplitude),
                   control2: CGPoint(x: x0 + 2 * w / 3, y: y + amplitude))
        return p
    }

    /// Teardrop with its tip at (0, -92) and its round end centred at (0, 28). Height 184.
    static func teardrop() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -92))
        p.addCurve(to: CGPoint(x: 64, y: 28),
                   control1: CGPoint(x: 14, y: -56), control2: CGPoint(x: 64, y: -22))
        p.addCurve(to: CGPoint(x: 0, y: 92),
                   control1: CGPoint(x: 64, y: 63), control2: CGPoint(x: 35, y: 92))
        p.addCurve(to: CGPoint(x: -64, y: 28),
                   control1: CGPoint(x: -35, y: 92), control2: CGPoint(x: -64, y: 63))
        p.addCurve(to: CGPoint(x: 0, y: -92),
                   control1: CGPoint(x: -64, y: -22), control2: CGPoint(x: -14, y: -56))
        p.closeSubpath()
        return p
    }
}

// MARK: - SwiftUI view

/// Draws the mark. Use `parts` to draw only some groups (used for the layer export).
struct LangMark: View {
    var params = LangMarkParams()
    var parts: Set<LangPart> = Set(LangPart.allCases)

    var body: some View {
        Canvas { context, size in
            LangMarkRenderer.draw(into: context, size: size, params: params, parts: parts)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

enum LangMarkRenderer {
    static func draw(into base: GraphicsContext, size: CGSize,
                     params: LangMarkParams, parts: Set<LangPart>) {
        var ctx = base
        let scale = size.width / LangMarkScene.unit
        ctx.scaleBy(x: scale, y: scale)

        // At 40 pt and below: 2 layers and slightly heavier strokes, so the bars stay visible.
        let small = size.width <= 40
        let shapes = LangMarkScene.shapes(params,
                                          layers: small ? min(params.layerCount, 2) : params.layerCount,
                                          boost: small ? 1.35 : 1)
        for shape in shapes where parts.contains(shape.part) {
            paint(shape, into: &ctx)
        }
    }

    static func paint(_ shape: LangShape, into ctx: inout GraphicsContext) {
        var c = ctx
        if shape.blur > 0 { c.addFilter(.blur(radius: shape.blur)) }

        switch shape.fill {
        case .none:
            break
        case .solid(let hex, let opacity):
            c.fill(shape.path, with: .color(Color(langHex: hex, opacity: opacity)),
                   style: FillStyle(eoFill: shape.evenOdd))
        case .linear(let top, let bottom, let y0, let y1):
            c.fill(shape.path,
                   with: .linearGradient(Gradient(colors: [Color(langHex: top), Color(langHex: bottom)]),
                                         startPoint: CGPoint(x: 0, y: y0),
                                         endPoint: CGPoint(x: 0, y: y1)),
                   style: FillStyle(eoFill: shape.evenOdd))
        }

        if let stroke = shape.stroke {
            c.stroke(shape.path,
                     with: .color(Color(langHex: stroke.color, opacity: stroke.opacity)),
                     style: StrokeStyle(lineWidth: stroke.width,
                                        lineCap: stroke.round ? .round : .butt,
                                        lineJoin: .round))
        }
    }
}
