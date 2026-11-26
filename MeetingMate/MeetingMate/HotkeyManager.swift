import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// ⌃⌥R: start/stop recording from any app.
    static let toggleRecording = Self("toggleRecording", initial: .init(.r, modifiers: [.control, .option]))
    /// ⌃⌥Space: open the Ask window from any app.
    static let openAsk = Self("openAsk", initial: .init(.space, modifiers: [.control, .option]))
}

/// Global hotkeys (KeyboardShortcuts package). They can be changed in Settings → Shortcuts.
@MainActor
enum HotkeyManager {
    static func install(toggleRecording: @escaping @MainActor () -> Void,
                        openAsk: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) {
            MainActor.assumeIsolated { toggleRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .openAsk) {
            MainActor.assumeIsolated { openAsk() }
        }
    }
}

/// Settings section to change the shortcuts.
struct ShortcutSettings: View {
    var body: some View {
        KeyboardShortcuts.Recorder("Ghi / dừng ghi:", name: .toggleRecording)
        KeyboardShortcuts.Recorder("Mở Hỏi lắng:", name: .openAsk)
        Text("If a shortcut does nothing, another app or macOS uses it (⌃⌥Space also switches input sources, e.g. Vietnamese Telex). Pick another one here.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
