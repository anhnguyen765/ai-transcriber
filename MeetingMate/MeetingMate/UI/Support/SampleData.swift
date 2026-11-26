import Foundation

/// Preview-only data that matches the Figma mockup. Never used for real screens.
enum SampleData {
    static let projectName = "2027"
    static let projectSubtitle = "128 tài liệu · 14 cuộc họp"

    struct Meeting: Identifiable {
        let id = UUID()
        let title: String
        let start: Date
        let duration: Double
    }

    static let recentMeetings: [Meeting] = {
        let now = Date()
        let calendar = Calendar.current
        func daysAgo(_ days: Int, hour: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        return [
            Meeting(title: "Sprint review · tuần 48", start: now.addingTimeInterval(-2 * 3600), duration: 48 * 60 + 10),
            Meeting(title: "1:1 với Minh", start: daysAgo(1, hour: 15), duration: 32 * 60),
            Meeting(title: "Họp khách hàng ABC", start: daysAgo(3, hour: 9), duration: 55 * 60 + 20),
        ]
    }()

    static let meetingTitle = "Sprint review · tuần 48"

    static let overview = """
        Nhóm chốt phạm vi bản phát hành 2027.1: giữ tính năng tìm kiếm hợp nhất, dời phần đồng bộ lịch \
        sang sprint sau. Minh lo ngại về thời gian kiểm thử trên máy cũ; cả nhóm đồng ý thêm một vòng \
        beta nội bộ trước khi gửi khách hàng ABC.
        """

    static let change = "Ngày phát hành dời từ 05/12 sang 12/12"
    static let changeSource = "Kế hoạch Q4.md"

    static let decisions: [(text: String, time: Double)] = [
        ("Giữ tìm kiếm hợp nhất trong bản 2027.1", 12 * 60 + 4),
        ("Dời đồng bộ lịch sang sprint 49", 23 * 60 + 41),
        ("Thêm một vòng beta nội bộ 3 ngày", 31 * 60 + 40),
    ]

    static let actionItems: [(text: String, owner: String, isMe: Bool, done: Bool, time: Double)] = [
        ("Viết kịch bản kiểm thử cho máy Intel", "bạn · 02/12", true, false, 18 * 60 + 22),
        ("Gửi lịch beta cho khách hàng ABC", "Minh · 03/12", false, false, 33 * 60 + 5),
        ("Cập nhật tài liệu phát hành", "Lan · 05/12", false, true, 41 * 60 + 12),
    ]

    static let related: [(label: String, icon: String, title: String)] = [
        ("S1", "doc.text", "Kế hoạch Q4.md"),
        ("S2", "waveform", "1:1 với Minh"),
        ("S3", "doc.text", "Ghi chú phát hành 2027.1"),
    ]

    static let quote = (speaker: "Minh", time: 31 * 60 + 40.0,
                        text: "Mình nghĩ nên có thêm một vòng beta nội bộ, máy cũ vẫn chậm lắm.")

    static let meShare = 0.34
}
