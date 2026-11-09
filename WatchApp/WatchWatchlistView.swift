import SwiftUI
import Combine

@MainActor
private final class WatchNavigationState: ObservableObject {
    @Published var navigationPath: [String] = []
    @Published var showsSettings = false
}

struct WatchWatchlistView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var navigation = WatchNavigationState()

    var body: some View {
        let referenceDay = quoteReferenceDay
        NavigationStack(path: $navigation.navigationPath) {
            List {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let session = TradingSchedule.session(at: context.date, additionalClosedDates: store.settings.additionalClosedDates)
                    Text("\(session.displayName) · 选择\(store.settings.marketDataSource.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if store.watchlist.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "star")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("还没有自选")
                            .font(.headline)
                        Text("在 iPhone 的 xPrice 中添加股票，列表会同步到这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    Section {
                        ForEach(store.watchlist) { instrument in
                            NavigationLink(value: instrument.symbol) {
                                let quote = store.quote(for: instrument)
                                WatchQuoteRow(
                                    instrument: instrument,
                                    quote: quote,
                                    status: QuoteStatus.evaluate(
                                        quote: quote, selectedSource: store.settings.marketDataSource,
                                        session: store.tradingSession,
                                        requestFailed: store.quoteFailures.contains(instrument.symbol)
                                    ),
                                    colorConvention: store.settings.colorConvention,
                                    isWidgetInstrument: store.settings.widgetSymbol == instrument.symbol,
                                    referenceDay: referenceDay
                                )
                                .equatable()
                            }
                            .listRowInsets(.vertical, 4)
                        }
                    } header: {
                        HStack {
                            Text("自选 \(store.watchlist.count)")
                            Spacer()
                            Text("\(store.settings.watchRefreshSeconds) 秒")
                        }
                    } footer: {
                        WatchRefreshStatus()
                    }
                }

                if let error = store.errorMessage {
                    Section {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "正在刷新" : "刷新行情", systemImage: "arrow.clockwise")
                }
                .tint(store.settings.buttonTheme.color)
                .disabled(store.isRefreshing || store.watchlist.isEmpty)

                Button("设置", systemImage: "gearshape") {
                    navigation.showsSettings = true
                }
                .tint(store.settings.buttonTheme.color)
            }
            .environment(\.defaultMinListRowHeight, 44)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .sheet(isPresented: $navigation.showsSettings) {
                WatchSettingsView()
            }
            .navigationDestination(for: String.self) { symbol in
                if let instrument = store.watchlist.first(where: { $0.symbol == symbol }) {
                    WatchQuoteDetailView(instrument: instrument)
                } else {
                    ContentUnavailableView(
                        "暂未找到这只自选",
                        systemImage: "star",
                        description: Text("请在 iPhone 打开 xPrice，同步自选列表后重试。")
                    )
                    .toolbarVisibility(.visible, for: .navigationBar)
                }
            }
            .onOpenURL { url in
                guard url.scheme == "xprice", url.host == "quote",
                      let symbol = url.pathComponents.dropFirst().first,
                      !symbol.isEmpty else { return }
                navigation.navigationPath = [symbol]
            }
        }
    }

    private var quoteReferenceDay: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.startOfDay(for: .now)
    }
}

private struct WatchQuoteRow: View, Equatable {
    let instrument: Instrument
    let quote: Quote?
    let status: QuoteStatus
    let colorConvention: PriceColorConvention
    let isWidgetInstrument: Bool
    let referenceDay: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(instrument.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isWidgetInstrument {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("表盘显示")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(quote.map { QuoteFormatting.price($0.price, kind: instrument.kind) } ?? "—")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                Text(quote.map { QuoteFormatting.percent($0.changePercent) } ?? "—")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(quote.map {
                        QuoteColor.color(for: $0.changePercent, convention: colorConvention)
                    } ?? .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            HStack(spacing: 4) {
                Text("\(instrument.code) · \(status.sourceLabel)")
                Spacer(minLength: 4)
                Text(quote.map { "源\(QuoteFormatting.compactTime($0.timestamp, relativeTo: referenceDay))" } ?? "未取价")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            if let badge = status.badge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityHint(status.message)
    }
}

private struct WatchRefreshStatus: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.isRefreshing {
                Text("正在更新行情…")
            } else if let date = store.lastRefreshAt {
                Text("取价 \(QuoteFormatting.time(date))")
                    .monospacedDigit()
            }
            Text(store.settings.smartRefreshEnabled && !store.tradingSession.isTrading
                 ? "休市期间降低刷新频率，垂腕保留行情。"
                 : "抬腕使用时刷新，垂腕保留最近行情。")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct WatchQuoteDetailView: View {
    @EnvironmentObject private var store: AppStore
    let instrument: Instrument

    var body: some View {
        let quote = store.quote(for: instrument)
        let status = QuoteStatus.evaluate(quote: quote, selectedSource: store.settings.marketDataSource,
                                          session: store.tradingSession, requestFailed: store.quoteFailures.contains(instrument.symbol))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(instrument.marketLabel) · \(instrument.code)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(quote.map { QuoteFormatting.price($0.price, kind: instrument.kind) } ?? "—")
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(quote.map { QuoteFormatting.percent($0.changePercent) } ?? "等待行情")
                        .font(.system(.title3, design: .rounded, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(quote.map {
                            QuoteColor.color(for: $0.changePercent, convention: store.settings.colorConvention)
                        } ?? .secondary)
                    Text("\(status.marketLabel) · \(status.message)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let quote {
                    VStack(alignment: .leading, spacing: 6) {
                        detailLine("昨收", QuoteFormatting.price(quote.previousClose, kind: instrument.kind))
                        detailLine("源时间", QuoteFormatting.time(quote.timestamp))
                        detailLine("取价", QuoteFormatting.time(quote.fetchedAt))
                        detailLine("来源", status.sourceLabel)
                        if status.usesPreviousSource {
                            detailLine("选择", store.settings.marketDataSource.displayName)
                        }
                    }
                    .font(.caption)
                }

                if let error = store.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    store.selectWidgetSymbol(instrument.symbol)
                } label: {
                    Label(
                        store.settings.widgetSymbol == instrument.symbol ? "已设为表盘股票" : "在表盘显示",
                        systemImage: store.settings.widgetSymbol == instrument.symbol ? "checkmark" : "clock"
                    )
                }
                .tint(store.settings.buttonTheme.color)
                .disabled(store.settings.widgetSymbol == instrument.symbol)

                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "正在刷新" : "刷新行情", systemImage: "arrow.clockwise")
                }
                .tint(store.settings.buttonTheme.color)
                .disabled(store.isRefreshing)

                Text("表盘由系统安排更新，显示最近行情和数据时间。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(instrument.name)
        .toolbarVisibility(.visible, for: .navigationBar)
        .accessibilityElement(children: .contain)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
