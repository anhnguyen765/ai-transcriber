import SwiftUI
import AppKit
import CoreText

/// Loads the bundled fonts (Newsreader, Geist Mono — both SIL OFL, licenses next to the files)
/// for this process only. Runs once, the first time any themed font is used,
/// so it also works in Xcode previews.
enum FontRegistry {
    static let postScriptNames = [
        "Newsreader16pt-Regular", "Newsreader16pt-Italic", "Newsreader16pt-Medium",
        "Newsreader72pt-Regular", "GeistMono-Regular", "GeistMono-Medium",
    ]

    /// Touch this to make sure the fonts are registered.
    static let isRegistered: Bool = {
        let bundle = Bundle.main
        let urls = (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // "Already registered" is fine; anything else falls back to system fonts.
                if let error = error?.takeRetainedValue() {
                    Log.info("Font \(url.lastPathComponent) not registered: \(error.localizedDescription)")
                }
            }
        }
        return !urls.isEmpty
    }()

    /// Prints which font really loads, so a missing bundle shows up in the console.
    static func logResolvedNames() {
        _ = isRegistered
        for name in ["Newsreader16pt-Regular", "Newsreader72pt-Regular", "GeistMono-Regular"] {
            let resolved = NSFont(name: name, size: 12)?.fontName ?? "NOT FOUND (system fallback)"
            print("[lắng] Font \(name) → \(resolved)")
        }
    }

    static func nsFont(_ name: String, size: CGFloat) -> NSFont? {
        _ = isRegistered
        return NSFont(name: name, size: size)
    }
}

/// One text style from the design: font + line height + letter spacing.
struct TypeStyle {
    enum Family {
        case ui(Font.Weight)
        /// Newsreader. `display` uses the 72 pt optical cut (big titles).
        case serif(italic: Bool, medium: Bool = false, display: Bool = false)
        case mono(medium: Bool)
    }

    var family: Family
    var size: CGFloat
    var lineHeight: CGFloat?
    /// Points (Figma "2 %" at 11 pt = 0.22).
    var tracking: CGFloat = 0

    // MARK: UI (SF Pro)
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular, lineHeight: CGFloat? = nil) -> TypeStyle {
        TypeStyle(family: .ui(weight), size: size, lineHeight: lineHeight)
    }
    static let caption = ui(11)
    static let small = ui(12)
    static let body = ui(13)
    static let bodyMedium = ui(13, .medium)
    static let large = ui(14)
    static let projectName = ui(13, .semibold)
    /// Ask answers in the inspector: 13/20.
    static let answer = ui(13, lineHeight: 20)
    /// "gần đây", "quyết định"… (lowercase, ink3).
    static let sectionLabel = TypeStyle(family: .ui(.medium), size: 11, tracking: 11 * 0.02)

    // MARK: Serif (Newsreader)
    static let meetingTitle = TypeStyle(family: .serif(italic: false, display: true), size: 36, lineHeight: 42)
    static let summary = TypeStyle(family: .serif(italic: false), size: 17, lineHeight: 27)
    static let quickAnswer = TypeStyle(family: .serif(italic: false), size: 18, lineHeight: 28)
    static let quote = TypeStyle(family: .serif(italic: true), size: 15, lineHeight: 22)
    static let recordCaption = TypeStyle(family: .serif(italic: false), size: 24)
    static let settlingCaption = TypeStyle(family: .serif(italic: true), size: 20)

    // MARK: Mono (Geist Mono)
    static func mono(_ size: CGFloat, medium: Bool = false) -> TypeStyle {
        TypeStyle(family: .mono(medium: medium), size: size)
    }
    static let timer = mono(30, medium: true)
    static let monoSmall = mono(11)
    static let monoTiny = mono(10.5)
    static let monoBody = mono(12)

    // MARK: Resolving

    private var postScriptName: String? {
        switch family {
        case .ui: nil
        case .serif(let italic, let medium, let display):
            display ? "Newsreader72pt-Regular"
                : italic ? "Newsreader16pt-Italic"
                : medium ? "Newsreader16pt-Medium" : "Newsreader16pt-Regular"
        case .mono(let medium): medium ? "GeistMono-Medium" : "GeistMono-Regular"
        }
    }

    var nsFont: NSFont {
        if let name = postScriptName, let font = FontRegistry.nsFont(name, size: size) { return font }
        switch family {
        case .ui(let weight):
            return .systemFont(ofSize: size, weight: weight.nsWeight)
        case .serif(let italic, _, _):
            let base = NSFont.systemFont(ofSize: size)
            var descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            if italic { descriptor = descriptor.withSymbolicTraits(.italic) }
            return NSFont(descriptor: descriptor, size: size) ?? base
        case .mono(let medium):
            return .monospacedSystemFont(ofSize: size, weight: medium ? .medium : .regular)
        }
    }

    var font: Font {
        if case .ui(let weight) = family { return .system(size: size, weight: weight) }
        return Font(nsFont)
    }

    /// Extra space between lines so the line height matches the design.
    var lineSpacing: CGFloat {
        guard let lineHeight else { return 0 }
        let font = nsFont
        let natural = font.ascender - font.descender + font.leading
        return max(0, lineHeight - natural)
    }
}

extension View {
    /// Applies a design text style (font, line height, letter spacing).
    func typeStyle(_ style: TypeStyle) -> some View {
        font(style.font)
            .lineSpacing(style.lineSpacing)
            .tracking(style.tracking)
    }
}

private extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
