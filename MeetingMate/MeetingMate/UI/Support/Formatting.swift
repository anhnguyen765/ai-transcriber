import Foundation

/// Vietnamese, human-friendly formatting for the UI.
/// Never show raw folder timestamps: use these instead.
enum LangFormat {
    private static let vi = Locale(identifier: "vi_VN")

    /// Seconds → "31:40" or "1:02:05" (mono timestamps and timers).
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// "31:40" / "1:02:05" / "[31:40]" → seconds.
    static func seconds(fromClock text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = cleaned.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// Seconds → "48 phút", "1 giờ 05 phút", "40 giây".
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 { return "\(Int(seconds)) giây" }
        if minutes < 60 { return "\(minutes) phút" }
        return String(format: "%d giờ %02d phút", minutes / 60, minutes % 60)
    }

    /// Short duration for mono columns: "48:10".
    static func shortDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? clock(seconds) : String(format: "%d:%02d", minutes, Int(seconds) % 60)
    }

    /// "vừa xong", "12 phút trước", "2 giờ trước", "hôm qua", "thứ Hai", "26 thg 11".
    static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "vừa xong" }
        if seconds < 3600 { return "\(Int(seconds / 60)) phút trước" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) giờ trước" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "hôm qua" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 99
        if days < 7 { return weekday(date, calendar: calendar) }
        return dayMonth(date)
    }

    /// "thứ Hai" … "Chủ nhật".
    static func weekday(_ date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.weekday, from: date) {
        case 1: "Chủ nhật"
        case 2: "thứ Hai"
        case 3: "thứ Ba"
        case 4: "thứ Tư"
        case 5: "thứ Năm"
        case 6: "thứ Sáu"
        default: "thứ Bảy"
        }
    }

    /// "26 thg 11".
    static func dayMonth(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month], from: date)
        return "\(c.day ?? 0) thg \(c.month ?? 0)"
    }

    /// "26/11".
    static func shortDate(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month], from: date)
        return String(format: "%02d/%02d", c.day ?? 0, c.month ?? 0)
    }

    /// "10:00".
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = vi
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// "Thứ Năm, 26 thg 11 · 10:00 · 48 phút · 4 người".
    static func meetingMeta(start: Date, length: Double, people: Int?) -> String {
        let day = weekday(start)
        var parts = ["\(day.prefix(1).uppercased() + day.dropFirst()), \(dayMonth(start))",
                     time(start), duration(length)]
        if let people, people > 0 { parts.append("\(people) người") }
        return parts.joined(separator: " · ")
    }
}
