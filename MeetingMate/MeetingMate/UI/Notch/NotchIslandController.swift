import AppKit
import Combine
import SwiftUI

/// Shows the NotchIsland (a borderless, non-activating panel) while recording,
/// and keeps it in place when screens change.
@MainActor
final class NotchIslandController {
    private let app: AppState
    private var panel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []

    init(app: AppState) {
        self.app = app
        app.recorder.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &subscriptions)
        // Toggle in Settings: re-check whenever any default changes.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &subscriptions)
        sync()
    }

    private var wanted: Bool { AppSettings.notchIsland && app.recorder.isRecording }

    private func sync() {
        if wanted {
            let panel = panel ?? makePanel()
            self.panel = panel
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchIslandView(recorder: app.recorder) {
            PopoverOpener.open()
        })
        return panel
    }

    /// The built-in display (the one with a notch), or the main screen.
    private func reposition() {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        else { return }
        let hasNotch = screen.safeAreaInsets.top > 0
        let menuBarHeight = hasNotch ? screen.safeAreaInsets.top : screen.frame.maxY - screen.visibleFrame.maxY
        var notch: (left: CGFloat, right: CGFloat)?
        if hasNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = (left: left.maxX, right: right.minX)
        }
        let frame = NotchGeometry.frame(screen: screen.frame, visible: screen.visibleFrame,
                                        menuBarHeight: menuBarHeight, notch: notch)
        panel.setFrame(frame, display: true)
    }
}

/// Opens the popover by clicking the menu bar icon, as the user would.
/// SwiftUI's MenuBarExtra has no public "open" call; this finds its status item button.
/// Relies on the status item living in an NSStatusBarWindow (checked on macOS 27 in tests).
@MainActor
enum PopoverOpener {
    static func open() {
        NSApp.activate()
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBar") {
            if let button = firstButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
        Log.info("Could not find the menu bar icon to open the popover")
    }

    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for sub in view.subviews {
            if let button = firstButton(in: sub) { return button }
        }
        return nil
    }
}
