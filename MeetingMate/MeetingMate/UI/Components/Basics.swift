import SwiftUI

/// Small lowercase section label: "gần đây", "quyết định", "việc cần làm", "liên quan".
struct SectionLabel: View {
    let text: LocalizedStringKey
    var color: Color = .ink3

    init(_ text: LocalizedStringKey, color: Color = .ink3) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .typeStyle(.sectionLabel)
            .foregroundStyle(color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Keyboard shortcut cap: "esc", "⌘K".
struct KeyCap: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .typeStyle(.monoTiny)
            .foregroundStyle(.ink2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.timestamp, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.timestamp, style: .continuous)
                .strokeBorder(.line, lineWidth: Theme.hairline))
    }
}

/// 1 pt hairline in the line color.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(.line).frame(height: Theme.hairline)
    }
}

/// 7 pt status dot: moss = indexed, rec = recording, pulsing water = indexing.
struct StatusDot: View {
    let status: ProjectStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var color: Color {
        switch status {
        case .indexed: .moss
        case .recording: .rec
        case .indexing: .water
        case .noDocuments: .ink3
        case .attention: .sandInk
        case .none: .ink3
        }
    }

    private var animates: Bool { status == .indexing || status == .recording }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(animates && pulse ? 0.35 : 1)
            .animation(animates ? .easeInOut(duration: reduceMotion ? 1.6 : 0.9).repeatForever(autoreverses: true)
                       : .default, value: pulse)
            .onAppear { pulse = animates }
            .onChange(of: animates) { _, now in pulse = now }
            .padding(6) // bigger hover target for the tooltip
            .contentShape(Rectangle())
            .help(status.tooltip)
            .accessibilityLabel(status.tooltip)
    }
}

// MARK: - Buttons

/// The few button looks used across lắng.
struct LangButtonStyle: ButtonStyle {
    enum Kind {
        /// Deep fill, white text ("Xem", send).
        case primary
        /// Recording red fill, white text ("Dừng & lưu").
        case record
        /// White 70 % + line border ("Tạm dừng").
        case secondary
        /// Foam 60 % pill (popover footer).
        case pill
    }

    var kind: Kind
    var radius: CGFloat = Theme.Radius.button
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .typeStyle(kind == .pill ? .ui(12) : .ui(13, .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .pill ? 10 : 14)
            .padding(.vertical, kind == .pill ? 5 : 8)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(shape.fill(background))
            .overlay {
                if kind == .secondary { shape.strokeBorder(.line, lineWidth: Theme.hairline) }
            }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .record: .white
        case .secondary: .ink
        case .pill: .deep
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .deep
        case .record: .rec
        case .secondary: .white.opacity(0.7)
        case .pill: Color.foam.opacity(0.6)
        }
    }
}

extension ButtonStyle where Self == LangButtonStyle {
    static func lang(_ kind: LangButtonStyle.Kind, radius: CGFloat = Theme.Radius.button,
                     fullWidth: Bool = false) -> LangButtonStyle {
        LangButtonStyle(kind: kind, radius: radius, fullWidth: fullWidth)
    }
}

/// Plain row that shows a foam background on hover.
struct HoverRowStyle: ButtonStyle {
    var radius: CGFloat = Theme.Radius.row

    func makeBody(configuration: Configuration) -> some View {
        HoverRow(radius: radius, pressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverRow<Content: View>: View {
        let radius: CGFloat
        let pressed: Bool
        @ViewBuilder let content: Content
        @State private var hovering = false

        var body: some View {
            content
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering || pressed ? Color.foam : .clear))
                .onHover { hovering = $0 }
                .animation(Theme.Motion.fade, value: hovering)
        }
    }
}

extension View {
    /// Disables the control and explains why on hover (disabled controls always explain why).
    func disabled(because reason: String?) -> some View {
        disabled(reason != nil)
            .help(reason ?? "")
    }
}

#Preview("Basics") {
    VStack(alignment: .leading, spacing: 14) {
        SectionLabel("gần đây")
        HStack { KeyCap("esc"); KeyCap("⌘K"); KeyCap("⌃⌥␣") }
        HStack(spacing: 12) {
            StatusDot(status: .indexed)
            StatusDot(status: .indexing)
            StatusDot(status: .recording)
        }
        Hairline()
        HStack {
            Button("Tạm dừng") {}.buttonStyle(.lang(.secondary, fullWidth: true))
            Button("Dừng & lưu") {}.buttonStyle(.lang(.record, fullWidth: true))
        }
        HStack {
            Button("Mở lắng ⌘O") {}.buttonStyle(.lang(.pill, radius: Theme.Radius.pill))
            Button("Xem") {}.buttonStyle(.lang(.primary, radius: Theme.Radius.pill))
            Button("Không bấm được") {}.buttonStyle(.lang(.primary)).disabled(because: "Lý do ở đây")
        }
    }
    .padding(20)
    .frame(width: 320)
    .background(.white)
}

// MARK: - Layout

extension View {
    /// A reading column: at most `maxWidth` wide and centered in the space it gets,
    /// so wide windows show equal margins instead of an empty right side.
    func readingColumn(maxWidth: CGFloat = Theme.readingWidth) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
