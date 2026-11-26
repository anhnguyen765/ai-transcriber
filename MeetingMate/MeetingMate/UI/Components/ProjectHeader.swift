import SwiftUI

/// Popover / sidebar header: water-drop tile, project name (click → project switcher),
/// subtitle, and a status dot.
struct ProjectHeader<SwitcherMenu: View>: View {
    let name: String
    let subtitle: String
    let status: ProjectStatus
    @ViewBuilder var switcherMenu: SwitcherMenu

    var body: some View {
        HStack(spacing: 10) {
            WaterDropTile(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Menu {
                    switcherMenu
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: name)
                            .typeStyle(.projectName)
                            .foregroundStyle(.ink)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.ink3)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Đổi dự án")

                Text(verbatim: subtitle)
                    .typeStyle(.caption)
                    .foregroundStyle(.ink2)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            StatusDot(status: status)
        }
    }
}

/// Rounded foam tile with a water-drop icon (lắng's mark).
struct WaterDropTile: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(.foam)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "drop.fill")
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.water)
            }
            .accessibilityHidden(true)
    }
}

#Preview("ProjectHeader") {
    VStack(spacing: 20) {
        ProjectHeader(name: SampleData.projectName, subtitle: SampleData.projectSubtitle, status: .indexed) {
            Button("2027") {}
            Divider()
            Button("Chọn thư mục dự án…") {}
        }
        ProjectHeader(name: SampleData.projectName, subtitle: "đang ghi vào .meetings", status: .recording) {
            EmptyView()
        }
        ProjectHeader(name: SampleData.projectName, subtitle: "Đang đọc dự án… 42/128", status: .indexing) {
            EmptyView()
        }
    }
    .padding(16)
    .frame(width: 320)
    .background(.white)
}
