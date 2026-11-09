import SwiftUI
import Combine

@MainActor
private final class WatchNavigationState: ObservableObject {
    @Published var navigationPath: [String] = []
    @Published var showsSettings = false
}

private enum WatchHomeStyle {
    static let background = Color.black
    static let card = Color(white: 0.10)
    static let border = Color.white.opacity(0.08)
    static let secondary = Color(white: 0.72)
    // Match the existing dark quote palette on the Watch's black card surface.
    static let quoteRed = Color(red: 1, green: 0.482353, blue: 0.537255)
    static let quoteGreen = Color(red: 0.337255, green: 0.850980, blue: 0.627451)
    static let spacing: CGFloat = 8
    static let cornerRadius: CGFloat = 14
    static let refreshButtonSize: CGFloat = 32
    static let refreshHitAreaSize: CGFloat = 44
    static let columns = [
        GridItem(.flexible(minimum: 0), spacing: spacing, alignment: .top),
        GridItem(.flexible(minimum: 0), spacing: spacing, alignment: .top)
    ]
}

struct WatchWatchlistView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var navigation = WatchNavigationState()
    @ScaledMetric(relativeTo: .headline) private var quoteCardHeight: CGFloat = 92

    var body: some View {
        NavigationStack(path: $navigation.navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    if store.watchlist.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: WatchHomeStyle.columns, spacing: WatchHomeStyle.spacing) {
                            ForEach(store.watchlist) { instrument in
                                NavigationLink(value: instrument.symbol) {
                                    let quote = store.quote(for: instrument)
                                    WatchQuoteCard(
                                        instrument: instrument,
                                        quote: quote,
                                        status: QuoteStatus.evaluate(
                                            quote: quote, selectedSource: store.settings.marketDataSource,
                                            session: store.tradingSession,
                                            requestFailed: store.quoteFailures.contains(instrument.symbol)
                                        ),
                                        colorConvention: store.settings.colorConvention,
                                        isWidgetInstrument: store.settings.widgetSymbol == instrument.symbol,
                                        height: quoteCardHeight
                                    )
                                    .equatable()
                                }
                                .buttonStyle(WatchHomeButtonStyle())
                                .accessibilityIdentifier("watch.quote.\(instrument.symbol)")
                            }
                        }

                        WatchRefreshStatus()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let error = store.errorMessage {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(WatchHomeStyle.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(WatchHomeStyle.card, in: RoundedRectangle(cornerRadius: WatchHomeStyle.cornerRadius))
                    }

                    Button {
                        navigation.showsSettings = true
                    } label: {
                        actionLabel("设置", systemImage: "gearshape")
                    }
                    .buttonStyle(WatchHomeButtonStyle())
                    .foregroundStyle(store.settings.buttonTheme.color)
                    .accessibilityIdentifier("watch.settings")
                }
                .padding(.horizontal, 0)
                .padding(.top, 4)
                .padding(.bottom, WatchHomeStyle.refreshHitAreaSize + 24)
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .background(WatchHomeStyle.background)
            .overlay(alignment: .bottomTrailing) {
                floatingRefreshButton
                    .padding(WatchHomeStyle.spacing)
            }
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
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
                guard url.scheme == "xprice" else { return }
                switch url.host {
                case "watchlist":
                    navigation.navigationPath = []
                    navigation.showsSettings = false
                case "quote":
                    guard let symbol = url.pathComponents.dropFirst().first,
                          !symbol.isEmpty else { return }
                    navigation.navigationPath = [symbol]
                default:
                    break
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("自选")
                    .font(.headline.weight(.regular))
                Text("\(store.watchlist.count)")
                    .font(.caption.weight(.regular))
                    .monospacedDigit()
                    .foregroundStyle(WatchHomeStyle.secondary)
                Spacer(minLength: 4)
                Text("\(store.settings.watchRefreshSeconds) 秒")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(WatchHomeStyle.secondary)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let session = TradingSchedule.session(at: context.date, additionalClosedDates: store.settings.additionalClosedDates)
                Text("\(session.displayName) · 选择\(store.settings.marketDataSource.displayName)")
                    .font(.caption2)
                    .foregroundStyle(WatchHomeStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "star")
                .font(.title2)
                .foregroundStyle(store.settings.buttonTheme.color)
                .accessibilityHidden(true)
            Text("还没有自选")
                .font(.headline.weight(.regular))
            Text("在 iPhone 的 xPrice 中添加股票，自选会同步到这里。")
                .font(.footnote)
                .foregroundStyle(WatchHomeStyle.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(WatchHomeStyle.card, in: RoundedRectangle(cornerRadius: WatchHomeStyle.cornerRadius))
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.regular))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(store.settings.buttonTheme.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }

    private var floatingRefreshButton: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            ZStack {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(store.settings.buttonTheme.color)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(store.settings.buttonTheme.color.opacity(0.9))
                }
            }
            .frame(width: WatchHomeStyle.refreshButtonSize, height: WatchHomeStyle.refreshButtonSize)
            .background(WatchHomeStyle.background.opacity(0.45), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(store.settings.buttonTheme.color.opacity(0.3), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .frame(width: WatchHomeStyle.refreshHitAreaSize, height: WatchHomeStyle.refreshHitAreaSize)
            .contentShape(Circle())
        }
        .buttonStyle(WatchHomeButtonStyle())
        .disabled(store.isRefreshing || store.watchlist.isEmpty)
        .accessibilityLabel(store.isRefreshing ? "正在刷新" : "刷新行情")
        .accessibilityIdentifier("watch.refresh")
    }
}

