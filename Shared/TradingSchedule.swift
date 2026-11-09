import Foundation

public enum TradingSession: String, Codable, CaseIterable, Sendable {
    case preMarket, auction, trading, middayBreak, afterHours, weekend, closedDay

    public var displayName: String {
        switch self {
        case .preMarket: "盘前"
        case .auction: "集合竞价"
        case .trading: "交易时段"
        case .middayBreak: "午间休市"
        case .afterHours: "已收盘"
        case .weekend: "周末"
        case .closedDay: "休市日"
        }
    }

    public var isTrading: Bool { self == .auction || self == .trading }

    public func autoRefreshDelay(interval: Int, failures: Int, smartEnabled: Bool) -> TimeInterval {
        let regularDelay = RefreshPolicy.delay(interval: interval, failures: failures)
        guard smartEnabled else { return regularDelay }
        if isTrading { return regularDelay }
        return max(self == .middayBreak ? 60 : 300, regularDelay)
    }
}

public enum TradingCalendarCoverage: Equatable, Sendable {
    case verifiedYear(Int)
    case weekdayInference(Int)
    case additionalClosedDate

    public var displayName: String {
        switch self {
        case .verifiedYear(let year): "\(year) 年休市日历已核实"
        case .weekdayInference: "按工作日判断"
        case .additionalClosedDate: "自定义休市日"
        }
    }

    public var isVerifiedCalendar: Bool {
        if case .verifiedYear = self { return true }
        return false
    }
}

/// A-share foreground request policy in Beijing time, independent of the device's timezone.
/// Uses weekdays plus user-supplied closed dates; weekends never become trading days through workday adjustments.
public enum TradingSchedule {
    // Reserved for annual exchange calendars if the app later supports them.
    private static let verifiedClosedDatesByYear: [Int: Set<String>] = [:]
    public static let verifiedCalendarSourceURLs: [Int: String] = [:]
    public static let calendarReferenceURL = "https://www.sse.com.cn/disclosure/dealinstruc/closed/"

    public static var verifiedYears: [Int] { verifiedClosedDatesByYear.keys.sorted() }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    public static func session(at date: Date, additionalClosedDates: [String] = []) -> TradingSession {
        session(at: date, closedDates: Set(normalizedClosedDates(additionalClosedDates)))
    }

    private static func session(at date: Date, closedDates: Set<String>) -> TradingSession {
        let day = dateString(for: date)
        let year = calendar.component(.year, from: date)
        if closedDates.contains(day) || verifiedClosedDatesByYear[year]?.contains(day) == true { return .closedDay }
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 { return .weekend }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        switch minutes {
        case ..<555: return .preMarket
        case 555..<570: return .auction
        case 570..<690, 780..<900: return .trading
        case 690..<780: return .middayBreak
        default: return .afterHours
        }
    }

    public static func coverage(at date: Date, additionalClosedDates: [String] = []) -> TradingCalendarCoverage {
        if Set(normalizedClosedDates(additionalClosedDates)).contains(dateString(for: date)) {
            return .additionalClosedDate
        }
        let year = calendar.component(.year, from: date)
        return verifiedClosedDatesByYear[year] == nil ? .weekdayInference(year) : .verifiedYear(year)
    }

    public static func coverageNotice(at date: Date, additionalClosedDates: [String] = []) -> String? {
        switch coverage(at: date, additionalClosedDates: additionalClosedDates) {
        case .verifiedYear: return nil
        case .weekdayInference:
            return "按周一至周五判断，法定节假日请补充休市日期。"
        case .additionalClosedDate:
            return "今日为自定义休市日。"
        }
    }

    /// The next exact session boundary, allowing a caller to wake before a slower refresh delay expires.
    /// Midnight is also a transition when the next date changes between a weekday, weekend or closed day.
    public static func nextTransition(after date: Date, additionalClosedDates: [String] = []) -> Date {
        let closedDates = Set(normalizedClosedDates(additionalClosedDates))
        let initial = session(at: date, closedDates: closedDates)
        let start = calendar.startOfDay(for: date)
        let boundaries = [(0, 0), (9, 15), (9, 30), (11, 30), (13, 0), (15, 0)]
        // A finite set of supplied holidays cannot close every future weekday.
        // This bound also allows for weekends between individually supplied dates.
        let verifiedDateCount = verifiedClosedDatesByYear.values.reduce(0) { $0 + $1.count }
        let daysToCheck = max(14, (closedDates.count + verifiedDateCount) * 2 + 14)
        for offset in 0..<daysToCheck {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            for (hour, minute) in boundaries {
                guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                      candidate > date else { continue }
                if session(at: candidate, closedDates: closedDates) != initial { return candidate }
            }
        }
        // Defensive fallback for dates outside Calendar's representable range.
        return date.addingTimeInterval(300)
    }

    public static func normalizedClosedDates(_ dates: [String]) -> [String] {
        Array(Set(dates.compactMap { raw in
            let date = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return isValidClosedDate(date) ? date : nil
        })).sorted()
    }

    public static func isValidClosedDate(_ date: String) -> Bool {
        guard date.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              let value = dayFormatter().date(from: date) else { return false }
        return dateString(for: value) == date
    }

    public static func dateString(for date: Date) -> String { dayFormatter().string(from: date) }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
