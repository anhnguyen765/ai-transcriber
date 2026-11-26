import SwiftUI
import AppKit

// "Mặt nước" (still water) design tokens.
// Every color, font, radius, shadow and animation used by the UI comes from here.
// Never hardcode these values in views.

// MARK: - Colors

extension ShapeStyle where Self == Color {
    /// Primary text.
    static var ink: Color { Theme.Palette.ink }
    /// Secondary text.
    static var ink2: Color { Theme.Palette.ink2 }
    /// Tertiary text and hints.
    static var ink3: Color { Theme.Palette.ink3 }
    /// Accent, and the "bạn" (me) speaker.
    static var water: Color { Theme.Palette.water }
    /// Primary buttons and selection.
    static var deep: Color { Theme.Palette.deep }
    /// Soft accent fill.
    static var foam: Color { Theme.Palette.foam }
    /// Sidebar and panel background.
    static var mist: Color { Theme.Palette.mist }
    /// Hairlines.
    static var line: Color { Theme.Palette.line }
    /// "Người khác" (others) fill and the "changes" callout.
    static var sand: Color { Theme.Palette.sand }
    /// "Người khác" (others) speaker color.
    static var sandInk: Color { Theme.Palette.sandInk }
    /// Recording only.
    static var rec: Color { Theme.Palette.rec }
    /// Done / healthy status.
    static var moss: Color { Theme.Palette.moss }
    /// The NotchIsland pill.
    static var notch: Color { Theme.Palette.notch }
}

enum Theme {
    enum Palette {
        // Light mode first. Dark values are added later by passing `dark:`.
        static let ink = Color(hex: 0x1D2A31)
        static let ink2 = Color(hex: 0x5E6F78)
        static let ink3 = Color(hex: 0x97A5AC)
        static let water = Color(hex: 0x4F8AA6)
        static let deep = Color(hex: 0x2C5A70)
        static let foam = Color(hex: 0xE4EEF2)
        static let mist = Color(hex: 0xF3F6F7)
        static let line = Color(hex: 0xDCE5E9)
        static let sand = Color(hex: 0xE9DCC9)
        static let sandInk = Color(hex: 0xA88A63)
        static let rec = Color(hex: 0xE2604E)
        static let moss = Color(hex: 0x5FB3A1)
        static let notch = Color(hex: 0x0E1214)
        /// Only used for shadows.
        static let shadow = Color(hex: 0x1C3340)
    }

    // MARK: Shape and spacing (8 pt grid)

    enum Radius {
        static let popover: CGFloat = 18
        static let quickAsk: CGFloat = 22
        static let window: CGFloat = 14
        static let card: CGFloat = 14
        static let notch: CGFloat = 14
        static let bubble: CGFloat = 14
        static let callout: CGFloat = 12
        static let input: CGFloat = 12
        static let button: CGFloat = 11
        static let segmented: CGFloat = 10
        static let row: CGFloat = 10
        static let chip: CGFloat = 8
        static let pill: CGFloat = 8
        static let search: CGFloat = 9
        static let checkbox: CGFloat = 5
        static let timestamp: CGFloat = 5
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    static let hairline: CGFloat = 1
    /// Width of text columns in the main window (Hỏi, Việc của tôi, meeting detail); centered when wider.
    static let readingWidth: CGFloat = 760

    // MARK: Shadows (soft only)

    struct Shadow {
        let opacity: Double
        let radius: CGFloat // SwiftUI radius ≈ half the Figma blur
        let y: CGFloat

        /// Cards and panels: y 18, blur 48, 14 %.
        static let soft = Shadow(opacity: 0.14, radius: 24, y: 18)
        /// Floating panels (Quick Ask): y 30, blur 80, 22 %.
        static let float = Shadow(opacity: 0.22, radius: 40, y: 30)
        /// Selected rows and segmented control thumb.
        static let tiny = Shadow(opacity: 0.08, radius: 2, y: 1)
    }

    // MARK: Motion

    enum Motion {
        /// Popover sections and page transitions (no bounce).
        static let standard = Animation.spring(duration: 0.25, bounce: 0)
        static let slow = Animation.spring(duration: 0.3, bounce: 0)
        /// Mic → stop square morph.
        static let morph = Animation.spring(duration: 0.25, bounce: 0)
        /// Idle ripple breathing.
        static let breathing = Animation.easeInOut(duration: 4).repeatForever(autoreverses: true)
        static let breathingScale: CGFloat = 1.03
        /// Recording rings never grow past this.
        static let maxRingScale: CGFloat = 1.08
        static let settleDuration: Double = 1.5
        /// Used instead of movement when Reduce Motion is on.
        static let fade = Animation.easeInOut(duration: 0.2)
    }
}

// MARK: - Materials

extension View {
    /// Popover / panel background: system material behind a white fill (74–80 %),
    /// with a 1 pt white 90 % border.
    func panelBackground(radius: CGFloat, fill: Double = 0.77) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(Color.white.opacity(fill))
            }
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.9), lineWidth: Theme.hairline))
        .clipShape(shape)
    }

    /// White card with a hairline border.
    func cardBackground(radius: CGFloat = Theme.Radius.card, fill: Double = 1) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(Color.white.opacity(fill)))
            .overlay(shape.strokeBorder(.line, lineWidth: Theme.hairline))
    }

    func themeShadow(_ shadow: Theme.Shadow) -> some View {
        self.shadow(color: Theme.Palette.shadow.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
