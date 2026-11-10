import Foundation
import Testing
@testable import XPriceCore

struct StorePolicyTests {
    private let instrument = Instrument(symbol: "sh510300", name: "沪深300ETF", kind: .etf)

    @Test func intervalNormalizationAndFailureBackoff() {
        let settings = AppSettings(phoneRefreshSeconds: 0, watchRefreshSeconds: 2)
        #expect(settings.phoneRefreshSeconds == 3)
        #expect(settings.watchRefreshSeconds == 5)
        for seconds in AppSettings.refreshOptions {
            #expect(RefreshPolicy.delay(interval: seconds, failures: 0) == Double(seconds))
        }
        #expect(RefreshPolicy.delay(interval: 1, failures: 1) == 2)
        #expect(RefreshPolicy.delay(interval: 15, failures: 1) == 15)
        #expect(RefreshPolicy.delay(interval: 1, failures: 20) == 60)
    }

    @Test func phoneAppearanceDefaultsToSystemForNewLegacyAndUnknownSettings() throws {
        #expect(AppSettings().phoneAppearance == .system)
        for json in ["{}", "{\"phoneAppearance\":\"future-mode\"}", "{\"phoneAppearance\":null}"] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            #expect(settings.phoneAppearance == .system)
            #expect(settings.phoneRefreshSeconds == 3)
            #expect(settings.marketDataSource == .tencent)
        }
    }

    @Test(arguments: AppAppearance.allCases)
    func phoneAppearancePersistsWithOtherSettings(appearance: AppAppearance) throws {
        try withDefaults { defaults in
            let changed = Date(timeIntervalSince1970: 300)
            var versions = SettingsVersions()
            versions.phoneAppearance = changed
            let settings = AppSettings(phoneRefreshSeconds: 10, watchRefreshSeconds: 15,
                                       colorConvention: .greenUp, widgetSymbol: instrument.symbol,
                                       marketDataSource: .sina, phoneAppearance: appearance)
            SnapshotStore.save(CacheSnapshot(watchlist: [instrument], quotes: [:], settings: settings,
                                            settingsVersions: versions), to: defaults)
            let restored = try #require(SnapshotStore.load(from: defaults))
            #expect(restored.settings == settings)
            #expect(restored.settingsVersions.phoneAppearance == changed)
        }
    }

    @Test func appearanceAndWatchSettingsSurviveOutOfOrderSync() {
        let initial = AppSettings()
        var phone = initial
        var phoneVersions = SettingsVersions()
        phone.phoneAppearance = .dark
        phoneVersions.recordChanges(from: initial, to: phone, at: Date(timeIntervalSince1970: 100))

        var watch = initial
        var watchVersions = SettingsVersions()
        watch.watchRefreshSeconds = 15
        watch.marketDataSource = .eastmoney
        watchVersions.recordChanges(from: initial, to: watch, at: Date(timeIntervalSince1970: 200))

        phoneVersions.merge(local: &phone, incoming: watch, versions: watchVersions)
        #expect(phone.phoneAppearance == .dark)
        #expect(phone.watchRefreshSeconds == 15)
        #expect(phone.marketDataSource == .eastmoney)
        watchVersions.merge(local: &watch, incoming: phone, versions: phoneVersions)
        #expect(watch == phone)

        let prior = phone
        phone.phoneAppearance = .light
        phoneVersions.recordChanges(from: prior, to: phone, at: Date(timeIntervalSince1970: 300))
        #expect(phoneVersions.phoneAppearance == Date(timeIntervalSince1970: 300))
        #expect(phoneVersions.latest == Date(timeIntervalSince1970: 300))
        #expect(phoneVersions.marketDataSource == Date(timeIntervalSince1970: 200))
        phoneVersions.merge(local: &phone, incoming: watch, versions: watchVersions)
        #expect(phone.phoneAppearance == .light)
        watchVersions.merge(local: &watch, incoming: phone, versions: phoneVersions)
        #expect(watch == phone)
    }

    @Test(arguments: [false, true])
    func legacyPeerDoesNotResetPhoneAppearance(hasFieldVersions: Bool) throws {
        let oldSettings = AppSettings(phoneRefreshSeconds: 10, watchRefreshSeconds: 15,
                                      colorConvention: .greenUp, widgetSymbol: instrument.symbol)
        let original = CacheSnapshot(watchlist: [instrument], quotes: [:], settings: oldSettings,
                                     modifiedAt: Date(timeIntervalSince1970: 400))
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var settings = try #require(legacy["settings"] as? [String: Any])
        settings.removeValue(forKey: "phoneAppearance")
        legacy["settings"] = settings
        if hasFieldVersions {
            var versions = try #require(legacy["settingsVersions"] as? [String: Any])
            versions.removeValue(forKey: "phoneAppearance")
            legacy["settingsVersions"] = versions
        } else {
            legacy.removeValue(forKey: "settingsVersions")
        }
        let restored = try JSONDecoder().decode(CacheSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.settings == oldSettings)
        #expect(restored.settingsVersions.phoneAppearance == .distantPast)

        var phone = AppSettings(phoneAppearance: .dark)
        var phoneVersions = SettingsVersions()
        phoneVersions.phoneAppearance = Date(timeIntervalSince1970: 200)
        phoneVersions.merge(local: &phone, incoming: restored.settings, versions: restored.settingsVersions)
        #expect(phone.phoneAppearance == .dark)
        #expect(phone.watchRefreshSeconds == 15)
        #expect(phone.phoneRefreshSeconds == 10)
        #expect(phone.colorConvention == .greenUp)
    }

    @Test func independentPhoneAndWatchChangesSurviveOutOfOrderSync() {
        let initial = AppSettings()
        var phone = initial
        var phoneVersions = SettingsVersions()
        phone.phoneRefreshSeconds = 1
        phoneVersions.recordChanges(from: initial, to: phone, at: Date(timeIntervalSince1970: 100))

        var watch = initial
        var watchVersions = SettingsVersions()
        watch.watchRefreshSeconds = 10
        watchVersions.recordChanges(from: initial, to: watch, at: Date(timeIntervalSince1970: 200))

        phoneVersions.merge(local: &phone, incoming: watch, versions: watchVersions)
        #expect(phone.phoneRefreshSeconds == 1)
        #expect(phone.watchRefreshSeconds == 10)
        watchVersions.merge(local: &watch, incoming: phone, versions: phoneVersions)
        #expect(watch == phone)

        phoneVersions.merge(local: &phone, incoming: initial, versions: SettingsVersions())
        #expect(phone.phoneRefreshSeconds == 1)
        #expect(phone.watchRefreshSeconds == 10)
    }

    @Test func latestSameFieldWinsWithoutChangingOtherSettings() {
        var local = AppSettings(colorConvention: .greenUp, widgetSymbol: "sh510300")
        var versions = SettingsVersions(date: Date(timeIntervalSince1970: 100))
        var incoming = AppSettings()
        var incomingVersions = SettingsVersions()
        incoming.widgetSymbol = "sz161725"
        incomingVersions.widgetSymbol = Date(timeIntervalSince1970: 200)
        versions.merge(local: &local, incoming: incoming, versions: incomingVersions)
        #expect(local.widgetSymbol == "sz161725")
        #expect(local.colorConvention == .greenUp)
    }

    @Test(arguments: MarketDataSource.allCases)
    func selectedMarketDataSourcePersistsWithOtherSettings(source: MarketDataSource) throws {
        try withDefaults { defaults in
            let changed = Date(timeIntervalSince1970: 300)
            var versions = SettingsVersions()
            versions.marketDataSource = changed
            let settings = AppSettings(phoneRefreshSeconds: 10, watchRefreshSeconds: 15,
                                       colorConvention: .greenUp, widgetSymbol: instrument.symbol,
                                       marketDataSource: source)
            let snapshot = CacheSnapshot(watchlist: [instrument], quotes: [:], settings: settings,
                                         settingsVersions: versions)
            SnapshotStore.save(snapshot, to: defaults)
            let restored = try #require(SnapshotStore.load(from: defaults))
            #expect(restored.settings == settings)
            #expect(restored.settingsVersions.marketDataSource == changed)
        }
    }

    @Test func sourceChangeAndWatchIntervalSurviveOutOfOrderSync() {
        let initial = AppSettings()
        var phone = initial
        var phoneVersions = SettingsVersions()
        phone.marketDataSource = .eastmoney
        phoneVersions.recordChanges(from: initial, to: phone, at: Date(timeIntervalSince1970: 100))

        var watch = initial
        var watchVersions = SettingsVersions()
        watch.watchRefreshSeconds = 15
        watchVersions.recordChanges(from: initial, to: watch, at: Date(timeIntervalSince1970: 200))

        phoneVersions.merge(local: &phone, incoming: watch, versions: watchVersions)
        #expect(phone.marketDataSource == .eastmoney)
        #expect(phone.watchRefreshSeconds == 15)
        watchVersions.merge(local: &watch, incoming: phone, versions: phoneVersions)
        #expect(watch == phone)
        #expect(phoneVersions.latest == Date(timeIntervalSince1970: 200))

        let prior = watch
        watch.marketDataSource = .sina
        watchVersions.recordChanges(from: prior, to: watch, at: Date(timeIntervalSince1970: 300))
        phoneVersions.merge(local: &phone, incoming: watch, versions: watchVersions)
        phoneVersions.merge(local: &phone, incoming: initial, versions: SettingsVersions())
        #expect(phone.marketDataSource == .sina)
        #expect(phone.watchRefreshSeconds == 15)
        #expect(phone.phoneRefreshSeconds == 3)
    }

    @Test(arguments: [false, true])
    func legacySnapshotDefaultsSourceWithoutErasingSettings(hasFieldVersions: Bool) throws {
        let settings = AppSettings(phoneRefreshSeconds: 10, watchRefreshSeconds: 15,
                                   colorConvention: .greenUp, widgetSymbol: instrument.symbol)
        let original = CacheSnapshot(watchlist: [instrument],
                                     quotes: [instrument.symbol: quote(price: 3, market: 100, received: 101)],
                                     settings: settings, modifiedAt: Date(timeIntervalSince1970: 400))
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var oldSettings = try #require(legacy["settings"] as? [String: Any])
        oldSettings.removeValue(forKey: "marketDataSource")
        legacy["settings"] = oldSettings
        if hasFieldVersions {
            var oldVersions = try #require(legacy["settingsVersions"] as? [String: Any])
            oldVersions.removeValue(forKey: "marketDataSource")
            legacy["settingsVersions"] = oldVersions
        } else {
            legacy.removeValue(forKey: "settingsVersions")
        }
        let restored = try JSONDecoder().decode(CacheSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.watchlist == original.watchlist)
        #expect(restored.quotes == original.quotes)
        #expect(restored.settings == settings)
        #expect(restored.settings.marketDataSource == .tencent)
        #expect(restored.settingsVersions.marketDataSource == .distantPast)

        var local = AppSettings(marketDataSource: .sina)
        var localVersions = SettingsVersions()
        localVersions.marketDataSource = Date(timeIntervalSince1970: 200)
        localVersions.merge(local: &local, incoming: restored.settings, versions: restored.settingsVersions)
        #expect(local.marketDataSource == .sina)
        #expect(local.watchRefreshSeconds == 15)
    }

    @Test func sameMarketSecondNeverMovesReceivedTimeBackward() {
        let newer = quote(price: 4, market: 100, received: 102)
        let older = quote(price: 3, market: 100, received: 101)
        #expect(!QuoteMerge.shouldReplace(newer, with: older))
        #expect(!QuoteMerge.shouldReplace(newer, with: newer))
        #expect(QuoteMerge.shouldReplace(older, with: newer))
        #expect(!QuoteMerge.shouldReplace(newer, with: quote(price: 8, market: 99, received: 105)))
    }

    @Test func syncedQuotesMustMatchSourceAndSourceVersion() {
        var versions = SettingsVersions()
        versions.marketDataSource = Date(timeIntervalSince1970: 200)
        let current = CacheSnapshot(watchlist: [instrument], quotes: [:],
                                    settings: AppSettings(marketDataSource: .sina), settingsVersions: versions)
        let otherSource = CacheSnapshot(watchlist: [instrument], quotes: [:],
                                        settings: AppSettings(marketDataSource: .tencent), settingsVersions: versions)
        #expect(!current.hasSameMarketDataSelection(as: otherSource))
        var oldSelection = current
        oldSelection.settingsVersions.marketDataSource = Date(timeIntervalSince1970: 100)
        #expect(!current.hasSameMarketDataSelection(as: oldSelection))
        var intervalChange = current
        intervalChange.settings.watchRefreshSeconds = 15
        intervalChange.settingsVersions.watchRefreshSeconds = Date(timeIntervalSince1970: 300)
        #expect(current.hasSameMarketDataSelection(as: intervalChange))
    }

    @Test func lateWidgetCacheWriteCannotOverrideAnotherSourceOrSelectionVersion() throws {
        try withDefaults { defaults in
            let currentVersion = Date(timeIntervalSince1970: 200)
            var versions = SettingsVersions()
            versions.marketDataSource = currentVersion
            let currentQuote = quote(price: 4, market: 102, received: 103)
            let current = CacheSnapshot(watchlist: [instrument], quotes: [:],
                                        settings: AppSettings(widgetSymbol: instrument.symbol, marketDataSource: .sina),
                                        settingsVersions: versions)
            SnapshotStore.save(current, to: defaults)
            SnapshotStore.updateQuote(currentQuote, source: .sina, sourceVersion: currentVersion, in: defaults)
            // An old provider finishes after the selection check and the new provider's cache write.
            let lateQuote = quote(price: 9, market: 110, received: 111)
            SnapshotStore.updateQuote(lateQuote, source: .tencent,
                                      sourceVersion: Date(timeIntervalSince1970: 100), in: defaults)
            #expect(SnapshotStore.load(from: defaults)?.quotes[instrument.symbol] == currentQuote)
            // Switching away and back to Sina must not revive its previous request.
            SnapshotStore.updateQuote(lateQuote, source: .sina,
                                      sourceVersion: Date(timeIntervalSince1970: 150), in: defaults)
            #expect(SnapshotStore.load(from: defaults)?.quotes[instrument.symbol] == currentQuote)
        }
    }

    @Test func legacyWidgetCacheOnlyAppliesBeforeAnySourceSelection() throws {
        try withDefaults { defaults in
            let legacy = quote(price: 9, market: 110, received: 111)
            defaults.set(try JSONEncoder().encode(legacy), forKey: "xprice.widgetQuote.v1." + instrument.symbol)
            var current = CacheSnapshot(watchlist: [instrument], quotes: [:], settings: AppSettings())
            SnapshotStore.save(current, to: defaults)
            #expect(SnapshotStore.load(from: defaults)?.quotes[instrument.symbol] == legacy)
            current.settings.marketDataSource = .sina
            current.settingsVersions.marketDataSource = Date(timeIntervalSince1970: 200)
            SnapshotStore.save(current, to: defaults)
            #expect(SnapshotStore.load(from: defaults)?.quotes[instrument.symbol] == nil)
            current.settings.marketDataSource = .tencent
            current.settingsVersions.marketDataSource = Date(timeIntervalSince1970: 300)
            SnapshotStore.save(current, to: defaults)
            #expect(SnapshotStore.load(from: defaults)?.quotes[instrument.symbol] == nil)
        }
    }

    @Test func lateWidgetRequestCannotRestoreDeletedWatchlist() throws {
        try withDefaults { defaults in
            let oldQuote = quote(price: 3, market: 100, received: 101)
            SnapshotStore.save(CacheSnapshot(watchlist: [instrument], quotes: [instrument.symbol: oldQuote],
                                             settings: AppSettings(widgetSymbol: instrument.symbol)), to: defaults)
            // The app deletes the symbol while the widget's network request is in flight.
            SnapshotStore.save(CacheSnapshot(watchlist: [], quotes: [:], settings: AppSettings()), to: defaults)
            SnapshotStore.updateQuote(quote(price: 4, market: 102, received: 103), in: defaults)
            let restored = try #require(SnapshotStore.load(from: defaults))
            #expect(restored.watchlist.isEmpty)
            #expect(restored.quotes.isEmpty)
            #expect(restored.settings.widgetSymbol == nil)
        }
    }

    @Test func appPersistenceCannotOverwriteNewerWidgetQuote() throws {
        try withDefaults { defaults in
            let oldQuote = quote(price: 3, market: 100, received: 101)
            let snapshot = CacheSnapshot(watchlist: [instrument], quotes: [instrument.symbol: oldQuote],
                                         settings: AppSettings(widgetSymbol: instrument.symbol))
            SnapshotStore.save(snapshot, to: defaults)
            let updated = quote(price: 4, market: 102, received: 103)
            SnapshotStore.updateQuote(updated, in: defaults)
            SnapshotStore.save(snapshot, to: defaults)
            #expect(SnapshotStore.load(from: defaults)?.quotes[instrument.symbol] == updated)
            SnapshotStore.updateQuote(oldQuote, in: defaults)
            #expect(SnapshotStore.load(from: defaults)?.quotes[instrument.symbol] == updated)
        }
    }

    @Test func snapshotNormalizesDuplicatesAndRestoresFieldVersions() throws {
        try withDefaults { defaults in
            var versions = SettingsVersions()
            versions.phoneRefreshSeconds = Date(timeIntervalSince1970: 900)
            let snapshot = CacheSnapshot(watchlist: [instrument, instrument], quotes: [:],
                                         settings: AppSettings(widgetSymbol: "sz000001"), settingsVersions: versions)
            SnapshotStore.save(snapshot, to: defaults)
            let loaded = try #require(SnapshotStore.load(from: defaults))
            #expect(loaded.watchlist == [instrument])
            #expect(loaded.settings.widgetSymbol == instrument.symbol)
            #expect(loaded.settingsVersions == versions)
        }
    }

    @Test func indexAndStockWithTheSameCodeKeepSeparatePersistenceAndSyncIdentities() throws {
        try withDefaults { defaults in
            let index = Instrument(symbol: "sh000001", name: "上证指数", kind: .index)
            let stock = Instrument(symbol: "sz000001", name: "平安银行", kind: .stock)
            let timestamp = Date(timeIntervalSince1970: 100)
            let indexQuote = Quote(symbol: index.symbol, name: index.name, price: 3300, previousClose: 3200,
                                   changePercent: 3.125, timestamp: timestamp, fetchedAt: timestamp)
            let stockQuote = Quote(symbol: stock.symbol, name: stock.name, price: 12, previousClose: 10,
                                   changePercent: 20, timestamp: timestamp, fetchedAt: timestamp)
            let snapshot = CacheSnapshot(watchlist: [index, stock, index],
                                         quotes: [index.symbol: indexQuote, stock.symbol: stockQuote],
                                         settings: AppSettings(widgetSymbol: index.symbol))
            SnapshotStore.save(snapshot, to: defaults)
            let loaded = try #require(SnapshotStore.load(from: defaults))
            #expect(loaded.watchlist == [index, stock])
            #expect(loaded.quotes[index.symbol] == indexQuote)
            #expect(loaded.quotes[stock.symbol] == stockQuote)
            #expect(loaded.settings.widgetSymbol == index.symbol)

            let synced = try JSONDecoder().decode(CacheSnapshot.self, from: JSONEncoder().encode(loaded))
            #expect(synced.watchlist == [index, stock])
            #expect(synced.quotes == loaded.quotes)
            #expect(synced.settings.widgetSymbol == index.symbol)

            let newerIndexQuote = Quote(symbol: index.symbol, name: index.name, price: 3301, previousClose: 3200,
                                        changePercent: 3.15625, timestamp: timestamp.addingTimeInterval(1),
                                        fetchedAt: timestamp.addingTimeInterval(2))
            SnapshotStore.updateQuote(newerIndexQuote, in: defaults)
            let refreshed = try #require(SnapshotStore.load(from: defaults))
            #expect(refreshed.quotes[index.symbol] == newerIndexQuote)
            #expect(refreshed.quotes[stock.symbol] == stockQuote)
        }
    }

    @Test func legacySnapshotRestoresWithAnEmptyOverview() throws {
        let original = CacheSnapshot(watchlist: [instrument], quotes: [instrument.symbol: quote(price: 3, market: 100, received: 101)],
                                     settings: AppSettings(widgetSymbol: instrument.symbol),
                                     modifiedAt: Date(timeIntervalSince1970: 200))
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "overviewInstruments")
        let restored = try JSONDecoder().decode(CacheSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.overviewInstruments.isEmpty)
        #expect(restored.watchlist == original.watchlist)
        #expect(restored.quotes == original.quotes)
        #expect(restored.settings == original.settings)
        #expect(restored.settingsVersions == original.settingsVersions)
    }

    @Test func convertibleBondsPreserveKindsAndFractionalPricesAcrossPersistenceSyncAndWidgetCache() throws {
        try withDefaults { defaults in
            let shBond = Instrument(symbol: "sh113001", name: "合成沪市转债", kind: .convertibleBond)
            let szBond = Instrument(symbol: "sz123001", name: "合成深市转债", kind: .convertibleBond)
            let timestamp = Date(timeIntervalSince1970: 100)
            let oldQuote = Quote(symbol: szBond.symbol, name: szBond.name,
                                 price: Decimal(string: "123.456")!, previousClose: Decimal(string: "122.345")!,
                                 changePercent: Decimal(string: "0.91")!, timestamp: timestamp, fetchedAt: timestamp,
                                 source: .sina)
            let snapshot = CacheSnapshot(watchlist: [shBond, szBond], quotes: [szBond.symbol: oldQuote],
                                         settings: AppSettings(widgetSymbol: szBond.symbol, marketDataSource: .sina),
                                         overviewInstruments: [szBond])
            SnapshotStore.save(snapshot, to: defaults)
            let persisted = try #require(SnapshotStore.load(from: defaults))
            #expect(persisted.watchlist == [shBond, szBond])
            #expect(persisted.overviewInstruments == [szBond])
            #expect(persisted.settings.widgetSymbol == szBond.symbol)
            #expect(persisted.quotes[szBond.symbol] == oldQuote)

            // WatchConnectivity sends this same Codable snapshot payload.
            let synced = try JSONDecoder().decode(CacheSnapshot.self, from: JSONEncoder().encode(persisted))
            #expect(synced.watchlist == persisted.watchlist)
            #expect(synced.quotes == persisted.quotes)
            #expect(synced.settings.widgetSymbol == szBond.symbol)

            let updated = Quote(symbol: szBond.symbol, name: szBond.name,
                                price: Decimal(string: "123.457")!, previousClose: oldQuote.previousClose,
                                changePercent: oldQuote.changePercent, timestamp: timestamp.addingTimeInterval(1),
                                fetchedAt: timestamp.addingTimeInterval(2), source: .sina)
            SnapshotStore.updateQuote(updated, in: defaults)
            let refreshed = try #require(SnapshotStore.load(from: defaults))
            #expect(refreshed.quotes[szBond.symbol] == updated)
            #expect(refreshed.watchlist == [shBond, szBond])
            #expect(refreshed.overviewInstruments == [szBond])
            #expect(refreshed.settings.widgetSymbol == szBond.symbol)
        }
    }

    @Test func overviewPersistsItsOrderAndKeepsSameCodeInDifferentMarkets() throws {
        try withDefaults { defaults in
            let index = Instrument(symbol: "sh000001", name: "上证指数", kind: .index)
            let stock = Instrument(symbol: "sz000001", name: "平安银行", kind: .stock)
            let snapshot = CacheSnapshot(watchlist: [instrument], quotes: [:],
                                         settings: AppSettings(widgetSymbol: instrument.symbol),
                                         overviewInstruments: [stock, index, stock, instrument])
            SnapshotStore.save(snapshot, to: defaults)
            let restored = try #require(SnapshotStore.load(from: defaults))
            #expect(restored.overviewInstruments == [stock, index, instrument])
            #expect(restored.watchlist == [instrument])
            #expect(restored.settings.widgetSymbol == instrument.symbol)
        }
    }

    @Test func overviewQuoteSurvivesWatchlistRemovalButNotRemovalFromBothLists() throws {
        try withDefaults { defaults in
            let oldQuote = quote(price: 3, market: 100, received: 101)
            var snapshot = CacheSnapshot(watchlist: [], quotes: [instrument.symbol: oldQuote],
                                         settings: AppSettings(), overviewInstruments: [instrument])
            SnapshotStore.save(snapshot, to: defaults)
            let updated = quote(price: 4, market: 102, received: 103)
            SnapshotStore.updateQuote(updated, in: defaults)
            let overviewOnly = try #require(SnapshotStore.load(from: defaults))
            #expect(overviewOnly.watchlist.isEmpty)
            #expect(overviewOnly.overviewInstruments == [instrument])
            #expect(overviewOnly.quotes[instrument.symbol] == updated)
            #expect(overviewOnly.settings.widgetSymbol == nil)

            snapshot.watchlist = [instrument]
            snapshot.overviewInstruments = []
            SnapshotStore.save(snapshot, to: defaults)
            let watchlistOnly = try #require(SnapshotStore.load(from: defaults))
            #expect(watchlistOnly.quotes[instrument.symbol] == updated)

            snapshot.watchlist = []
            SnapshotStore.save(snapshot, to: defaults)
            let removed = try #require(SnapshotStore.load(from: defaults))
            #expect(removed.quotes.isEmpty)
            #expect(removed.overviewInstruments.isEmpty)
        }
    }

    @Test func overviewRestoreHonorsItsOwnLimitWithoutTrimmingWatchlist() throws {
        try withDefaults { defaults in
            let overview = (0..<52).map { Instrument(symbol: "sz\(String(format: "%06d", $0))", name: "证券\($0)") }
            SnapshotStore.save(CacheSnapshot(watchlist: [instrument], quotes: [:], settings: AppSettings(),
                                             overviewInstruments: overview), to: defaults)
            let restored = try #require(SnapshotStore.load(from: defaults))
            #expect(restored.overviewInstruments == Array(overview.prefix(50)))
            #expect(restored.watchlist == [instrument])
        }
    }

    private func quote(price: Decimal, market: TimeInterval, received: TimeInterval) -> Quote {
        Quote(symbol: instrument.symbol, name: instrument.name, price: price, previousClose: 3,
              changePercent: 0, timestamp: Date(timeIntervalSince1970: market),
              fetchedAt: Date(timeIntervalSince1970: received))
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "xprice.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}

struct LocalAppearanceStoreTests {
    @Test func phoneAndWatchAppearanceValuesUseSeparateLocalKeys() throws {
        let suite = "xprice.localAppearance.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let phone = LocalAppearanceSettings(appearance: .dark, buttonTheme: .purple, fontSize: .large)
        let watch = LocalAppearanceSettings(appearance: .system, buttonTheme: .orange, fontSize: .small)
        #expect(LocalAppearanceStore.save(phone, for: .phone, to: defaults))
        #expect(LocalAppearanceStore.save(watch, for: .watch, to: defaults))
        #expect(LocalAppearanceStore.load(for: .phone, from: defaults) == phone)
        #expect(LocalAppearanceStore.load(for: .watch, from: defaults) == watch)

        LocalAppearanceStore.remove(for: .phone, from: defaults)
        #expect(LocalAppearanceStore.load(for: .phone, from: defaults) == nil)
        #expect(LocalAppearanceStore.load(for: .watch, from: defaults) == watch)
    }

    @Test func malformedLocalAppearanceDoesNotProduceAStalePreference() throws {
        let suite = "xprice.localAppearance.malformed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "xprice.localAppearance.v1.phone")
        #expect(LocalAppearanceStore.load(for: .phone, from: defaults) == nil)
    }
}
