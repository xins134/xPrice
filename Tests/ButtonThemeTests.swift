import Foundation
import Testing
@testable import XPriceCore

struct ButtonThemeTests {
    @Test func newLegacyAndUnknownSettingsUseTealWithoutChangingAppearanceOrQuoteColors() throws {
        #expect(AppSettings().buttonTheme == .teal)
        for json in [
            #"{"colorConvention":"greenUp","phoneAppearance":"dark"}"#,
            #"{"colorConvention":"greenUp","phoneAppearance":"dark","buttonTheme":"future-theme"}"#,
            #"{"colorConvention":"greenUp","phoneAppearance":"dark","buttonTheme":null}"#
        ] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            #expect(settings.buttonTheme == .teal)
            #expect(settings.colorConvention == .greenUp)
            #expect(settings.phoneAppearance == .dark)
        }
    }

    @Test(arguments: ButtonTheme.allCases)
    func chosenThemePersistsIndependentlyOfAppearanceAndQuoteColors(theme: ButtonTheme) throws {
        let suite = "xprice.buttonTheme.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let changed = Date(timeIntervalSince1970: 300)
        var versions = SettingsVersions()
        versions.buttonTheme = changed
        let settings = AppSettings(phoneRefreshSeconds: 10, watchRefreshSeconds: 15,
                                   colorConvention: .greenUp, marketDataSource: .sina,
                                   phoneAppearance: .dark, buttonTheme: theme)
        SnapshotStore.save(CacheSnapshot(watchlist: [], quotes: [:], settings: settings,
                                        settingsVersions: versions), to: defaults)
        let restored = try #require(SnapshotStore.load(from: defaults))
        #expect(restored.settings == settings)
        #expect(restored.settingsVersions.buttonTheme == changed)
        #expect(restored.settingsVersions.latest == changed)
    }

    @Test func independentThemeAppearanceAndQuoteColorEditsSurviveOutOfOrderSync() {
        let initial = AppSettings()
        var phone = initial
        var phoneVersions = SettingsVersions()
        phone.buttonTheme = .purple
        phoneVersions.recordChanges(from: initial, to: phone, at: Date(timeIntervalSince1970: 100))
        #expect(phoneVersions.buttonTheme == Date(timeIntervalSince1970: 100))
        #expect(phoneVersions.phoneAppearance == .distantPast)
        #expect(phoneVersions.colorConvention == .distantPast)
        #expect(phoneVersions.marketDataSource == .distantPast)

        var peer = initial
        var peerVersions = SettingsVersions()
        peer.phoneAppearance = .dark
        peer.colorConvention = .greenUp
        peerVersions.recordChanges(from: initial, to: peer, at: Date(timeIntervalSince1970: 200))
        phoneVersions.merge(local: &phone, incoming: peer, versions: peerVersions)
        #expect(phone.buttonTheme == .purple)
        #expect(phone.phoneAppearance == .dark)
        #expect(phone.colorConvention == .greenUp)
        peerVersions.merge(local: &peer, incoming: phone, versions: phoneVersions)
        #expect(peer == phone)

        let before = peer
        peer.buttonTheme = .pink
        peerVersions.recordChanges(from: before, to: peer, at: Date(timeIntervalSince1970: 300))
        phoneVersions.merge(local: &phone, incoming: peer, versions: peerVersions)
        phoneVersions.merge(local: &phone, incoming: initial, versions: SettingsVersions())
        #expect(phone.buttonTheme == .pink)
        #expect(phone.phoneAppearance == .dark)
        #expect(phone.colorConvention == .greenUp)
        #expect(phoneVersions.latest == Date(timeIntervalSince1970: 300))
    }

    @Test(arguments: [false, true])
    func legacySnapshotCannotOverwriteNewThemeSelection(hasFieldVersions: Bool) throws {
        let original = CacheSnapshot(watchlist: [], quotes: [:],
                                     settings: AppSettings(colorConvention: .greenUp, phoneAppearance: .dark),
                                     modifiedAt: Date(timeIntervalSince1970: 400))
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var oldSettings = try #require(legacy["settings"] as? [String: Any])
        oldSettings.removeValue(forKey: "buttonTheme")
        legacy["settings"] = oldSettings
        if hasFieldVersions {
            var oldVersions = try #require(legacy["settingsVersions"] as? [String: Any])
            oldVersions.removeValue(forKey: "buttonTheme")
            legacy["settingsVersions"] = oldVersions
        } else {
            legacy.removeValue(forKey: "settingsVersions")
        }
        let restored = try JSONDecoder().decode(CacheSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.settings.buttonTheme == .teal)
        #expect(restored.settings.phoneAppearance == .dark)
        #expect(restored.settings.colorConvention == .greenUp)
        #expect(restored.settingsVersions.buttonTheme == .distantPast)

        var local = AppSettings(buttonTheme: .orange)
        var localVersions = SettingsVersions()
        localVersions.buttonTheme = Date(timeIntervalSince1970: 200)
        localVersions.merge(local: &local, incoming: restored.settings, versions: restored.settingsVersions)
        #expect(local.buttonTheme == .orange)
        #expect(local.phoneAppearance == .dark)
        #expect(local.colorConvention == .greenUp)
    }

    @Test func buttonThemeChangesDoNotInvalidateMarketDataSelection() {
        var first = CacheSnapshot(watchlist: [], quotes: [:], settings: AppSettings(marketDataSource: .eastmoney))
        var second = first
        second.settings.buttonTheme = .graphite
        second.settingsVersions.recordChanges(from: first.settings, to: second.settings,
                                              at: Date(timeIntervalSince1970: 500))
        #expect(first.hasSameMarketDataSelection(as: second))
        first.settingsVersions.merge(local: &first.settings, incoming: second.settings, versions: second.settingsVersions)
        #expect(first.settings.buttonTheme == .graphite)
        #expect(first.settingsVersions.marketDataSource == .distantPast)
    }
}
