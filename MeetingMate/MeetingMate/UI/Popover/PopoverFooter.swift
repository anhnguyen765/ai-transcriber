import SwiftUI

/// Hairline, then "Mở lắng ⌘O" and "Hỏi ⌃⌥␣" pills, and a settings menu.
struct PopoverFooter: View {
    let app: AppState
    let close: () -> Void
    @Environment(\.openSettings) private var openSettings

    private var noProject: Bool { app.projectStore.folderURL == nil }

    var body: some View {
        VStack(spacing: 10) {
            Hairline()
            HStack(spacing: 6) {
                Button {
                    app.router.openMain()
                    close()
                } label: {
                    Text("Mở lắng ") + Text(verbatim: "⌘O").foregroundStyle(.ink3)
                }
                .buttonStyle(.lang(.pill, radius: Theme.Radius.pill))
                .keyboardShortcut("o", modifiers: .command)
                .disabled(because: noProject ? String(localized: "Chọn thư mục dự án trước.") : nil)

                Button {
                    app.router.openAsk()
                    close()
                } label: {
                    Text("Hỏi ") + Text(verbatim: "⌃⌥␣").foregroundStyle(.ink3)
                }
                .buttonStyle(.lang(.pill, radius: Theme.Radius.pill))
                .disabled(because: noProject ? String(localized: "Chọn thư mục dự án trước.") : nil)

                Spacer()
                settingsMenu
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Cài đặt…") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Menu("Công cụ") { toolItems }
            Divider()
            Button("Thoát lắng") {
                // AppDelegate stops & saves any running recording before the app exits.
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.ink2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Cài đặt và công cụ")
    }

    /// The old flat menu's extra actions, until each one has its new home (main window, Project screen).
    @ViewBuilder private var toolItems: some View {
        let folder = app.projectStore.folderURL
        Button("Mở thư mục ghi âm") { openRecordingsFolder() }
            .disabled(folder == nil)
        Divider()
        Button("Chép lời lại cuộc họp gần nhất") {
            app.transcription.retranscribeLastMeeting(projectFolder: folder)
        }
        .disabled(folder == nil)
        Button("Tóm tắt lại cuộc họp gần nhất") {
            app.summary.summarizeLastMeeting(projectFolder: folder)
        }
        .disabled(folder == nil)
        Button("Mở bản tóm tắt gần nhất") {
            app.summary.openLastSummary(projectFolder: folder)
        }
        .disabled(folder == nil)
        Divider()
        Button("Đọc lại dự án") { app.indexer.reindex() }
            .disabled(folder == nil || app.indexer.isWorking)
        Button("Xem file đã đọc") {
            app.section = .project
            app.router.openMain()
            close()
        }
        .disabled(folder == nil)
        Button("Gợi ý thuật ngữ từ dự án") {
            app.glossary.suggest(store: app.indexer.store, projectFolder: app.indexer.projectFolder)
            app.section = .project
            app.router.openMain()
            close()
        }
        .disabled(app.indexer.store == nil || app.glossary.isWorking)
    }

    private func openRecordingsFolder() {
        if let last = app.recorder.lastSessionURL, FileManager.default.fileExists(atPath: last.path) {
            NSWorkspace.shared.activateFileViewerSelecting([last])
            return
        }
        guard let meetings = app.projectStore.meetingsFolderURL else { return }
        do {
            try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
            NSWorkspace.shared.open(meetings)
        } catch {
            app.recorder.errorMessage = String(localized: "Không mở được .meetings: \(error.localizedDescription)")
        }
    }
}
