#if DEBUG
import SwiftUI
import AppKit

enum LangExportError: LocalizedError {
    case render(String)

    var errorDescription: String? {
        switch self {
        case .render(let name): return "Không vẽ được \(name)"
        }
    }
}

/// Exports the mark for Xcode (AppIcon set) and for Icon Composer (layers).
@MainActor
enum LangExporter {
    /// macOS AppIcon slots: point size and scale. Pixel size = points × scale.
    static let appIconSlots: [(points: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ]

    /// Writes `AppIcon.appiconset` (PNGs + Contents.json) into `folder`.
    static func exportAppIcon(_ params: LangMarkParams, to folder: URL) throws {
        let set = folder.appending(path: "AppIcon.appiconset")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

        var images: [[String: Any]] = []
        for slot in appIconSlots {
            let pixels = slot.points * slot.scale
            let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
            guard let data = png(LangMark(params: params), px: pixels) else {
                throw LangExportError.render(name)
            }
            try data.write(to: set.appending(path: name))
            images.append([
                "size": "\(slot.points)x\(slot.points)",
                "idiom": "mac",
                "filename": name,
                "scale": "\(slot.scale)x",
            ])
        }

        let json: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: set.appending(path: "Contents.json"))
    }

    /// Writes one PNG (1024 px) and one SVG per part into `folder/LangLayers`.
    static func exportLayers(_ params: LangMarkParams, to folder: URL) throws {
        let dir = folder.appending(path: "LangLayers")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let all = LangMarkScene.shapes(params, layers: params.layerCount, boost: 1)
        for part in LangPart.allCases {
            let name = "layer_\(part.rawValue)"
            guard let data = png(LangMark(params: params, parts: [part]), px: 1024) else {
                throw LangExportError.render("\(name).png")
            }
            try data.write(to: dir.appending(path: "\(name).png"))
            let svg = svgDocument(all.filter { $0.part == part })
            try svg.write(to: dir.appending(path: "\(name).svg"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: PNG

    static func png<V: View>(_ view: V, px: Int) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(px), height: CGFloat(px)))
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    // MARK: SVG

    /// SVG uses flat colors: gradients are replaced by their top color, blur is dropped.
    static func svgDocument(_ shapes: [LangShape]) -> String {
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">\n"
        for shape in shapes {
            var attrs = "d=\"\(pathData(shape.path))\""
            switch shape.fill {
            case .none:
                attrs += " fill=\"none\""
            case .solid(let hex, let opacity):
                attrs += " fill=\"\(hexString(hex))\""
                if opacity < 1 { attrs += " fill-opacity=\"\(opacity)\"" }
            case .linear(let top, _, _, _):
                attrs += " fill=\"\(hexString(top))\""
            }
            if shape.evenOdd { attrs += " fill-rule=\"evenodd\"" }
            if let stroke = shape.stroke {
                attrs += " stroke=\"\(hexString(stroke.color))\""
                attrs += " stroke-width=\"\(stroke.width)\""
                if stroke.opacity < 1 { attrs += " stroke-opacity=\"\(stroke.opacity)\"" }
                attrs += stroke.round ? " stroke-linecap=\"round\" stroke-linejoin=\"round\"" : ""
            }
            out += "  <path \(attrs)/>\n"
        }
        return out + "</svg>\n"
    }

    static func hexString(_ hex: UInt32) -> String {
        String(format: "#%06X", hex)
    }

    static func pathData(_ path: Path) -> String {
        var d = ""
        func p(_ point: CGPoint) -> String { String(format: "%.2f %.2f", point.x, point.y) }
        path.cgPath.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: d += "M\(p(e.points[0])) "
            case .addLineToPoint: d += "L\(p(e.points[0])) "
            case .addQuadCurveToPoint: d += "Q\(p(e.points[0])) \(p(e.points[1])) "
            case .addCurveToPoint: d += "C\(p(e.points[0])) \(p(e.points[1])) \(p(e.points[2])) "
            case .closeSubpath: d += "Z "
            @unknown default: break
            }
        }
        return d.trimmingCharacters(in: .whitespaces)
    }
}
#endif
