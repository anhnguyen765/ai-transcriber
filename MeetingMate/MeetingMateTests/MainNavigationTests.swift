import Foundation
import Testing
@testable import MeetingMate

struct MainNavigationTests {
    private let calendar = Calendar(identifier: .gregorian)

    /// Thursday 26 Nov 2026, 15:00.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15))!
    }

    private func meeting(_ title: String, _ date: Date) -> MeetingInfo {
        MeetingInfo(folder: URL(fileURLWithPath: "/tmp/\(title)"), date: date, title: title, duration: 600,
                    status: .summarized, hasTranscript: true, hasSummary: true)
    }

    @Test func groupsTodayThisWeekEarlier() {
        let meetings = [
            meeting("Sáng nay", calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9))!),
            meeting("Thứ Hai", calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 10))!),
            meeting("Tuần trước", calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!),
        ]
        let sections = MeetingList.grouped(meetings, now: now, calendar: calendar)
        #expect(sections.map(\.group) == [.today, .thisWeek, .earlier])
        #expect(sections[2].meetings.map(\.title) == ["Tuần trước"])
    }

    @Test func emptyGroupsAreDropped() {
        let only = [meeting("Hôm nay", now)]
        #expect(MeetingList.grouped(only, now: now, calendar: calendar).map(\.group) == [.today])
    }

    @Test func filterIgnoresCaseAndAccents() {
        let meetings = [meeting("Sprint review", now), meeting("Họp khách hàng ABC", now), meeting("1:1 với Minh", now)]
        let title: (MeetingInfo) -> String = { $0.title }
        #expect(MeetingList.filter(meetings, query: "sprint", title: title).map(\.title) == ["Sprint review"])
        #expect(MeetingList.filter(meetings, query: "hop", title: title).map(\.title) == ["Họp khách hàng ABC"])
        #expect(MeetingList.filter(meetings, query: "  ", title: title).count == 3)
        #expect(MeetingList.filter(meetings, query: "không có", title: title).isEmpty)
    }

    @Test func sectionsHaveFixedOrderAndLabels() {
        #expect(MainSection.allCases.map(\.title) == ["Cuộc họp", "Hỏi", "Việc của tôi", "Dự án"])
        #expect(MeetingGroup.allCases.map(\.title) == ["hôm nay", "tuần này", "trước đó"])
    }
}
