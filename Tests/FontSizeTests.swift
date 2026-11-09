import Foundation
import Testing
@testable import XPriceCore

struct FontSizeTests {
    @Test func newLegacyUnknownAndNullSettingsUseTheCurrentSmallerSize() throws {
        #expect(AppSettings().fontSize == .smaller)
        #expect(AppFontSize.allCases.map(\.displayName) == ["小", "较小", "中", "较大", "大"])
        for json in [
            #"{"colorConvention":"greenUp","phoneAppearance":"dark","buttonTheme":"purple"}"#,
            #"{"colorConvention":"greenUp","phoneAppearance":"dark","buttonTheme":"purple","fontSize":"future-size"}"#,
            #"{"colorConvention":"greenUp","phoneAppearance":"dark","buttonTheme":"purple","fontSize":null}"#
        ] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            #expect(settings.fontSize == .smaller)
            #expect(settings.phoneAppearance == .dark)
            #expect(settings.buttonTheme == .purple)
            #expect(settings.colorConvention == .greenUp)
        }
        let oldVersions = try JSONDecoder().decode(SettingsVersions.self, from: Data("{}".utf8))
        #expect(oldVersions.fontSize == .distantPast)
    }

    @Test func malformedFontSizeCannotSilentlyResetSettings() {
        for json in [#"{"fontSize":3}"#, #"{"fontSize":true}"#, #"{"fontSize":[]}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            }
        }
    }

    @Test(arguments: AppFontSize.allCases)
    func allFiveSizesPersistIndependentlyOfOtherPreferences(size: AppFontSize) throws {
        let suite = "xprice.fontSize.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let changedAt = Date(timeIntervalSince1970: 300)
        let settings = AppSettings(phoneRefreshSeconds: 10, watchRefreshSeconds: 15,
                                   colorConvention: .greenUp, marketDataSource: .sina,
                                   phoneAppearance: .dark, buttonTheme: .pink, fontSize: size)
        var versions = SettingsVersions()
        versions.fontSize = changedAt
        let saved = SnapshotStore.saveConfirmed(CacheSnapshot(watchlist: [], quotes: [:], settings: settings,
                                                               settingsVersions: versions), to: defaults)
        #expect(saved)
        let restored = try #require(SnapshotStore.load(from: defaults))
        #expect(restored.settings == settings)
        #expect(restored.settingsVersions.fontSize == changedAt)
        #expect(restored.settingsVersions.latest == changedAt)
    }

    @Test func fontAppearanceThemeAndRefreshChangesSurviveOutOfOrderSync() {
        let initial = AppSettings()
        var phone = initial
        var phoneVersions = SettingsVersions()
        phone.fontSize = .larger
        phoneVersions.recordChanges(from: initial, to: phone, at: Date(timeIntervalSince1970: 100))
        #expect(phoneVersions.fontSize == Date(timeIntervalSince1970: 100))
        #expect(phoneVersions.phoneAppearance == .distantPast)
        #expect(phoneVersions.buttonTheme == .distantPast)
        #expect(phoneVersions.watchRefreshSeconds == .distantPast)

        var watch = initial
        var watchVersions = SettingsVersions()
        watch.phoneAppearance = .dark
        watch.buttonTheme = .purple
        watch.colorConvention = .greenUp
        watch.watchRefreshSeconds = 15
        watchVersions.recordChanges(from: initial, to: watch, at: Date(timeIntervalSince1970: 200))
        phoneVersions.merge(local: &phone, incoming: watch, versions: watchVersions)
        #expect(phone.fontSize == .larger)
        #expect(phone.phoneAppearance == .dark)
        #expect(phone.buttonTheme == .purple)
        #expect(phone.colorConvention == .greenUp)
        #expect(phone.watchRefreshSeconds == 15)
        watchVersions.merge(local: &watch, incoming: phone, versions: phoneVersions)
        #expect(watch == phone)

        let oldPhone = phone
        let oldPhoneVersions = phoneVersions
        let before = watch
        watch.fontSize = .large
        watchVersions.recordChanges(from: before, to: watch, at: Date(timeIntervalSince1970: 300))
        phoneVersions.merge(local: &phone, incoming: watch, versions: watchVersions)
        phoneVersions.merge(local: &phone, incoming: oldPhone, versions: oldPhoneVersions)
        #expect(phone == watch)
        #expect(phone.fontSize == .large)
        #expect(phoneVersions.latest == Date(timeIntervalSince1970: 300))
        #expect(phoneVersions.buttonTheme == Date(timeIntervalSince1970: 200))
        #expect(phoneVersions.marketDataSource == .distantPast)
    }

    @Test(arguments: [false, true])
    func legacySnapshotCannotOverwriteANewerFontSelection(hasFieldVersions: Bool) throws {
        let original = CacheSnapshot(watchlist: [], quotes: [:],
                                     settings: AppSettings(phoneAppearance: .dark, buttonTheme: .purple),
                                     modifiedAt: Date(timeIntervalSince1970: 400))
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var oldSettings = try #require(legacy["settings"] as? [String: Any])
        oldSettings.removeValue(forKey: "fontSize")
        legacy["settings"] = oldSettings
        if hasFieldVersions {
            var oldVersions = try #require(legacy["settingsVersions"] as? [String: Any])
            oldVersions.removeValue(forKey: "fontSize")
            legacy["settingsVersions"] = oldVersions
        } else {
            legacy.removeValue(forKey: "settingsVersions")
        }
        let restored = try JSONDecoder().decode(CacheSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.settings.fontSize == .smaller)
        #expect(restored.settingsVersions.fontSize == .distantPast)

        var local = AppSettings(fontSize: .large)
        var versions = SettingsVersions()
        versions.fontSize = Date(timeIntervalSince1970: 200)
        versions.merge(local: &local, incoming: restored.settings, versions: restored.settingsVersions)
        #expect(local.fontSize == .large)
        #expect(local.phoneAppearance == .dark)
        #expect(local.buttonTheme == .purple)
    }

    @Test(arguments: AppFontSize.allCases)
    func backupRoundTripsAndOnlyRestoresFontWhenSettingsAreSelected(size: AppFontSize) throws {
        let stock = Instrument(symbol: "sh600519", name: "合成股票")
        let localSize: AppFontSize = size == .smaller ? .large : .smaller
        let current = AppSettings(widgetSymbol: stock.symbol, buttonTheme: .orange, fontSize: localSize)
        let imported = AppSettings(widgetSymbol: stock.symbol, buttonTheme: .orange, fontSize: size)
        let snapshot = CacheSnapshot(watchlist: [stock], quotes: [:], settings: current,
                                     modifiedAt: Date(timeIntervalSince1970: 100))
        let backup = try WatchlistBackup.decode(WatchlistBackup(watchlist: [stock], settings: imported).encode())
        #expect(backup.settings.fontSize == size)

        let date = Date(timeIntervalSince1970: 200)
        let kept = try backup.apply(to: snapshot, includeSettings: false, date: date)
        #expect(kept.settings == current)
        #expect(kept.settingsVersions.fontSize == snapshot.settingsVersions.fontSize)

        let restored = try backup.apply(to: snapshot, includeSettings: true, date: date)
        #expect(restored.settings == imported)
        #expect(restored.settingsVersions.fontSize == date)
        #expect(restored.settingsVersions.buttonTheme == snapshot.settingsVersions.buttonTheme)
        var peer = current
        var peerVersions = snapshot.settingsVersions
        peerVersions.merge(local: &peer, incoming: restored.settings, versions: restored.settingsVersions)
        #expect(peer == imported)
    }

    @Test func legacyBackupDefaultsFontAndRejectsMalformedFontTypes() throws {
        let data = try WatchlistBackup(watchlist: [], settings: AppSettings(fontSize: .large)).encode()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var settings = try #require(object["settings"] as? [String: Any])
        for field in [nil, "future-size" as Any?, NSNull() as Any?] {
            settings["fontSize"] = field
            object["settings"] = settings
            let restored = try WatchlistBackup.decode(JSONSerialization.data(withJSONObject: object))
            #expect(restored.settings.fontSize == .smaller)
        }
        settings["fontSize"] = 3
        object["settings"] = settings
        #expect(throws: WatchlistBackupError.invalidFormat) {
            try WatchlistBackup.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func confirmationRequiresTheReceiverToSaveTheNewFontVersion() throws {
        let id = UUID()
        let changedAt = Date(timeIntervalSince1970: 300)
        var sent = CacheSnapshot(watchlist: [], quotes: [:], settings: AppSettings(fontSize: .large))
        sent.settingsVersions.fontSize = changedAt
        var tracker = SyncConfirmationTracker()
        tracker.sent(id: id, snapshot: sent)

        let confirmation = SyncConfirmation(deliveryID: id, persistedAt: .now, snapshot: sent)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmation)) as? [String: Any])
        var oldVersions = try #require(legacy["settingsVersions"] as? [String: Any])
        oldVersions.removeValue(forKey: "fontSize")
        legacy["settingsVersions"] = oldVersions
        let missingFont = try JSONDecoder().decode(SyncConfirmation.self, from: JSONSerialization.data(withJSONObject: legacy))
        let acceptedLegacy = tracker.receive(missingFont)
        #expect(!acceptedLegacy)
        #expect(!tracker.isConfirmed)

        var stale = sent
        stale.settingsVersions.fontSize = changedAt.addingTimeInterval(-1)
        let acceptedStale = tracker.receive(SyncConfirmation(deliveryID: id, persistedAt: .now, snapshot: stale))
        #expect(!acceptedStale)
        let acceptedSaved = tracker.receive(confirmation)
        #expect(acceptedSaved)
        #expect(tracker.isConfirmed)
    }
}
