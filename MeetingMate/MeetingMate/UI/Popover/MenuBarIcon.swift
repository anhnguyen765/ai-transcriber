import SwiftUI
import AppKit

/// Menu bar icon, driven by PipelineStatus:
/// idle = water drop · recording = pulsing red dot · processing = drop filling up · done = brief check.
struct MenuBarIcon: View {
    let app: AppState
    /// Hands SwiftUI's openWindow to the AppDelegate, so hotkeys and the Router can open windows.
    let provideOpenWindow: (OpenWindowAction) -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = 0

    private static let fillFrames = ["drop", "drop.halffull", "drop.fill"]

    var body: some View {
        icon
            .onAppear { provideOpenWindow(openWindow) } // the icon exists from launch on
            .task(id: app.menuBarMode) {
                frame = 0
                guard !reduceMotion, app.menuBarMode == .recording || app.menuBarMode == .processing else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(app.menuBarMode == .recording ? 700 : 450))
                    frame &+= 1
                }
            }
    }

    @ViewBuilder private var icon: some View {
        switch app.menuBarMode {
        case .idle:
            Image(systemName: "drop")
                .accessibilityLabel("lắng")
        case .recording:
            // A red stop button while recording: clicking the icon opens the popover with "Dừng & lưu".
            Image(nsImage: frame % 2 == 0 ? Self.stopImage : Self.stopDimImage)
                .help("Đang ghi âm. Bấm để dừng.")
                .accessibilityLabel("lắng đang ghi âm, bấm để dừng")
        case .processing:
            Image(systemName: reduceMotion ? "drop.halffull" : Self.fillFrames[frame % Self.fillFrames.count])
                .accessibilityLabel("lắng đang xử lý")
        case .justDone:
            Image(nsImage: Self.doneImage)
                .accessibilityLabel("lắng đã xong")
        }
    }

    /// Menu bar icons are drawn as black/white templates. Colored icons need a non-template NSImage.
    private static func colored(_ symbol: String, _ color: NSColor, alpha: CGFloat = 1) -> NSImage {
        let config = NSImage.SymbolConfiguration(hierarchicalColor: color.withAlphaComponent(alpha))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }

    private static let stopImage = colored("stop.circle.fill", NSColor(Theme.Palette.rec))
    private static let stopDimImage = colored("stop.circle.fill", NSColor(Theme.Palette.rec), alpha: 0.45)
    private static let doneImage = colored("checkmark.circle.fill", NSColor(Theme.Palette.moss))
}
