import SwiftUI

/// Brand palette for the "lắng" mark. Hex values are kept as UInt32 so the same
/// numbers drive SwiftUI colors and the SVG export.
enum LangPalette {
    static let mistHex: UInt32 = 0xF3F6F7
    static let foamHex: UInt32 = 0xE4EEF2
    static let waterHex: UInt32 = 0x4F8AA6
    static let deepHex: UInt32 = 0x2C5A70
    static let sandHex: UInt32 = 0xE9DCC9
    static let sandInkHex: UInt32 = 0xA88A63
    /// Only for the recording state.
    static let recHex: UInt32 = 0xE2604E
}

extension Color {
    init(langHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
