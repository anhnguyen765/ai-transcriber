import SwiftUI

/// Menu items to switch project: recent folders, then "Chọn thư mục dự án…".
/// Used by the popover header and the main window sidebar.
struct ProjectSwitcherItems: View {
    let app: AppState

    var body: some View {
        let store = app.projectStore
        Group {
            ForEach(store.recentFolders, id: \.self) { folder in
                Toggle(folder.lastPathComponent, isOn: Binding(
                    get: { folder.standardizedFileURL == store.folderURL?.standardizedFileURL },
                    set: { _ in store.select(folder) }))
            }
            if !store.recentFolders.isEmpty { Divider() }
            Button("Chọn thư mục dự án…") { store.chooseFolder() }
            if let reason = app.switchProjectDisabledReason {
                Text(verbatim: reason)
            }
        }
        .disabled(app.switchProjectDisabledReason != nil)
    }
}
