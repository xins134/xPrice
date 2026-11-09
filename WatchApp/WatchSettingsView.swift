import SwiftUI

struct WatchSettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("字体大小", selection: Binding(
                        get: { store.settings.fontSize },
                        set: { size in store.updateSettings { $0.fontSize = size } }
                    )) {
                        ForEach(AppFontSize.allCases, id: \.self) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    Picker("主题色", selection: Binding(
                        get: { store.settings.buttonTheme },
                        set: { theme in store.updateSettings { $0.buttonTheme = theme } }
                    )) {
                        ForEach(ButtonTheme.allCases, id: \.self) { theme in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(theme.color)
                                    .frame(width: 18, height: 18)
                                    .accessibilityHidden(true)
                                Text(theme.displayName)
                            }
                            .tag(theme)
                        }
                    }
                } header: {
                    Text("界面外观")
                } footer: {
                    Text("字体默认较小，调整后同步到 iPhone。按钮、开关等控件跟随主题色，涨跌颜色单独设置。")
                }

                Section {
                    Picker("行情来源", selection: Binding(
                        get: { store.settings.marketDataSource },
                        set: { source in store.updateSettings { $0.marketDataSource = source } }
                    )) {
                        ForEach(MarketDataSource.allCases, id: \.self) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .accessibilityHint("选择手表和表盘组件使用的行情服务")
                } footer: {
                    Text("无需 API Key。选择会同步到 iPhone，并用于手表和表盘取价。")
                }

                Section {
                    Toggle("智能刷新", isOn: Binding(
                        get: { store.settings.smartRefreshEnabled },
                        set: { enabled in store.updateSettings { $0.smartRefreshEnabled = enabled } }
                    ))
                    LabeledContent("当前时段", value: store.tradingSession.displayName)
                    LabeledContent("自动间隔", value: "\(store.effectiveRefreshSeconds) 秒")
                    Picker("手表刷新", selection: Binding(
                        get: { store.settings.watchRefreshSeconds },
                        set: { seconds in store.updateSettings { $0.watchRefreshSeconds = seconds } }
                    )) {
                        ForEach(AppSettings.refreshOptions, id: \.self) { seconds in
                            Text("\(seconds) 秒").tag(seconds)
                        }
                    }
                } footer: {
                    Text("智能刷新：交易时使用所选档位，午休 60 秒，其他时段 5 分钟。按北京时间工作日判断，休市日期在手机补充并同步。仅 App 活跃时自动刷新。")
                }

                Section {
                    Picker("涨跌颜色", selection: Binding(
                        get: { store.settings.colorConvention },
                        set: { convention in store.updateSettings { $0.colorConvention = convention } }
                    )) {
                        Text("红涨绿跌").tag(PriceColorConvention.redUp)
                        Text("绿涨红跌").tag(PriceColorConvention.greenUp)
                    }
                }

                if !store.watchlist.isEmpty {
                    Section {
                        Picker("表盘股票", selection: Binding(
                            get: { store.settings.widgetSymbol ?? store.watchlist.first?.symbol ?? "" },
                            set: { store.selectWidgetSymbol($0) }
                        )) {
                            ForEach(store.watchlist) { instrument in
                                Text(instrument.name).tag(instrument.symbol)
                            }
                        }
                    } footer: {
                        Text("先在表盘编辑中添加 xPrice 组件。这里选择组件显示的股票。")
                    }
                }

                Section("同步") {
                    Text(store.syncStatus).font(.footnote)
                    if let date = store.lastSyncConfirmedAt {
                        LabeledContent("iPhone 上次确认", value: QuoteFormatting.time(date))
                            .font(.footnote)
                    }
                    Button("重新同步", systemImage: "arrow.triangle.2.circlepath") { store.retrySync() }
                        .tint(store.settings.buttonTheme.color)
                }
            }
            .tint(store.settings.buttonTheme.color)
            .navigationTitle("设置")
        }
    }
}
