import Foundation
import Testing
@testable import MeetingMate

struct ProjectOverviewTests {
    /// A temp project with three meetings; the middle one has no summary.
    private func makeProject() throws -> (folder: URL, meetings: [MeetingInfo]) {
        let project = FileManager.default.temporaryDirectory.appending(path: "overview-\(UUID().uuidString)")
        let root = project.appending(path: ".meetings")
        var meetings: [MeetingInfo] = []
        let specs: [(String, Double, MeetingSummary?)] = [
            ("2026-11-20_10-00-00", 0, MeetingSummary(
                title: "Kickoff", overview: "Bắt đầu dự án.",
                actionItems: [ActionItem(task: "Viết charter", owner: "Lan", deadline: "1/12")])),
            ("2026-11-24_10-00-00", 4, nil),
            ("2026-11-26_10-00-00", 6, MeetingSummary(
                title: "Review", overview: "Xem lại tiến độ.",
                decisions: [SummaryItem(text: "Chốt dùng QR")],
                actionItems: [ActionItem(task: "Gửi báo giá"),
                              ActionItem(task: "Đã xong rồi"),
                              ActionItem(task: "Test iOS 18", owner: "Tùng", deadline: "28/11")])),
        ]
        for (name, day, summary) in specs {
            let folder = root.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if var summary {
                if summary.title == "Review" { summary.actionItems[1].done = true }
                try JSONEncoder().encode(summary).write(to: folder.appending(path: SummaryWriter.jsonFileName))
            }
            meetings.append(MeetingInfo(folder: folder, date: Date(timeIntervalSince1970: 1_800_000_000 + day * 86_400),
                                        title: summary?.title ?? name, duration: 60, status: nil,
                                        hasTranscript: true, hasSummary: summary != nil))
        }
        return (project, meetings)
    }

    @Test func recentMeetingsAreNewestFirstAndNeedASummary() throws {
        let (_, meetings) = try makeProject()
        let recent = ProjectOverviewBuilder.recentMeetings(meetings)
        #expect(recent.map(\.summary.title) == ["Review", "Kickoff"])
        #expect(ProjectOverviewBuilder.recentMeetings(meetings, limit: 1).count == 1)
    }

    @Test func openTasksSkipTickedItems() throws {
        let (_, meetings) = try makeProject()
        let tasks = ProjectOverviewBuilder.openTasks(in: ProjectOverviewBuilder.recentMeetings(meetings))
        #expect(tasks.map(\.item.task) == ["Gửi báo giá", "Test iOS 18", "Viết charter"])
        #expect(tasks.first?.index == 0 && tasks[1].index == 2)
    }

    @Test func fallbackPrioritiesPutDeadlinesFirst() throws {
        let (_, meetings) = try makeProject()
        let tasks = ProjectOverviewBuilder.openTasks(in: ProjectOverviewBuilder.recentMeetings(meetings))
        let priorities = ProjectOverviewBuilder.fallbackPriorities(from: tasks)
        #expect(priorities.map(\.title) == ["Test iOS 18", "Viết charter", "Gửi báo giá"])
        #expect(priorities[0].reason.contains("28/11"))
        #expect(priorities[0].meetingFolder == "2026-11-26_10-00-00")
    }

    @Test func replyIsCappedAndMeetingLabelsMapToFolders() throws {
        let (_, meetings) = try makeProject()
        let recent = ProjectOverviewBuilder.recentMeetings(meetings)
        let reply = ProjectOverviewBuilder.Reply(about: "  Dự án thanh toán QR.  ", priorities: [
            .init(title: "Gửi báo giá", reason: "Khách đang chờ.", meeting: "M1"),
            .init(title: "Viết charter", reason: "Cần chốt phạm vi.", meeting: "m2"),
            .init(title: "", reason: "rỗng", meeting: "M1"),
            .init(title: "Việc lạ", reason: "Không rõ nguồn.", meeting: "M9"),
            .init(title: "Thừa", reason: "Quá 3.", meeting: nil),
        ])
        let overview = ProjectOverviewBuilder.overview(from: reply, recent: recent)
        #expect(overview.about == "Dự án thanh toán QR.")
        #expect(overview.priorities.map(\.title) == ["Gửi báo giá", "Viết charter", "Việc lạ"])
        #expect(overview.priorities.map(\.meetingFolder) == ["2026-11-26_10-00-00", "2026-11-20_10-00-00", nil])
        #expect(overview.basedOnMeetings == ["2026-11-26_10-00-00", "2026-11-20_10-00-00"])
    }

    @Test func overviewIsStaleWhenANewerMeetingHasASummary() throws {
        let (_, meetings) = try makeProject()
        let recent = ProjectOverviewBuilder.recentMeetings(meetings)
        let old = ProjectOverview(about: "", priorities: [], generatedAt: Date(), basedOnMeetings: ["2026-11-20_10-00-00"])
        let current = ProjectOverview(about: "", priorities: [], generatedAt: Date(),
                                      basedOnMeetings: recent.map(\.folderName))
        #expect(ProjectOverviewBuilder.isStale(old, recent: recent))
        #expect(!ProjectOverviewBuilder.isStale(current, recent: recent))
        #expect(!ProjectOverviewBuilder.isStale(old, recent: []))
    }

    @Test func documentExcerptPutsIntroFilesFirstAndKeepsToTheBudget() {
        let chunks: [(path: String, type: SourceType, text: String)] = [
            ("docs/zeta.md", .doc, "Zeta notes"),
            ("README.md", .doc, "Dự án thanh toán QR cho cửa hàng."),
            ("README.md", .doc, "Second chunk is skipped"),
            ("src/main.swift", .code, "let x = 1"),
            (".meetings/2026/summary.md", .doc, "Meeting summary"),
            ("docs/alpha.md", .doc, String(repeating: "a", count: 5_000)),
        ]
        let text = ProjectOverviewBuilder.documentExcerpt(from: chunks, budget: 1_500)
        #expect(text.hasPrefix("### README.md\nDự án thanh toán QR"))
        #expect(!text.contains("Second chunk") && !text.contains("let x") && !text.contains("Meeting summary"))
        #expect(text.contains("### docs/alpha.md"))
        #expect(text.count <= 1_500)
    }

    @Test func savesAndLoadsOverviewJSON() throws {
        let (folder, _) = try makeProject()
        let overview = ProjectOverview(about: "Dự án X", priorities: [.init(title: "A", reason: "B", meetingFolder: nil)],
                                       generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                       basedOnMeetings: ["2026-11-26_10-00-00"])
        try ProjectOverviewBuilder.save(overview, projectFolder: folder)
        #expect(ProjectOverviewBuilder.load(projectFolder: folder) == overview)
        // overview.json has no meta.json, so the meeting library must not list it as a meeting.
        #expect(MeetingLibrary.load(projectFolder: folder).isEmpty)
    }

    @Test func promptListsMeetingsWithLabelsAndOnlyOpenTasks() throws {
        let (_, meetings) = try makeProject()
        let prompt = ProjectOverviewBuilder.prompt(projectName: "2027", documents: "", recent:
                                                    ProjectOverviewBuilder.recentMeetings(meetings),
                                                   language: .vietnamese)
        #expect(prompt.contains("## M1") && prompt.contains("Review") && prompt.contains("## M2"))
        #expect(prompt.contains("Gửi báo giá") && !prompt.contains("Đã xong rồi"))
        #expect(prompt.contains("Chốt dùng QR"))
        #expect(prompt.contains("tiếng Việt"))
    }
}
