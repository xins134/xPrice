import SwiftUI
import Combine

@MainActor
private final class ClosedDatesScreenState: ObservableObject {
    @Published var selectedDate = Date()
}

struct ClosedDatesView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var ui = ClosedDatesScreenState()

    var body: some View {
        List {
            Section {
                LabeledContent("交易日规则", value: "周一至周五")
                DatePicker("补充休市日期", selection: $ui.selectedDate, displayedComponents: .date)
                Button("添加休市日", systemImage: "calendar.badge.plus") {
                    let key = TradingSchedule.dateString(for: ui.selectedDate)
                    store.updateSettings { $0.additionalClosedDates.append(key) }
                }
                .tint(store.settings.buttonTheme.color)
                .disabled(store.settings.additionalClosedDates.contains(TradingSchedule.dateString(for: ui.selectedDate)))
            } footer: {
                Text("按北京时间判断工作日。法定节假日不会自动识别，可在这里补充休市日期；这些日期会同步到手表，并随设置一起备份。手动刷新始终可用。")
            }
            Section("已补充的休市日") {
                if store.settings.additionalClosedDates.isEmpty {
                    Text("暂无补充日期").foregroundStyle(.secondary)
                } else {
                    ForEach(store.settings.additionalClosedDates, id: \.self) { date in
                        Text(date).monospacedDigit()
                    }
                    .onDelete { offsets in
                        let dates = store.settings.additionalClosedDates
                        let removed = Set(offsets.compactMap { dates.indices.contains($0) ? dates[$0] : nil })
                        store.updateSettings { $0.additionalClosedDates.removeAll { removed.contains($0) } }
                    }
                }
            }
        }
        .tint(store.settings.buttonTheme.color)
        .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
        .navigationTitle("休市日期")
        .navigationBarTitleDisplayMode(.inline)
    }
}