private struct WatchHomeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.70 : 1) : 0.45)
    }
}

private struct WatchQuoteCard: View, Equatable {
    let instrument: Instrument
    let quote: Quote?
    let status: QuoteStatus
    let colorConvention: PriceColorConvention
    let isWidgetInstrument: Bool
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let centerX = geometry.size.width / 2
            let textWidth = max(0, geometry.size.width - 16)
            let slotHeight = geometry.size.height / 4

            Text(instrument.name)
                .font(.caption2.weight(.regular))
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .frame(width: textWidth, height: slotHeight, alignment: .center)
                .position(x: centerX, y: geometry.size.height * 0.25)

            Text(quote.map { QuoteFormatting.price($0.price, kind: instrument.kind) } ?? "—")
                .font(.system(.headline, design: .rounded, weight: .regular))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .frame(width: textWidth, height: slotHeight, alignment: .center)
                .position(x: centerX, y: geometry.size.height * 0.50)

            Text(quote.map { QuoteFormatting.percent($0.changePercent) } ?? "—")
                .font(.system(.caption, design: .rounded, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(changeColor)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(changeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .frame(width: textWidth, height: slotHeight, alignment: .center)
                .position(x: centerX, y: geometry.size.height * 0.75)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .center)
        .background(WatchHomeStyle.card, in: RoundedRectangle(cornerRadius: WatchHomeStyle.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: WatchHomeStyle.cornerRadius)
                .strokeBorder(WatchHomeStyle.border, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: WatchHomeStyle.cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(status.message)
    }

    private var changeColor: Color {
        guard let quote, quote.changePercent != 0 else { return WatchHomeStyle.secondary }
        let isRed = (quote.changePercent > 0) == (colorConvention == .redUp)
        return isRed ? WatchHomeStyle.quoteRed : WatchHomeStyle.quoteGreen
    }

    private var accessibilitySummary: String {
        let price = quote.map { QuoteFormatting.price($0.price, kind: instrument.kind) } ?? "暂无价格"
        let percent = quote.map { QuoteFormatting.percent($0.changePercent) } ?? "暂无涨跌幅"
        return "\(instrument.name)，价格 \(price)，涨跌幅 \(percent)"
            + (isWidgetInstrument ? "，表盘显示" : "")
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
