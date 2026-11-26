import SwiftUI

/// The main window: sidebar (project, search, sections, meetings) and detail.
/// Opened from "Mở lắng ⌘O" and the popover's meeting rows. Minimum 1080×700.
struct MainWindow: View {
    @Bindable var app: AppState

    var body: some View {
        ZStack {
            NavigationSplitView {
                MainSidebar(app: app)
                    .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 250)
            } detail: {
                MainDetail(app: app)
            }
            if app.paletteOpen {
                CommandPalette(app: app)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.fade, value: app.paletteOpen)
        .frame(minWidth: 1080, minHeight: 700)
        .preferredColorScheme(.light)
    }
}

struct MainSidebar: View {
    @Bindable var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProjectHeader(name: app.projectName, subtitle: app.projectSubtitle, status: app.projectStatus) {
                ProjectSwitcherItems(app: app)
            }
            .padding(.top, 6)

            searchField

            VStack(spacing: 2) {
                ForEach(MainSection.allCases) { section in
                    SidebarNavRow(title: section.title, icon: section.icon,
                                  selected: app.section == section,
                                  badge: section == .tasks ? app.openTaskCount : 0) {
                        app.section = section
                    }
                }
            }

            if app.section == .meetings {
                ScrollView { meetingGroups.padding(.bottom, 12) }
                    .scrollIndicators(.never)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.mist.opacity(0.9))
    }

    /// Looks like a search field; a click (or ⌘K) opens the command palette, where you type.
    private var searchField: some View {
        Button { app.paletteOpen = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.ink3)
                Text("Tìm mọi thứ…")
                    .typeStyle(.small)
                    .foregroundStyle(.ink3)
                Spacer(minLength: 4)
                KeyCap("⌘K")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.search, style: .continuous)
                .fill(Color.white.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.search, style: .continuous)
                .strokeBorder(.line, lineWidth: Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tìm mọi thứ, phím tắt ⌘K")
        .background {
            Button("") { app.paletteOpen = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder private var meetingGroups: some View {
        let sections = MeetingList.grouped(app.meetings)
        VStack(alignment: .leading, spacing: 12) {
            if sections.isEmpty {
                Text("Chưa có cuộc họp nào.")
                    .typeStyle(.caption)
                    .foregroundStyle(.ink3)
                    .padding(.horizontal, 10)
            }
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(LocalizedStringKey(section.group.title))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                    ForEach(section.meetings) { meeting in
                        MeetingSidebarRow(app: app, meeting: meeting)
                    }
                }
            }
        }
    }
}

/// Sections: foam when selected, deep text. Tasks show a rec badge.
struct SidebarNavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(verbatim: title)
                    .typeStyle(.ui(13, .medium))
                Spacer(minLength: 4)
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .typeStyle(.ui(11, .medium))
                        .foregroundStyle(.rec)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.rec.opacity(0.12)))
                }
            }
            .foregroundStyle(selected ? Color.deep : .ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(selected ? Color.foam : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Meeting row in the sidebar: title 12.5 Medium, "10:00 · 48 phút" 11 ink2.
/// Selected = white card with a tiny shadow.
struct MeetingSidebarRow: View {
    let app: AppState
    let meeting: MeetingInfo

    private var selected: Bool { app.selectedMeeting == meeting.folder }

    var body: some View {
        Button {
            app.selectedMeeting = meeting.folder
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: app.displayTitle(meeting))
                    .typeStyle(.ui(12.5, .medium))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text(verbatim: "\(LangFormat.time(meeting.date)) · \(LangFormat.duration(meeting.duration))")
                    .typeStyle(.caption)
                    .foregroundStyle(.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(selected ? Color.white : Color.clear)
                .shadow(color: Theme.Palette.shadow.opacity(selected ? Theme.Shadow.tiny.opacity : 0),
                        radius: Theme.Shadow.tiny.radius, y: Theme.Shadow.tiny.y))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Right side. Meeting detail arrives in step (f); the other sections in (h)–(i).
struct MainDetail: View {
    @Bindable var app: AppState

    var body: some View {
        Group {
            switch app.section {
            case .meetings:
                meetingDetail
            case .ask:
                AskSection(app: app)
            case .tasks:
                TasksSection(app: app)
            case .project:
                ProjectSection(app: app)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    @ViewBuilder private var meetingDetail: some View {
        if let folder = app.selectedMeeting, app.meetings.contains(where: { $0.folder == folder }) {
            MeetingDetailView(app: app, folder: folder)
                .id(folder)
        } else {
            DetailPlaceholder(title: "Cuộc họp", text: "Chọn một cuộc họp ở bên trái.")
        }
    }
}

struct DetailPlaceholder: View {
    let title: String
    let text: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            Text(verbatim: title)
                .typeStyle(.meetingTitle)
                .foregroundStyle(.ink)
                .multilineTextAlignment(.center)
            Text(verbatim: text)
                .typeStyle(.body)
                .foregroundStyle(.ink2)
                .multilineTextAlignment(.center)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.lang(.secondary))
                    .padding(.top, 6)
            }
        }
        .padding(40)
    }
}

