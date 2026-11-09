import SwiftUI
import WidgetKit

private struct QuoteEntry: TimelineEntry {
    let date: Date
    let instrument: Instrument?
    let quote: Quote?
    let colorConvention: PriceColorConvention
    let refreshFailed: Bool
    let selectedSource: MarketDataSource
    let additionalClosedDates: [String]

    var deepLink: URL? {
        guard let instrument else { return URL(string: "xprice://watchlist") }
        var components = URLComponents()
        components.scheme = "xprice"
        components.host = "quote"
        components.path = "/\(instrument.symbol)"
        return components.url
    }
}

private struct QuoteTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuoteEntry {
        QuoteEntry(date: .now, instrument: nil, quote: nil, colorConvention: .redUp, refreshFailed: false,
                   selectedSource: .tencent, additionalClosedDates: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (QuoteEntry) -> Void) {
        completion(cachedEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuoteEntry>) -> Void) {
        Task {
            let entry = await refreshedEntry()
            // This requests a future update; WidgetKit decides when it can run.
            let nextRequest = Date.now.addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRequest)))
        }
    }

    private func selectedInstrument(in snapshot: CacheSnapshot) -> Instrument? {
        snapshot.watchlist.first { $0.symbol == snapshot.settings.widgetSymbol }
            ?? snapshot.watchlist.first
    }

    private func cachedEntry(refreshFailed: Bool = false) -> QuoteEntry {
        guard let snapshot = SnapshotStore.load() else {
            return QuoteEntry(date: .now, instrument: nil, quote: nil, colorConvention: .redUp, refreshFailed: refreshFailed,
                              selectedSource: .tencent, additionalClosedDates: [])
        }
        let instrument = selectedInstrument(in: snapshot)
        return QuoteEntry(
            date: .now,
            instrument: instrument,
            quote: instrument.flatMap { snapshot.quotes[$0.symbol] },
            colorConvention: snapshot.settings.colorConvention,
            refreshFailed: refreshFailed,
            selectedSource: snapshot.settings.marketDataSource,
            additionalClosedDates: snapshot.settings.additionalClosedDates
        )
    }

    private func refreshedEntry() async -> QuoteEntry {
        guard let snapshot = SnapshotStore.load(),
              let instrument = selectedInstrument(in: snapshot) else {
            return cachedEntry()
        }
        do {
            let provider = MarketDataProviders.make(source: snapshot.settings.marketDataSource)
            let quotes = try await provider.quotes(for: [instrument])
            guard let quote = quotes.first(where: { $0.symbol == instrument.symbol }) else {
                return cachedEntry(refreshFailed: isCurrentSelection(snapshot, instrument: instrument))
            }

            // A phone/Watch setting may arrive while this timeline request is running.
            guard isCurrentSelection(snapshot, instrument: instrument) else {
                return cachedEntry()
            }

            SnapshotStore.updateQuote(quote, source: snapshot.settings.marketDataSource,
                                      sourceVersion: snapshot.settingsVersions.marketDataSource)
            return cachedEntry()
        } catch {
            return cachedEntry(refreshFailed: isCurrentSelection(snapshot, instrument: instrument))
        }
    }

    private func isCurrentSelection(_ snapshot: CacheSnapshot, instrument: Instrument) -> Bool {
        guard let current = SnapshotStore.load() else { return false }
        return current.hasSameMarketDataSelection(as: snapshot) &&
            selectedInstrument(in: current)?.symbol == instrument.symbol
    }
}

