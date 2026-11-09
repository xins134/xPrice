import SwiftUI

struct InstrumentDetailView: View {
    @EnvironmentObject private var store: AppStore
    let instrument: Instrument

    var body: some View {
        let quote = store.quote(for: instrument)
        let status = QuoteStatus.evaluate(quote: quote, selectedSource: store.settings.marketDataSource,
                                          session: store.tradingSession, requestFailed: store.quoteFailures.contains(instrument.symbol))
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(instrument.marketLabel) \(instrument.code) · \(instrument.kind.displayName) · 人民币")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let quote {
                        let changeText = QuoteFormatting.signedPrice(quote.change, kind: instrument.kind)
                        let percentText = QuoteFormatting.percent(quote.changePercent)
                        Text(QuoteFormatting.price(quote.price, kind: instrument.kind))
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.75)
                            .lineLimit(1)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { change(changeText); percent(percentText) }
                            VStack(alignment: .leading, spacing: 8) { change(changeText); percent(percentText) }
                        }
                        .foregroundStyle(QuoteColor.color(for: quote.changePercent, convention: store.settings.colorConvention))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    } else {
                        Text("暂无有效报价")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(status.marketLabel) · \(status.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            }

            if let quote {
                Section("行情信息") {
                    LabeledContent("昨收", value: QuoteFormatting.price(quote.previousClose, kind: instrument.kind))
                    LabeledContent("源时间", value: QuoteFormatting.fullTime(quote.timestamp))
                    LabeledContent("本机接收", value: QuoteFormatting.fullTime(quote.fetchedAt))
                    LabeledContent("报价来源", value: status.sourceLabel)
                    if status.usesPreviousSource {
                        LabeledContent("当前选择", value: store.settings.marketDataSource.displayName)
                    }
                }
                .monospacedDigit()
                .font(.subheadline)
            }

            Section {
                if store.watchlist.contains(where: { $0.symbol == instrument.symbol }) {
                    Button {
                        store.selectWidgetSymbol(instrument.symbol)
                    } label: {
                        Label(store.settings.widgetSymbol == instrument.symbol ? "已设为表盘关注" : "显示在 Apple Watch 表盘",
                              systemImage: store.settings.widgetSymbol == instrument.symbol ? "checkmark.circle" : "applewatch")
                    }
                    .tint(store.settings.buttonTheme.color)
                    .disabled(store.settings.widgetSymbol == instrument.symbol)
                } else {
                    Button {
                        store.add(instrument)
                    } label: {
                        Label(store.watchlist.count >= 50 ? "自选已满（50 只）" : "添加到自选", systemImage: "plus.circle")
                    }
                    .tint(store.settings.buttonTheme.color)
                    .disabled(store.watchlist.count >= 50)
                }
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "正在获取行情" : "立即刷新", systemImage: "arrow.clockwise")
                }
                .tint(store.settings.buttonTheme.color)
                .disabled(store.isRefreshing)
            } footer: {
                Text(store.errorMessage ?? "智能刷新可在休市期间降低请求频率。行情时间为北京时间；旧报价会保留原始时间与真实来源。")
            }
        }
        .navigationTitle(instrument.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
    }

    private func change(_ text: String) -> some View {
        Text(text)
            .accessibilityLabel("涨跌额 \(text) 元")
    }

    private func percent(_ text: String) -> some View {
        Text(text)
            .accessibilityLabel("涨跌幅 \(text)")
    }
}
