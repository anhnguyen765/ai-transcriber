import SwiftUI

/// Menu items to switch project: recent folders, then "Chọn thư mục dự án…".
/// Used by the popover header and the main window sidebar.
/// Reads AppState's copies (not ProjectStore) so the tick follows the header.
struct ProjectSwitcherItems: View {
    let app: AppState

    var body: some View {
        Group {
            ForEach(app.recentProjects, id: \.self) { folder in
                Toggle(folder.lastPathComponent, isOn: Binding(
                    get: { folder.standardizedFileURL == app.projectFolder?.standardizedFileURL },
                    set: { _ in app.projectStore.select(folder) }))
            }
            if !app.recentProjects.isEmpty { Divider() }
            Button("Chọn thư mục dự án…") { app.projectStore.chooseFolder() }
            if let reason = app.switchProjectDisabledReason {
                Text(verbatim: reason)
            }
        }
        .disabled(app.switchProjectDisabledReason != nil)
    }
}
