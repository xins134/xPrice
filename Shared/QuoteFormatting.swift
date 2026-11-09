import Foundation
import SwiftUI

public enum QuoteFormatting {
    private static let stockPriceFormatter = priceFormatter(digits: 2)
    private static let threeDecimalPriceFormatter = priceFormatter(digits: 3)
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.positivePrefix = "+"
        return formatter
    }()
    private static let sameDayTimeFormatter = dateFormatter("HH:mm:ss")
    private static let earlierTimeFormatter = dateFormatter("MM-dd HH:mm")
    private static let sameDayCompactFormatter = dateFormatter("HH:mm")
    private static let earlierCompactFormatter = dateFormatter("MM/dd HH:mm")
    private static let fullTimeFormatter = dateFormatter("yyyy-MM-dd HH:mm:ss")
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    public static func price(_ value: Decimal, kind: InstrumentKind) -> String {
        let formatter: NumberFormatter
        switch kind {
        case .stock, .index: formatter = stockPriceFormatter
        case .etf, .lof, .fund, .convertibleBond: formatter = threeDecimalPriceFormatter
        }
        return formatter.string(from: value as NSDecimalNumber) ?? "—"
    }

    public static func percent(_ value: Decimal) -> String {
        (percentFormatter.string(from: value as NSDecimalNumber) ?? "—") + "%"
    }

    public static func signedPrice(_ value: Decimal, kind: InstrumentKind) -> String {
        (value > 0 ? "+" : "") + price(value, kind: kind)
    }

    public static func time(_ date: Date) -> String {
        time(date, relativeTo: Date())
    }

    public static func time(_ date: Date, relativeTo now: Date) -> String {
        let formatter = calendar.isDate(date, inSameDayAs: now) ? sameDayTimeFormatter : earlierTimeFormatter
        return formatter.string(from: date)
    }

    public static func compactTime(_ date: Date, relativeTo now: Date = Date()) -> String {
        let formatter = calendar.isDate(date, inSameDayAs: now) ? sameDayCompactFormatter : earlierCompactFormatter
        return formatter.string(from: date)
    }

    public static func fullTime(_ date: Date) -> String {
        fullTimeFormatter.string(from: date)
    }

    private static func priceFormatter(digits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter
    }

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter
    }

    public static func freshness(_ quote: Quote, now: Date = Date()) -> String {
        if now.timeIntervalSince(quote.timestamp) > 5 * 60 { return "源时间较早" }
        return "行情时间"
    }
}

public enum QuoteColor {
    public static func color(for value: Decimal, convention: PriceColorConvention) -> Color {
        guard value != 0 else { return .secondary }
        let red = (value > 0) == (convention == .redUp)
        // Asset colors use different tones in light and dark appearances.
        return red ? Color("QuoteRed", bundle: .main) : Color("QuoteGreen", bundle: .main)
    }
}
