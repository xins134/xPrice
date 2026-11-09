import Foundation

/// Describes only what this app knows. An old source timestamp does not prove
/// delayed transport, suspension, or a particular exchange update frequency.
public struct QuoteStatus: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        case noQuote
        case quote
        case cachedQuote
    }

    public let availability: Availability
    public let marketLabel: String
    public let sourceLabel: String
    public let message: String
    /// Short wording for narrow quote cards and complications.
    public let badge: String?
    public let requestFailed: Bool
    public let usesPreviousSource: Bool
    public let hasEarlierSourceTime: Bool

    public static func evaluate(
        quote: Quote?, selectedSource: MarketDataSource, session: TradingSession,
        requestFailed: Bool = false, now: Date = Date()
    ) -> QuoteStatus {
        guard let quote else {
            return QuoteStatus(
                availability: .noQuote, marketLabel: session.displayName,
                sourceLabel: "尚无报价来源",
                message: requestFailed ? "取价失败 · 尚无有效报价" : "尚未取价",
                badge: requestFailed ? "取价失败" : "未取价",
                requestFailed: requestFailed, usesPreviousSource: false, hasEarlierSourceTime: false
            )
        }

        let previousSource = quote.source.map { $0 != selectedSource } ?? false
        let earlier = session.isTrading && now.timeIntervalSince(quote.timestamp) > 5 * 60
        let sourceLabel = quote.source?.displayName ?? "来源未记录"
        let cached = requestFailed || previousSource || !session.isTrading
        var reasons: [String] = []
        if requestFailed { reasons.append("取价失败，保留缓存") }
        if previousSource { reasons.append("旧来源缓存") }
        if earlier { reasons.append("源时间较早") }
        if reasons.isEmpty {
            reasons.append(session.isTrading ? "最近报价" : "\(session.displayName) · 保留最近行情")
        }
        let badge: String?
        if requestFailed && previousSource { badge = "失败·旧源" }
        else if requestFailed { badge = "失败缓存" }
        else if previousSource { badge = "旧源缓存" }
        else if earlier { badge = "源时较早" }
        else if !session.isTrading { badge = "缓存" }
        else { badge = nil }
        return QuoteStatus(
            availability: cached ? .cachedQuote : .quote,
            marketLabel: session.displayName, sourceLabel: sourceLabel,
            message: reasons.joined(separator: " · "), badge: badge,
            requestFailed: requestFailed, usesPreviousSource: previousSource, hasEarlierSourceTime: earlier
        )
    }
}
