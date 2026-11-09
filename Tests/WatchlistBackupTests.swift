import Foundation
import Testing
@testable import XPriceCore

struct WatchlistBackupTests {
    private let stock = Instrument(symbol: "sh600519", name: "合成股票")
    private let fund = Instrument(symbol: "sh510300", name: "合成ETF", kind: .etf)
    private let date = Date(timeIntervalSince1970: 1_793_950_800)

    @Test func roundTripsPortableListsAndSettingsWithoutCacheOrSyncData() throws {
        let settings = AppSettings(phoneRefreshSeconds: 10, watchRefreshSeconds: 15,
                                   colorConvention: .greenUp, widgetSymbol: stock.symbol,
                                   marketDataSource: .sina, phoneAppearance: .dark,
                                   buttonTheme: .purple, smartRefreshEnabled: false,
                                   additionalClosedDates: ["2026-11-09"])
        let backup = WatchlistBackup(watchlist: [stock], overviewInstruments: [fund],
                                    settings: settings, exportedAt: date)
        let data = try backup.encode()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "version", "exportedAt", "watchlist", "overviewInstruments", "settings"])
        let restored = try WatchlistBackup.decode(data)
        #expect(restored.watchlist == [stock])
        #expect(restored.overviewInstruments == [fund])
        #expect(restored.settings == settings)
        #expect(restored.exportedAt == date)
        #expect(restored.format == WatchlistBackup.formatIdentifier)
        #expect(restored.version == 1)
    }

    @Test func normalizesSymbolsAndDeduplicatesWhileKeepingFirstMetadataAndOrder() throws {
        let first = Instrument(symbol: " SH600519 ", name: " 第一名称 ")
        let second = Instrument(symbol: "sh600519", name: "第二名称")
        let backup = WatchlistBackup(watchlist: [first, fund, second], overviewInstruments: [fund, fund],
                                    settings: AppSettings(), exportedAt: date)
        let restored = try WatchlistBackup.decode(backup.encode())
        #expect(restored.watchlist == [Instrument(symbol: stock.symbol, name: "第一名称"), fund])
        #expect(restored.overviewInstruments == [fund])
    }

    @Test func rejectsOversizeInvalidDocumentsAndFutureVersions() throws {
        #expect(throws: WatchlistBackupError.oversized) {
            try WatchlistBackup.decode(Data(repeating: 0x20, count: WatchlistBackup.maximumBytes + 1))
        }
        for value in [Data(), Data("<html>Error</html>".utf8), Data("{}".utf8)] {
            #expect(throws: WatchlistBackupError.invalidFormat) { try WatchlistBackup.decode(value) }
        }
        var object = try backupObject()
        object["format"] = "another-app"
        #expect(throws: WatchlistBackupError.invalidFormat) {
            try WatchlistBackup.decode(JSONSerialization.data(withJSONObject: object))
        }
        object["format"] = WatchlistBackup.formatIdentifier
        object["version"] = 2
        object.removeValue(forKey: "watchlist")
        #expect(throws: WatchlistBackupError.unsupportedVersion(2)) {
            try WatchlistBackup.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func rejectsUnsupportedCodeWrongKindAndInvalidName() throws {
        let invalid = [
            Instrument(symbol: "hk00700", name: "港股"),
            Instrument(symbol: "sh900901", name: "B股"),
            Instrument(symbol: "sh600519&bad=1", name: "错误代码"),
            Instrument(symbol: stock.symbol, name: "错误类型", kind: .etf),
            Instrument(symbol: fund.symbol, name: "错误类型", kind: .stock),
            Instrument(symbol: stock.symbol, name: " "),
            Instrument(symbol: stock.symbol, name: "含\n换行"),
            Instrument(symbol: stock.symbol, name: String(repeating: "名", count: 129))
        ]
        for instrument in invalid {
            let backup = WatchlistBackup(watchlist: [instrument], settings: AppSettings())
            #expect(throws: WatchlistBackupError.self) { try backup.encode() }
        }
        // Generic fund classification remains usable for older stored metadata.
        let generic = Instrument(symbol: fund.symbol, name: fund.name, kind: .fund)
        #expect(try WatchlistBackup.decode(WatchlistBackup(watchlist: [generic], settings: AppSettings()).encode()).watchlist == [generic])
    }

    @Test func rejectsOversizedListsWithoutSilentlyTruncatingOrDeduplicatingThemToFit() throws {
        let repeated = Array(repeating: stock, count: 51)
        #expect(throws: WatchlistBackupError.self) {
            try WatchlistBackup(watchlist: repeated, settings: AppSettings()).encode()
        }
        #expect(throws: WatchlistBackupError.self) {
            try WatchlistBackup(watchlist: [], overviewInstruments: repeated, settings: AppSettings()).encode()
        }
    }

    @Test func mergeKeepsLocalMetadataAndIndependentListOrder() throws {
        let localStock = Instrument(symbol: stock.symbol, name: "本地名称")
        let snapshot = CacheSnapshot(watchlist: [localStock], quotes: [stock.symbol: quote(stock)],
                                     settings: AppSettings(widgetSymbol: stock.symbol), overviewInstruments: [fund])
        let backup = WatchlistBackup(watchlist: [stock, fund], overviewInstruments: [stock],
                                    settings: AppSettings(marketDataSource: .sina), exportedAt: date)
        let result = try backup.apply(to: snapshot, mode: .merge, includeSettings: false, date: date)
        #expect(result.watchlist == [localStock, fund])
        #expect(result.overviewInstruments == [fund, localStock])
        #expect(result.settings == snapshot.settings)
        #expect(result.quotes == snapshot.quotes)
        #expect(snapshot.watchlist == [localStock])
        #expect(result.watchlistUpdatedAt == date)
    }

    @Test func mergeOverflowFailsAndLeavesOriginalSnapshotIntact() throws {
        let local = (0..<50).map { Instrument(symbol: String(format: "sh600%03d", $0), name: "合成股票") }
        let snapshot = CacheSnapshot(watchlist: local, quotes: [:], settings: AppSettings())
        let backup = WatchlistBackup(watchlist: [stock], settings: AppSettings())
        #expect(throws: WatchlistBackupError.self) {
            try backup.apply(to: snapshot, mode: .merge, includeSettings: false, date: date)
        }
        #expect(snapshot.watchlist == local)
        #expect(snapshot.watchlist.count == 50)
    }

    @Test func replaceKeepsUnselectedSettingsRepairsWidgetAndRemovesUnrelatedQuotes() throws {
        let localSettings = AppSettings(colorConvention: .greenUp, widgetSymbol: stock.symbol,
                                        marketDataSource: .eastmoney, phoneAppearance: .dark, buttonTheme: .orange)
        let snapshot = CacheSnapshot(watchlist: [stock], quotes: [stock.symbol: quote(stock), fund.symbol: quote(fund)],
                                     settings: localSettings)
        let backup = WatchlistBackup(watchlist: [fund], settings: AppSettings())
        let result = try backup.apply(to: snapshot, mode: .replace, includeSettings: false, date: date)
        #expect(result.watchlist == [fund])
        #expect(result.overviewInstruments.isEmpty)
        #expect(result.quotes.keys.sorted() == [fund.symbol])
        #expect(result.settings.marketDataSource == .eastmoney)
        #expect(result.settings.phoneAppearance == .dark)
        #expect(result.settings.buttonTheme == .orange)
        #expect(result.settings.colorConvention == .greenUp)
        #expect(result.settings.widgetSymbol == fund.symbol)
        #expect(result.settingsVersions.widgetSymbol == date)
        #expect(result.settingsVersions.marketDataSource == snapshot.settingsVersions.marketDataSource)
    }

    @Test func optionalSettingsRestoreUpdatesChangedFieldVersionsAndSupportsWatchMerge() throws {
        let incoming = AppSettings(phoneRefreshSeconds: 10, watchRefreshSeconds: 15,
                                   colorConvention: .greenUp, widgetSymbol: fund.symbol,
                                   marketDataSource: .sina, phoneAppearance: .dark,
                                   buttonTheme: .pink, smartRefreshEnabled: false,
                                   additionalClosedDates: ["2026-11-09"])
        let snapshot = CacheSnapshot(watchlist: [fund], quotes: [:], settings: AppSettings(widgetSymbol: fund.symbol))
        let backup = WatchlistBackup(watchlist: [fund], settings: incoming)
        let result = try backup.apply(to: snapshot, mode: .replace, includeSettings: true, date: date)
        #expect(result.settings == incoming)
        #expect(result.settingsVersions.phoneRefreshSeconds == date)
        #expect(result.settingsVersions.watchRefreshSeconds == date)
        #expect(result.settingsVersions.colorConvention == date)
        #expect(result.settingsVersions.marketDataSource == date)
        #expect(result.settingsVersions.phoneAppearance == date)
        #expect(result.settingsVersions.buttonTheme == date)
        #expect(result.settingsVersions.smartRefreshEnabled == date)
        #expect(result.settingsVersions.additionalClosedDates == date)
        #expect(result.settingsVersions.widgetSymbol == .distantPast)
        var peer = snapshot.settings
        var versions = snapshot.settingsVersions
        versions.merge(local: &peer, incoming: result.settings, versions: result.settingsVersions)
        #expect(peer == incoming)
    }

    @Test func previewMatchesApplyWithoutWritingAndNeverImportsCachedPrices() throws {
        let snapshot = CacheSnapshot(watchlist: [stock], quotes: [stock.symbol: quote(stock)], settings: AppSettings())
        let backup = WatchlistBackup(watchlist: [fund], settings: AppSettings())
        let preview = try backup.preview(to: snapshot, mode: .replace, includeSettings: false, date: date)
        let applied = try backup.apply(to: snapshot, mode: .replace, includeSettings: false, date: date)
        #expect(preview.watchlist == applied.watchlist)
        #expect(preview.settings == applied.settings)
        #expect(preview.quotes.isEmpty)
        #expect(snapshot.quotes.count == 1)
    }

    @Test func unknownSettingsUseDefaultsButMalformedTypesFail() throws {
        var object = try backupObject()
        object["settings"] = ["colorConvention": "future", "marketDataSource": "future", "phoneAppearance": "future",
                              "buttonTheme": "future", "phoneRefreshSeconds": 99, "watchRefreshSeconds": 99,
                              "unusedFutureSetting": "ignored"]
        let restored = try WatchlistBackup.decode(JSONSerialization.data(withJSONObject: object))
        #expect(restored.settings == AppSettings())
        object["settings"] = ["phoneRefreshSeconds": "three"]
        #expect(throws: WatchlistBackupError.invalidFormat) {
            try WatchlistBackup.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func importVersionsAdvanceEvenWhenLocalClockIsBehindExistingEdits() throws {
        let future = date.addingTimeInterval(1000)
        let snapshot = CacheSnapshot(watchlist: [stock], quotes: [:], settings: AppSettings(),
                                     settingsVersions: SettingsVersions(date: future))
        let backup = WatchlistBackup(watchlist: [stock], settings: AppSettings(marketDataSource: .sina))
        let result = try backup.apply(to: snapshot, includeSettings: true, date: date)
        #expect(result.settingsVersions.marketDataSource > future)
        #expect(result.settingsVersions.buttonTheme == future)
    }

    private func backupObject() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: WatchlistBackup(watchlist: [stock], settings: AppSettings(), exportedAt: date).encode()) as? [String: Any])
    }

    private func quote(_ instrument: Instrument) -> Quote {
        Quote(symbol: instrument.symbol, name: instrument.name, price: 12, previousClose: 10,
              changePercent: 20, timestamp: date, fetchedAt: date)
    }
}
