import Foundation

public struct CacheSnapshot: Codable, Sendable {
    public var watchlist: [Instrument]
    /// The phone's independently curated quote strip; never replaces the Watch watchlist.
    public var overviewInstruments: [Instrument]
    public var quotes: [String: Quote]
    public var settings: AppSettings
    public var modifiedAt: Date
    public var watchlistUpdatedAt: Date
    public var settingsUpdatedAt: Date
    public var settingsVersions: SettingsVersions

    public init(watchlist: [Instrument], quotes: [String: Quote], settings: AppSettings,
                modifiedAt: Date = .distantPast, watchlistUpdatedAt: Date? = nil,
                settingsUpdatedAt: Date? = nil, settingsVersions: SettingsVersions? = nil,
                overviewInstruments: [Instrument] = []) {
        self.watchlist = watchlist
        self.overviewInstruments = overviewInstruments
        self.quotes = quotes
        self.settings = settings
        self.modifiedAt = modifiedAt
        self.watchlistUpdatedAt = watchlistUpdatedAt ?? modifiedAt
        self.settingsUpdatedAt = settingsUpdatedAt ?? modifiedAt
        self.settingsVersions = settingsVersions ?? SettingsVersions(date: settingsUpdatedAt ?? modifiedAt)
    }

    public func hasSameMarketDataSelection(as other: CacheSnapshot) -> Bool {
        settings.marketDataSource == other.settings.marketDataSource &&
            settingsVersions.marketDataSource == other.settingsVersions.marketDataSource
    }

    private enum CodingKeys: String, CodingKey {
        case watchlist, overviewInstruments, quotes, settings, modifiedAt
        case watchlistUpdatedAt, settingsUpdatedAt, settingsVersions
    }

    private enum SettingsCodingKeys: String, CodingKey {
        case marketDataSource, phoneAppearance, buttonTheme, smartRefreshEnabled, additionalClosedDates
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        watchlist = try values.decode([Instrument].self, forKey: .watchlist)
        overviewInstruments = try values.decodeIfPresent([Instrument].self, forKey: .overviewInstruments) ?? []
        quotes = try values.decode([String: Quote].self, forKey: .quotes)
        settings = try values.decode(AppSettings.self, forKey: .settings)
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
        watchlistUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .watchlistUpdatedAt) ?? modifiedAt
        settingsUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .settingsUpdatedAt) ?? modifiedAt
        settingsVersions = try values.decodeIfPresent(SettingsVersions.self, forKey: .settingsVersions)
            ?? SettingsVersions(date: settingsUpdatedAt)
        let settingsValues = try values.nestedContainer(keyedBy: SettingsCodingKeys.self, forKey: .settings)
        if !settingsValues.contains(.marketDataSource) {
            // Legacy peers did not select a source; their other setting edits must not reset it.
            settingsVersions.marketDataSource = .distantPast
        }
        if !settingsValues.contains(.phoneAppearance) {
            // A peer without appearance support must not replace the phone's chosen theme.
            settingsVersions.phoneAppearance = .distantPast
        }
        if !settingsValues.contains(.buttonTheme) {
            // Peers without button themes did not choose one; retain the newer device's selection.
            settingsVersions.buttonTheme = .distantPast
        }
        if !settingsValues.contains(.smartRefreshEnabled) {
            settingsVersions.smartRefreshEnabled = .distantPast
        }
        if !settingsValues.contains(.additionalClosedDates) {
            settingsVersions.additionalClosedDates = .distantPast
        }
    }
}

public enum SnapshotStore {
    public static let groupIdentifier = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        ?? "group.com.example.xprice.shared"
    private static let key = "xprice.snapshot.v1"
    private static let legacyWidgetQuotePrefix = "xprice.widgetQuote.v1."
    private static let widgetQuotePrefix = "xprice.widgetQuote.v2."

    private struct WidgetQuoteRecord: Codable {
        let quote: Quote
        let source: MarketDataSource
        let sourceVersion: Date
    }

    private static func widgetQuoteKey(symbol: String, source: MarketDataSource, sourceVersion: Date) -> String {
        widgetQuotePrefix + source.rawValue + "." + String(sourceVersion.timeIntervalSince1970) + "." + symbol
    }

