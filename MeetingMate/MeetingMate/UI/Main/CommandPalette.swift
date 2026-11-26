import SwiftUI

/// ⌘K palette: type to jump to a section or a meeting. Enter runs the first match, Esc closes.
struct CommandPalette: View {
    @Bindable var app: AppState
    @State private var query = ""
    @FocusState private var focused: Bool

    enum Item: Identifiable, Equatable {
        case section(MainSection)
        case meeting(MeetingInfo)

        var id: String {
            switch self {
            case .section(let section): "section-\(section.rawValue)"
            case .meeting(let meeting): "meeting-\(meeting.id)"
            }
        }
    }

    private var items: [Item] {
        let sections = MainSection.allCases
            .filter { query.isEmpty || $0.title.localizedStandardContains(query) }
            .map(Item.section)
        let meetings = MeetingList.filter(app.meetings, query: query) { app.displayTitle($0) }
            .prefix(20)
            .map(Item.meeting)
        return sections + meetings
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.ink3)
                    TextField("Tìm cuộc họp hoặc mục…", text: $query)
                        .textFieldStyle(.plain)
                        .typeStyle(.body)
                        .focused($focused)
                        .onSubmit { if let first = items.first { run(first) } }
                    KeyCap("esc")
                }
                .padding(14)
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            Button { run(item) } label: { row(item) }
                                .buttonStyle(HoverRowStyle())
                        }
                        if items.isEmpty {
                            Text("Không có kết quả")
                                .typeStyle(.caption)
                                .foregroundStyle(.ink3)
                                .padding(14)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
                .strokeBorder(Color.white.opacity(0.9), lineWidth: Theme.hairline))
            .themeShadow(.float)
            .padding(.top, 120)
        }
        .onAppear { focused = true }
        .onExitCommand { close() }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        switch item {
        case .section(let section):
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .frame(width: 18)
                    .foregroundStyle(.ink2)
                Text(verbatim: section.title)
                    .typeStyle(.bodyMedium)
                    .foregroundStyle(.ink)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        case .meeting(let meeting):
            HStack(spacing: 10) {
                Circle().fill(.water).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: app.displayTitle(meeting))
                        .typeStyle(.bodyMedium)
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    Text(verbatim: "\(LangFormat.time(meeting.date)) · \(LangFormat.duration(meeting.duration))")
                        .typeStyle(.caption)
                        .foregroundStyle(.ink2)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func run(_ item: Item) {
        switch item {
        case .section(let section):
            app.section = section
        case .meeting(let meeting):
            app.section = .meetings
            app.selectedMeeting = meeting.folder
        }
        close()
    }

    private func close() {
        app.paletteOpen = false
    }
}
