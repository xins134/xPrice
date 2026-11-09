import SwiftUI

struct InstrumentDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL
    @State private var isEastmoneyUnavailable = false
    let instrument: Instrument
    let onScreenOff: () -> Void

    var body: some View {
        let quote = store.quote(for: instrument)
        let eastmoneyLink = eastmoneyURL
        let status = QuoteStatus.evaluate(quote: quote, selectedSource: store.settings.marketDataSource,
                                          session: store.tradingSession, requestFailed: store.quoteFailures.contains(instrument.symbol))
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(instrument.marketLabel) \(instrument.code) · \(instrument.kind.displayName) · 人民币")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, eastmoneyLink == nil ? 0 : 52)
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
                .overlay(alignment: .topTrailing) {
                    if let url = eastmoneyLink {
                        Button {
                            openURL(url) { accepted in
                                isEastmoneyUnavailable = !accepted
                            }
                        } label: {
                            Label("在东方财富查看", systemImage: "arrow.up.right.square")
                                .labelStyle(.iconOnly)
                                .font(.title3)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .tint(store.settings.buttonTheme.color)
                    }
                }
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

            if store.watchlist.contains(where: { $0.symbol == instrument.symbol }) {
                Section {
                    Toggle("显示在熄屏行情", isOn: Binding(
                        get: { store.isScreenOffSelected(instrument) },
                        set: { selected in
                            store.setScreenOffSelected(selected, for: instrument)
                        }
                    ))
                    .tint(store.settings.buttonTheme.color)
                } header: {
                    Text("熄屏行情 · 已选 \(store.screenOffInstruments.count) 只")
                } footer: {
                    Text("按自选顺序在底部显示涨跌幅，每行最多 4 个，可多行显示。单击其他区域立即隐藏或再次显示行情；隐藏时暂停刷新，重新显示时立即更新。切后台保留页面，点击底部行情区域返回首页。")
                }
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("熄屏", systemImage: "moon.zzz", action: onScreenOff)
                    .labelStyle(.iconOnly)
                    .tint(store.settings.buttonTheme.color)
                    .accessibilityIdentifier("detail.screenOff")
            }
        }
        .refreshable { await store.refresh() }
        .alert("无法打开东方财富", isPresented: $isEastmoneyUnavailable) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请确认已安装东方财富 App，然后重试。")
        }
    }

    private var eastmoneyURL: URL? {
        let market: String
        switch instrument.symbol.prefix(2) {
        case "sh": market = "1"
        case "sz", "bj": market = "0"
        default: return nil
        }
        guard instrument.code.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "eastmoney"
        components.host = "page"
        components.path = "/stockpage"
        components.queryItems = [
            URLQueryItem(name: "code", value: instrument.code),
            URLQueryItem(name: "market", value: market)
        ]
        return components.url
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