    private static var defaults: UserDefaults {
        #if os(iOS) || os(watchOS)
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) != nil,
           let group = UserDefaults(suiteName: groupIdentifier) { return group }
        #endif
        return .standard
    }

    public static func load() -> CacheSnapshot? { load(from: defaults) }

    public static func load(from defaults: UserDefaults) -> CacheSnapshot? {
        guard let data = defaults.data(forKey: key),
              var snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: data) else { return nil }
        snapshot.settings.normalize()
        var seen = Set<String>()
        snapshot.watchlist = snapshot.watchlist.filter { seen.insert($0.symbol).inserted }
        var overviewSymbols = Set<String>()
        snapshot.overviewInstruments = snapshot.overviewInstruments
            .filter { overviewSymbols.insert($0.symbol).inserted }.prefix(50).map { $0 }
        seen.formUnion(snapshot.overviewInstruments.map(\.symbol))
        snapshot.quotes = snapshot.quotes.filter { seen.contains($0.key) && $0.key == $0.value.symbol }
        for symbol in seen {
            if snapshot.settings.marketDataSource == .tencent,
               snapshot.settingsVersions.marketDataSource == .distantPast,
               let data = defaults.data(forKey: legacyWidgetQuotePrefix + symbol),
               let quote = try? JSONDecoder().decode(Quote.self, from: data), quote.symbol == symbol,
               QuoteMerge.shouldReplace(snapshot.quotes[symbol], with: quote, preferredSource: snapshot.settings.marketDataSource) {
                snapshot.quotes[symbol] = quote
            }
            let quoteKey = widgetQuoteKey(symbol: symbol, source: snapshot.settings.marketDataSource,
                                          sourceVersion: snapshot.settingsVersions.marketDataSource)
            if let data = defaults.data(forKey: quoteKey),
               let record = try? JSONDecoder().decode(WidgetQuoteRecord.self, from: data),
               record.source == snapshot.settings.marketDataSource,
               record.sourceVersion == snapshot.settingsVersions.marketDataSource,
               record.quote.symbol == symbol,
               QuoteMerge.shouldReplace(snapshot.quotes[symbol], with: record.quote, preferredSource: snapshot.settings.marketDataSource) {
                snapshot.quotes[symbol] = record.quote
            }
        }
        if !snapshot.watchlist.contains(where: { $0.symbol == snapshot.settings.widgetSymbol }) {
            snapshot.settings.widgetSymbol = snapshot.watchlist.first?.symbol
        }
        return snapshot
    }

    public static func save(_ snapshot: CacheSnapshot) { _ = saveConfirmed(snapshot) }

    public static func save(_ snapshot: CacheSnapshot, to defaults: UserDefaults) {
        _ = saveConfirmed(snapshot, to: defaults)
    }

    public static func saveConfirmed(_ snapshot: CacheSnapshot) -> Bool {
        saveConfirmed(snapshot, to: defaults)
    }

    public static func saveConfirmed(_ snapshot: CacheSnapshot, to defaults: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }

    public static func updateQuote(_ quote: Quote) { updateQuote(quote, in: defaults) }

    public static func updateQuote(_ quote: Quote, source: MarketDataSource, sourceVersion: Date) {
        updateQuote(quote, source: source, sourceVersion: sourceVersion, in: defaults)
    }

    /// Widgets never write the app's watchlist/settings document, even when their request finishes late.
    public static func updateQuote(_ quote: Quote, in defaults: UserDefaults) {
        let snapshot = load(from: defaults)
        updateQuote(quote, source: snapshot?.settings.marketDataSource ?? .tencent,
                    sourceVersion: snapshot?.settingsVersions.marketDataSource ?? .distantPast, in: defaults)
    }

    public static func updateQuote(_ quote: Quote, source: MarketDataSource, sourceVersion: Date, in defaults: UserDefaults) {
        let record = WidgetQuoteRecord(quote: quote, source: source, sourceVersion: sourceVersion)
        guard let data = try? JSONEncoder().encode(record) else { return }
        // A distinct key per selection protects against cross-process source changes
        // between the timeline's final selection check and this cache write.
        let quoteKey = widgetQuoteKey(symbol: quote.symbol, source: source, sourceVersion: sourceVersion)
        if let oldData = defaults.data(forKey: quoteKey),
           let old = try? JSONDecoder().decode(WidgetQuoteRecord.self, from: oldData),
           !QuoteMerge.shouldReplace(old.quote, with: quote) { return }
        defaults.set(data, forKey: quoteKey)
    }
}
