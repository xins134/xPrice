import SwiftUI
import Combine

@MainActor
private final class SearchScreenState: ObservableObject {
    enum Phase {
        case idle
        case searching
        case results(query: String, instruments: [Instrument])
        case failed(String)
    }

    @Published var query = ""
    @Published var phase: Phase = .idle
    var requestID = UUID()
}

struct StockSearchView: View {
    enum Destination { case watchlist, overview }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ui = SearchScreenState()
    let destination: Destination

    init(destination: Destination = .watchlist) {
        self.destination = destination
    }

    var body: some View {
        NavigationStack {
            searchContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(destination == .overview ? "添加行情" : "添加自选")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $ui.query, prompt: "名称或证券代码")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .tint(store.settings.buttonTheme.color)
                }
            }
            .task(id: "\(store.settings.marketDataSource.rawValue):\(ui.query)") { await search(debounce: true) }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if ui.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            discoveryContent
        } else {
            switch ui.phase {
            case .idle:
                instrumentList([])
            case .searching:
                ProgressView("正在搜索")
                    .tint(store.settings.buttonTheme.color)
            case .failed(let error):
                ContentUnavailableView {
                    Label("暂时无法搜索", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("\(error)\n名称搜索失败时，可以输入完整的 6 位证券代码重试。")
                } actions: {
                    Button("重试") { Task { await search(debounce: false) } }
                        .buttonStyle(.bordered)
                        .tint(store.settings.buttonTheme.color)
                }
            case .results(let query, let instruments):
                if instruments.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    instrumentList(instruments)
                }
            }
        }
    }

    @ViewBuilder
    private var discoveryContent: some View {
        if destination == .overview, !store.watchlist.isEmpty {
            instrumentList(store.watchlist, fromWatchlist: true)
        } else {
            ContentUnavailableView {
                Label(destination == .overview ? "添加想看的行情" : "找到你的下一只自选",
                      systemImage: "magnifyingglass")
            } description: {
                Text(destination == .overview
                     ? "搜索名称或完整代码，添加多个证券，\n在首页行情栏左右滑动查看。"
                     : "输入名称或完整代码\n支持沪深北 A 股、指数、ETF、LOF 和沪深可转债")
            } actions: {
                Text("例如：上证指数、510300、兴业转债、113052")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func instrumentList(_ instruments: [Instrument], fromWatchlist: Bool = false) -> some View {
        let selected = selectedInstruments
        let selectedSymbols = Set(selected.map(\.symbol))
        let canAdd = selected.count < 50
        return List {
            if fromWatchlist {
                Section {
                    Text("搜索证券名称或代码，也可从自选中添加。可连续添加多个，在首页左右滑动查看。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(instruments) { instrument in
                    instrumentRow(instrument, added: selectedSymbols.contains(instrument.symbol), canAdd: canAdd)
                }
            } header: {
                if fromWatchlist {
                    Text("从自选中添加")
                }
            } footer: {
                selectionSummary
            }
        }
        .listStyle(.insetGrouped)
    }

    private var selectedInstruments: [Instrument] {
        destination == .overview ? store.overviewInstruments : store.watchlist
    }

    private var selectionSummary: some View {
        let count = selectedInstruments.count
        let collection = destination == .overview ? "行情栏" : "自选"
        return Text(count >= 50
                    ? "\(collection)最多添加 50 只，已达到上限"
                    : "\(collection)已添加 \(count) / 50 只，可继续搜索添加")
    }

    private func instrumentRow(_ instrument: Instrument, added: Bool, canAdd: Bool) -> some View {
        let collection = destination == .overview ? "行情栏" : "自选"
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(instrument.name).font(.body.weight(.medium))
                Text("\(instrument.marketLabel) \(instrument.code) · \(instrument.kind.displayName)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                if destination == .overview {
                    _ = store.addToOverview(instrument)
                } else {
                    _ = store.add(instrument)
                }
            } label: {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .tint(store.settings.buttonTheme.color)
            .disabled(added || !canAdd)
            .accessibilityLabel(added ? "\(instrument.name)，已添加到\(collection)" : "添加\(instrument.name)到\(collection)")
        }
        .padding(.vertical, 4)
    }

    private func search(debounce: Bool) async {
        let requestID = UUID()
        ui.requestID = requestID
        let source = store.settings.marketDataSource
        let term = ui.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { ui.phase = .idle; return }
        ui.phase = .searching
        do {
            if debounce { try await Task.sleep(nanoseconds: 500_000_000) }
            try Task.checkCancellation()
            guard ui.requestID == requestID, source == store.settings.marketDataSource,
                  term == ui.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            let found = try await store.search(term)
            guard !Task.isCancelled, ui.requestID == requestID, source == store.settings.marketDataSource,
                  term == ui.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            ui.phase = .results(query: term, instruments: found)
        } catch {
            guard !Task.isCancelled, ui.requestID == requestID, source == store.settings.marketDataSource,
                  term == ui.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            ui.phase = error is CancellationError ? .idle : .failed(error.localizedDescription)
        }
    }
}
