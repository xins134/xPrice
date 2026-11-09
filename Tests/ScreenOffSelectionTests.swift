import Foundation
import Testing
@testable import XPriceCore

struct ScreenOffSelectionTests {
    private let instruments = [
        Instrument(symbol: "sh600519", name: "贵州茅台"),
        Instrument(symbol: "sz000001", name: "平安银行"),
        Instrument(symbol: "sh510300", name: "沪深300ETF", kind: .etf),
        Instrument(symbol: "sz127045", name: "牧原转债", kind: .convertibleBond)
    ]

    @Test func newSelectionStaysEmpty() {
        let selection = ScreenOffSelection(watchlist: instruments)
        #expect(selection.symbols.isEmpty)
        #expect(selection.instruments(in: instruments).isEmpty)
    }

    @Test(arguments: [4, 12, 50])
    func allExistingInstrumentsCanBeSelectedAndDuplicatesAreIdempotent(count: Int) {
        let watchlist = makeWatchlist(count: count)
        var selection = ScreenOffSelection(watchlist: watchlist)
        for instrument in watchlist {
            let accepted = selection.setSelected(true, for: instrument, watchlist: watchlist)
            #expect(accepted)
        }
        #expect(selection.symbols == watchlist.map(\.symbol))
        #expect(selection.instruments(in: watchlist) == watchlist)
        let before = selection
        let duplicateAccepted = selection.setSelected(true, for: watchlist[1], watchlist: watchlist)
        #expect(duplicateAccepted)
        #expect(selection == before)
    }

    @Test func deselectingAndReselectingUsesWatchlistOrder() {
        var selection = ScreenOffSelection(symbols: instruments.prefix(3).map(\.symbol), watchlist: instruments)
        let removed = selection.setSelected(false, for: instruments[1], watchlist: instruments)
        let added = selection.setSelected(true, for: instruments[3], watchlist: instruments)
        #expect(removed)
        #expect(added)
        #expect(selection.symbols == [instruments[0].symbol, instruments[2].symbol, instruments[3].symbol])

        let removedLast = selection.setSelected(false, for: instruments[3], watchlist: instruments)
        let reselected = selection.setSelected(true, for: instruments[1], watchlist: instruments)
        #expect(removedLast)
        #expect(reselected)
        #expect(selection.instruments(in: instruments) == Array(instruments.prefix(3)))
    }

    @Test func selectionRequiresAnExistingWatchlistSymbol() {
        var selection = ScreenOffSelection(watchlist: instruments)
        let overviewOnly = Instrument(symbol: "sh000001", name: "上证指数", kind: .index)
        let accepted = selection.setSelected(true, for: overviewOnly, watchlist: instruments)
        #expect(!accepted)
        #expect(selection.symbols.isEmpty)
        let renamed = Instrument(symbol: instruments[0].symbol, name: "旧名称")
        let existingAccepted = selection.setSelected(true, for: renamed, watchlist: instruments)
        #expect(existingAccepted)
        #expect(selection.instruments(in: instruments) == [instruments[0]])
    }

    @Test func sanitizationRemovesDuplicatesAndUnknownSymbolsWithoutTruncating() {
        let saved = [instruments[3].symbol, instruments[1].symbol, "sh999999",
                     instruments[1].symbol, instruments[0].symbol, instruments[2].symbol]
        let duplicateWatchlist = [instruments[0], instruments[0]] + Array(instruments.dropFirst())
        let selection = ScreenOffSelection(symbols: saved, watchlist: duplicateWatchlist)
        #expect(selection.symbols == instruments.map(\.symbol))
        #expect(selection.instruments(in: duplicateWatchlist) == instruments)
    }

    @Test func deletionAndReplacementClearSelectionsUntilExplicitlyReselected() {
        var selection = ScreenOffSelection(symbols: instruments.prefix(3).map(\.symbol), watchlist: instruments)
        let replacement = [instruments[2], instruments[3]]
        selection.reconcile(with: replacement)
        #expect(selection.symbols == [instruments[2].symbol])
        selection.reconcile(with: instruments)
        #expect(!selection.contains(instruments[0]))
        #expect(!selection.contains(instruments[1]))
        let reselected = selection.setSelected(true, for: instruments[0], watchlist: instruments)
        #expect(reselected)
        #expect(selection.symbols == [instruments[0].symbol, instruments[2].symbol])
    }

    @Test func reorderedWatchlistDeterminesDisplayAndPersistedOrder() {
        var selection = ScreenOffSelection(symbols: instruments.map(\.symbol), watchlist: instruments)
        let reordered = [instruments[2], instruments[1], instruments[0], instruments[3]]
        #expect(selection.instruments(in: reordered) == reordered)
        selection.reconcile(with: reordered)
        #expect(selection.symbols == reordered.map(\.symbol))
    }

    @Test(arguments: [4, 12, 50])
    func initializationLoadingAndReorderingPreserveAllSelectedSymbols(count: Int) throws {
        let watchlist = makeWatchlist(count: count)
        let savedSymbols = Array(watchlist.reversed()).map(\.symbol)
        let selection = ScreenOffSelection(symbols: savedSymbols, watchlist: watchlist)
        #expect(selection.symbols == watchlist.map(\.symbol))
        try withDefaults { defaults in
            defaults.set(savedSymbols, forKey: ScreenOffSelection.defaultsKey)
            var restored = ScreenOffSelection.load(from: defaults, watchlist: watchlist)
            #expect(restored == selection)
            let reordered = Array(watchlist.reversed())
            restored.reconcile(with: reordered)
            #expect(restored.symbols == savedSymbols)
            restored.save(to: defaults)
            #expect(ScreenOffSelection.load(from: defaults, watchlist: reordered) == restored)
            #expect(ScreenOffSelection.load(from: defaults, watchlist: watchlist) == selection)
        }
    }

    @Test func localPersistenceRestoresSelectionsAndKeepsDeletedItemsCleared() throws {
        try withDefaults { defaults in
            #expect(ScreenOffSelection.load(from: defaults, watchlist: instruments).symbols.isEmpty)
            let selected = ScreenOffSelection(symbols: [instruments[2].symbol, instruments[0].symbol],
                                              watchlist: instruments)
            selected.save(to: defaults)
            #expect(ScreenOffSelection.load(from: defaults, watchlist: instruments) == selected)

            let replacement = [instruments[2], instruments[3]]
            let restored = ScreenOffSelection.load(from: defaults, watchlist: replacement)
            #expect(restored.symbols == [instruments[2].symbol])
            restored.save(to: defaults)
            #expect(ScreenOffSelection.load(from: defaults, watchlist: instruments).symbols == [instruments[2].symbol])
        }
    }

    @Test func invalidStoredTypesYieldAnEmptySelection() throws {
        try withDefaults { defaults in
            defaults.set("invalid", forKey: ScreenOffSelection.defaultsKey)
            #expect(ScreenOffSelection.load(from: defaults, watchlist: instruments).symbols.isEmpty)
            defaults.set([1, 2, 3], forKey: ScreenOffSelection.defaultsKey)
            #expect(ScreenOffSelection.load(from: defaults, watchlist: instruments).symbols.isEmpty)
        }
    }

    private func makeWatchlist(count: Int) -> [Instrument] {
        instruments + (instruments.count..<count).map {
            Instrument(symbol: String(format: "sh%06d", 600000 + $0), name: "测试证券\($0)")
        }
    }

    private func withDefaults(_ operation: (UserDefaults) throws -> Void) throws {
        let suite = "xprice.screenOffSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(defaults)
    }
}