struct XPriceQuoteWidget: Widget {
    let kind = "XPriceQuoteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuoteTimelineProvider()) { entry in
            QuoteWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(entry.deepLink)
        }
        .configurationDisplayName("自选行情")
        .description("查看选中股票的最近价格与涨跌幅。点击打开 xPrice；表盘更新由系统安排。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct QuoteWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuoteEntry

    var body: some View {
        // This updates time-derived wording only. Network requests remain solely
        // in getTimeline and are still scheduled by WidgetKit.
        TimelineView(.periodic(from: entry.date, by: 60)) { context in
            let session = TradingSchedule.session(at: context.date, additionalClosedDates: entry.additionalClosedDates)
            let status = QuoteStatus.evaluate(quote: entry.quote, selectedSource: entry.selectedSource,
                                              session: session, requestFailed: entry.refreshFailed, now: context.date)
            Group {
                if let instrument = entry.instrument, let quote = entry.quote {
                    let text = formattedText(instrument, quote, status: status, now: context.date)
                    switch family {
                    case .accessoryCircular:
                        circular(instrument, quote, text: text)
                    case .accessoryInline:
                        Text("\(instrument.code) \(text.price) \(text.percent)\(text.badge.map { " · " + $0 } ?? "")")
                            .accessibilityLabel(text.accessibilityLabel)
                    default:
                        rectangular(instrument, quote, status: status, text: text)
                    }
                } else {
                    emptyState(status: status)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func circular(_ instrument: Instrument, _ quote: Quote, text: QuoteWidgetText) -> some View {
        VStack(spacing: 2) {
            Text(instrument.code + (text.badge.map { " " + $0 } ?? ""))
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .minimumScaleFactor(0.7)
            Text(text.percent)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(QuoteColor.color(for: quote.changePercent, convention: entry.colorConvention))
                .widgetAccentable()
                .minimumScaleFactor(0.65)
            Text(text.sourceTime)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.65)
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityLabel(text.accessibilityLabel)
    }

    private func rectangular(_ instrument: Instrument, _ quote: Quote, status: QuoteStatus, text: QuoteWidgetText) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(instrument.name)
                    .font(.headline)
                Spacer(minLength: 2)
                Text(instrument.code)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text.price)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                Spacer(minLength: 2)
                Text(text.percent)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(QuoteColor.color(for: quote.changePercent, convention: entry.colorConvention))
                    .widgetAccentable()
            }
            HStack(spacing: 3) {
                if entry.refreshFailed {
                    Image(systemName: "wifi.exclamationmark")
                        .accessibilityLabel("取价失败，显示缓存")
                }
                Text("\(status.sourceLabel) 源\(text.sourceTime)\(text.badge.map { " · " + $0 } ?? "")")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .monospacedDigit()
        .accessibilityLabel(text.accessibilityLabel)
    }

    @ViewBuilder
    private func emptyState(status: QuoteStatus) -> some View {
        switch family {
        case .accessoryInline:
            Text(entry.instrument.map { "\($0.name) \(status.badge ?? "未取价")" } ?? "xPrice · 在 iPhone 添加自选")
        case .accessoryCircular:
            VStack(spacing: 3) {
                Image(systemName: "star")
                    .accessibilityHidden(true)
                Text(entry.instrument == nil ? "添加自选" : status.badge ?? "未取价")
                    .font(.caption2)
            }
        default:
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.instrument?.name ?? "xPrice 自选行情")
                    .font(.headline)
                Text(entry.instrument == nil ? "在 iPhone 添加自选" : "\(status.marketLabel) · \(status.message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shortBadge(_ status: QuoteStatus) -> String? {
        if status.requestFailed { return status.usesPreviousSource ? "失败旧源" : "失败" }
        if status.usesPreviousSource { return "旧源" }
        if status.hasEarlierSourceTime { return "较早" }
        return status.availability == .cachedQuote ? "缓存" : nil
    }

    private func formattedText(_ instrument: Instrument, _ quote: Quote, status: QuoteStatus, now: Date) -> QuoteWidgetText {
        let price = QuoteFormatting.price(quote.price, kind: instrument.kind)
        let percent = QuoteFormatting.percent(quote.changePercent)
        return QuoteWidgetText(
            price: price,
            percent: percent,
            sourceTime: QuoteFormatting.compactTime(quote.timestamp, relativeTo: now),
            badge: shortBadge(status),
            accessibilityLabel: "\(instrument.name)，\(price)，涨跌幅 \(percent)，来源 \(status.sourceLabel)，源时间 \(QuoteFormatting.time(quote.timestamp, relativeTo: now))，\(status.marketLabel)，\(status.message)"
        )
    }
}

private struct QuoteWidgetText {
    let price: String
    let percent: String
    let sourceTime: String
    let badge: String?
    let accessibilityLabel: String
}
