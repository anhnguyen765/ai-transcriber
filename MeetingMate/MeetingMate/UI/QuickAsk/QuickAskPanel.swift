import AppKit
import Combine
import SwiftUI

/// A floating panel that takes keyboard focus without activating the app.
final class QuickAskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension Notification.Name {
    /// Posted each time Quick Ask is shown, so the query field takes focus again.
    static let quickAskShown = Notification.Name("lang.quickAskShown")
}

/// ⌃⌥Space: the Quick Ask panel, centered a little above the middle of the screen.
/// Esc closes it, and so does clicking anywhere else.
@MainActor
final class QuickAskController {
    static let width: CGFloat = 660

    private let app: AppState
    private var panel: QuickAskPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var resignObserver: NSObjectProtocol?
    private var escMonitor: Any?

    init(app: AppState) {
        self.app = app
        // Grow or shrink as the answer streams in; keep the top edge where it is.
        app.ask.$turns
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resizeToFit() }
            .store(in: &subscriptions)
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        // Each time Quick Ask comes up, start a new chat (previous answers are kept in Hỏi).
        app.ask.newChat()
        let panel = panel ?? makePanel()
        self.panel = panel
        resizeToFit(keepingCenter: true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickAskShown, object: nil)
        installEscMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        removeEscMonitor()
    }

    /// Esc closes the panel whichever control has focus (the query box may not, after reopening).
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.panel else { return event }
            self.hide()
            return nil
        }
    }

    private func removeEscMonitor() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        escMonitor = nil
    }

    private func makePanel() -> QuickAskPanel {
        let panel = QuickAskPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                                  styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuickAskView(app: app) { [weak self] in
            self?.hide()
        })
        // Clicking elsewhere closes it.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        return panel
    }

    /// Fits the panel to its content. The top edge stays put; on first show the panel is centered.
    private func resizeToFit(keepingCenter: Bool = false) {
        guard let panel, panel.isVisible || keepingCenter, let content = panel.contentView else { return }
        let fitted = content.fittingSize
        let size = NSSize(width: Self.width, height: max(fitted.height, 80))
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = panel.frame
        if keepingCenter || !panel.isVisible {
            // Centered horizontally, a little above the middle vertically.
            frame.origin.x = visible.midX - size.width / 2
            frame.origin.y = visible.midY + visible.height * 0.12 - size.height / 2
        } else {
            frame.origin.y = frame.maxY - size.height
        }
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }
}
