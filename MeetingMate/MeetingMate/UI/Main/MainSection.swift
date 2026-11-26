import Foundation

/// Sidebar sections of the main window.
enum MainSection: String, CaseIterable, Identifiable {
    case meetings, ask, tasks, project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetings: "Cuộc họp"
        case .ask: "Hỏi"
        case .tasks: "Việc của tôi"
        case .project: "Dự án"
        }
    }

    var icon: String {
        switch self {
        case .meetings: "waveform"
        case .ask: "bubble.left.and.text.bubble.right"
        case .tasks: "checklist"
        case .project: "folder"
        }
    }
}

/// "hôm nay" / "tuần này" / "trước đó".
enum MeetingGroup: String, CaseIterable, Identifiable {
    case today, thisWeek, earlier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "hôm nay"
        case .thisWeek: "tuần này"
        case .earlier: "trước đó"
        }
    }

    static func of(_ date: Date, now: Date, calendar: Calendar) -> MeetingGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        return .earlier
    }
}

struct MeetingSection: Identifiable, Equatable {
    let group: MeetingGroup
    let meetings: [MeetingInfo]
    var id: MeetingGroup { group }
}

/// Pure list logic for the sidebar (no UI), so it is unit tested.
enum MeetingList {
    /// Meetings whose title contains `query` (case and accent insensitive). Empty query = all.
    static func filter(_ meetings: [MeetingInfo], query: String, title: (MeetingInfo) -> String) -> [MeetingInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return meetings }
        return meetings.filter { title($0).localizedStandardContains(trimmed) }
    }

    /// Keeps the order of `meetings` (newest first) inside each group; empty groups are dropped.
    static func grouped(_ meetings: [MeetingInfo], now: Date = Date(), calendar: Calendar = .current) -> [MeetingSection] {
        MeetingGroup.allCases.compactMap { group in
            let items = meetings.filter { MeetingGroup.of($0.date, now: now, calendar: calendar) == group }
            return items.isEmpty ? nil : MeetingSection(group: group, meetings: items)
        }
    }

    /// Names that mean "me" in an owner field: the Settings name, "bạn" and "tôi" (lowercased).
    static func myNames() -> Set<String> {
        Set([AppSettings.myName, "bạn", "tôi"].map { normalizeOwner($0) })
    }

    /// Action items in a meeting's summary.json: all of them, and those whose owner is me.
    static func myActionItems(in folder: URL, names: Set<String>) -> (all: Int, mine: Int) {
        guard let data = try? Data(contentsOf: folder.appending(path: SummaryWriter.jsonFileName)),
              let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) else { return (0, 0) }
        let mine = summary.actionItems.filter { names.contains(normalizeOwner($0.owner)) && $0.done != true }.count
        return (summary.actionItems.count, mine)
    }

    /// One of my action items that is not checked yet, with where it lives.
    struct OpenTask: Identifiable {
        let folder: URL
        let meetingTitle: String
        let index: Int
        let item: ActionItem
        var id: String { "\(folder.path)#\(index)" }
    }

    /// My unchecked action items across the given meetings (meeting order kept).
    static func myOpenTasks(in meetings: [MeetingInfo], title: (MeetingInfo) -> String) -> [OpenTask] {
        let names = myNames()
        return meetings.flatMap { meeting -> [OpenTask] in
            guard let data = try? Data(contentsOf: meeting.folder.appending(path: SummaryWriter.jsonFileName)),
                  let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) else { return [] }
            return summary.actionItems.enumerated().compactMap { index, item in
                guard names.contains(normalizeOwner(item.owner)), item.done != true else { return nil }
                return OpenTask(folder: meeting.folder, meetingTitle: title(meeting), index: index, item: item)
            }
        }
    }

    /// Checks or unchecks one action item and saves summary.json (and summary.md).
    static func setActionItemDone(folder: URL, index: Int, done: Bool) {
        guard let meta = try? MeetingMeta.load(from: folder),
              let data = try? Data(contentsOf: folder.appending(path: SummaryWriter.jsonFileName)),
              var summary = try? JSONDecoder().decode(MeetingSummary.self, from: data),
              summary.actionItems.indices.contains(index) else { return }
        summary.actionItems[index].done = done
        _ = try? SummaryWriter.write(summary, meetingStart: meta.startTime, duration: meta.durationSeconds,
                                     projectName: URL(fileURLWithPath: meta.projectPath).lastPathComponent,
                                     language: AppSettings.summaryLanguage, to: folder)
    }

    static func normalizeOwner(_ owner: String) -> String {
        owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
