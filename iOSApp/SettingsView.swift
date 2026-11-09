import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("外观", selection: Binding(
                        get: { store.settings.phoneAppearance },
                        set: { appearance in store.updateSettings { $0.phoneAppearance = appearance } }
                    )) {
                        ForEach(AppAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }
                    .pickerStyle(.navigationLink)

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
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("界面外观")
                } footer: {
                    Text("跟随系统会随 iPhone 的外观自动切换。选择立即生效，并保留到下次打开 App。\n主题色仅用于按钮，涨跌颜色单独设置。")
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
                    .pickerStyle(.navigationLink)
                    .accessibilityHint("选择手机、手表和表盘组件使用的行情服务")
                } header: {
                    Text("行情服务")
                } footer: {
                    Text("三个免费来源均无需 API Key。选择会保存并同步到配对手表，手机、手表和表盘组件按所选来源取价。")
                }

                Section {
                    Toggle("交易时段智能刷新", isOn: Binding(
                        get: { store.settings.smartRefreshEnabled },
                        set: { enabled in store.updateSettings { $0.smartRefreshEnabled = enabled } }
                    ))
                    LabeledContent("当前时段", value: store.tradingSession.displayName)
                    LabeledContent("当前自动间隔", value: "\(store.effectiveRefreshSeconds) 秒")
                    intervalPicker("iPhone", value: store.settings.phoneRefreshSeconds) { seconds in
                        store.updateSettings { $0.phoneRefreshSeconds = seconds }
                    }
                    intervalPicker("Apple Watch", value: store.settings.watchRefreshSeconds) { seconds in
                        store.updateSettings { $0.watchRefreshSeconds = seconds }
                    }
                    NavigationLink("休市日期设置") { ClosedDatesView() }
                } header: {
                    Text("前台刷新间隔")
                } footer: {
                    Text("智能刷新按北京时间的工作日安排：交易时使用所选档位，午休每 60 秒，其他时段每 5 分钟。法定节假日可补充休市日期。锁屏、后台或手表垂腕后暂停，手动刷新随时可用；网络失败时逐步降低频率。")
                }

                Section("行情显示") {
                    Picker("涨跌颜色", selection: Binding(
                        get: { store.settings.colorConvention },
                        set: { color in store.updateSettings { $0.colorConvention = color } }
                    )) {
                        ForEach(PriceColorConvention.allCases, id: \.self) { convention in
                            Text(convention.displayName).tag(convention)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    if store.watchlist.isEmpty {
                        Text("添加自选后选择表盘显示的证券")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("表盘关注", selection: Binding(
                            get: { store.settings.widgetSymbol ?? store.watchlist.first?.symbol ?? "" },
                            set: { store.selectWidgetSymbol($0) }
                        )) {
                            ForEach(store.watchlist) { instrument in
                                Text("\(instrument.name) \(instrument.code)").tag(instrument.symbol)
                            }
                        }
                    }
                    LabeledContent("同步状态", value: store.syncStatus)
                        .font(.subheadline)
                    if let date = store.lastSyncConfirmedAt {
                        LabeledContent("手表上次确认", value: QuoteFormatting.fullTime(date))
                            .font(.footnote)
                        if let count = store.confirmedWatchlistCount {
                            LabeledContent("上次确认自选", value: "\(count) 只")
                        }
                    }
                    Button("重新同步", systemImage: "arrow.triangle.2.circlepath") { store.retrySync() }
                        .tint(store.settings.buttonTheme.color)
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text("“已发送”仍需等待手表确认保存。打开两端 App 可加快同步；上次确认时间只代表那一次的数据。在表盘编辑中添加“自选行情”组件，更新由系统安排。")
                }

                Section("数据管理") {
                    NavigationLink { WatchlistBackupView() } label: {
                        Label("自选备份与恢复", systemImage: "externaldrive")
                    }
                }

                Section {
                    LabeledContent("报价单位", value: "人民币")
                    LabeledContent("涨跌幅基准", value: "上一交易日收盘价")
                } header: {
                    Text("关于行情")
                } footer: {
                    Text("免费公开接口可能延迟、中断或改变。1 秒刷新代表请求间隔，不代表每秒都会产生新报价；请以每只证券标注的行情时间为准。\n\n自选与设置保存在本机，并同步到配对手表。查询证券时会连接行情服务；应用无需登录。\n\nxPrice 1.0 · 个人自用")
                }
            }
            .tint(.accentColor)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .tint(store.settings.buttonTheme.color)
                }
            }
        }
        .preferredColorScheme(store.settings.phoneAppearance.preferredColorScheme)
    }

    private func intervalPicker(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.medium))
            Picker(title, selection: Binding(get: { value }, set: set)) {
                ForEach(AppSettings.refreshOptions, id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }
}
