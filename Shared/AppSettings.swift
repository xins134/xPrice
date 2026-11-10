import Foundation

public enum AppAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    public var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色模式"
        case .dark: "深色模式"
        }
    }
}

public enum AppFontSize: String, Codable, CaseIterable, Sendable {
    case small, smaller, medium, larger, large

    public var displayName: String {
        switch self {
        case .small: "小"
        case .smaller: "较小"
        case .medium: "中"
        case .larger: "较大"
        case .large: "大"
        }
    }
}

public enum ButtonTheme: String, Codable, CaseIterable, Sendable {
    case teal, blue, purple, orange, pink, graphite

    public var displayName: String {
        switch self {
        case .teal: "青绿"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .orange: "橙色"
        case .pink: "玫红"
        case .graphite: "石墨"
        }
    }
}

public enum PriceColorConvention: String, Codable, CaseIterable, Sendable {
    case redUp, greenUp

    public var displayName: String {
        self == .redUp ? "红涨绿跌" : "绿涨红跌"
    }
}

public enum MarketDataSource: String, Codable, CaseIterable, Sendable {
    case tencent, eastmoney, sina

    public var displayName: String {
        switch self {
        case .tencent: "腾讯"
        case .eastmoney: "东方财富"
        case .sina: "新浪"
        }
    }
}

/// Interface preferences belong to the app that owns them. They are kept out
/// of the phone/Watch settings snapshot so changing one device never changes
/// the other device's controls.
public struct LocalAppearanceSettings: Codable, Equatable, Sendable {
    public var appearance: AppAppearance
    public var buttonTheme: ButtonTheme
    public var fontSize: AppFontSize

    public init(appearance: AppAppearance = .system,
                buttonTheme: ButtonTheme = .teal,
                fontSize: AppFontSize = .smaller) {
        self.appearance = appearance
        self.buttonTheme = buttonTheme
        self.fontSize = fontSize
    }
}

public enum AppearanceStorePlatform: String, Sendable {
    case phone
    case watch
}

public enum LocalAppearanceStore {
    private static let keyPrefix = "xprice.localAppearance.v1."

    private static func key(for platform: AppearanceStorePlatform) -> String {
        keyPrefix + platform.rawValue
    }

    public static func load(for platform: AppearanceStorePlatform,
                            from defaults: UserDefaults = .standard) -> LocalAppearanceSettings? {
        guard let data = defaults.data(forKey: key(for: platform)) else { return nil }
        return try? JSONDecoder().decode(LocalAppearanceSettings.self, from: data)
    }

    @discardableResult
    public static func save(_ settings: LocalAppearanceSettings,
                            for platform: AppearanceStorePlatform,
                            to defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        defaults.set(data, forKey: key(for: platform))
        return defaults.data(forKey: key(for: platform)) == data
    }

    public static func remove(for platform: AppearanceStorePlatform,
                              from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: platform))
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let refreshOptions = [1, 3, 5, 10, 15]
    public var phoneRefreshSeconds: Int
    public var watchRefreshSeconds: Int
    public var colorConvention: PriceColorConvention
    public var widgetSymbol: String?
    public var marketDataSource: MarketDataSource
    public var phoneAppearance: AppAppearance
    public var buttonTheme: ButtonTheme
    public var fontSize: AppFontSize
    public var smartRefreshEnabled: Bool
    public var additionalClosedDates: [String]

    public init(phoneRefreshSeconds: Int = 3, watchRefreshSeconds: Int = 5,
                colorConvention: PriceColorConvention = .redUp, widgetSymbol: String? = nil,
                marketDataSource: MarketDataSource = .tencent, phoneAppearance: AppAppearance = .system,
                buttonTheme: ButtonTheme = .teal, fontSize: AppFontSize = .smaller,
                smartRefreshEnabled: Bool = true,
                additionalClosedDates: [String] = []) {
        self.phoneRefreshSeconds = phoneRefreshSeconds
        self.watchRefreshSeconds = watchRefreshSeconds
        self.colorConvention = colorConvention
        self.widgetSymbol = widgetSymbol
        self.marketDataSource = marketDataSource
        self.phoneAppearance = phoneAppearance
        self.buttonTheme = buttonTheme
        self.fontSize = fontSize
        self.smartRefreshEnabled = smartRefreshEnabled
        self.additionalClosedDates = additionalClosedDates
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case phoneRefreshSeconds, watchRefreshSeconds, colorConvention, widgetSymbol, marketDataSource, phoneAppearance, buttonTheme
        case fontSize, smartRefreshEnabled, additionalClosedDates
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        phoneRefreshSeconds = try values.decodeIfPresent(Int.self, forKey: .phoneRefreshSeconds) ?? 3
        watchRefreshSeconds = try values.decodeIfPresent(Int.self, forKey: .watchRefreshSeconds) ?? 5
        colorConvention = try values.decodeIfPresent(PriceColorConvention.self, forKey: .colorConvention) ?? .redUp
        widgetSymbol = try values.decodeIfPresent(String.self, forKey: .widgetSymbol)
        let source = try values.decodeIfPresent(String.self, forKey: .marketDataSource)
        marketDataSource = source.flatMap(MarketDataSource.init(rawValue:)) ?? .tencent
        let appearance = try values.decodeIfPresent(String.self, forKey: .phoneAppearance)
        phoneAppearance = appearance.flatMap(AppAppearance.init(rawValue:)) ?? .system
        let theme = try values.decodeIfPresent(String.self, forKey: .buttonTheme)
        buttonTheme = theme.flatMap(ButtonTheme.init(rawValue:)) ?? .teal
        let size = try values.decodeIfPresent(String.self, forKey: .fontSize)
        fontSize = size.flatMap(AppFontSize.init(rawValue:)) ?? .smaller
        smartRefreshEnabled = try values.decodeIfPresent(Bool.self, forKey: .smartRefreshEnabled) ?? true
        additionalClosedDates = try values.decodeIfPresent([String].self, forKey: .additionalClosedDates) ?? []
        normalize()
    }

    public mutating func normalize() {
        if !Self.refreshOptions.contains(phoneRefreshSeconds) { phoneRefreshSeconds = 3 }
        if !Self.refreshOptions.contains(watchRefreshSeconds) { watchRefreshSeconds = 5 }
        additionalClosedDates = TradingSchedule.normalizedClosedDates(additionalClosedDates)
    }
}

/// Separate versions let a Watch interval change coexist with an unsynced phone interval change.
public struct SettingsVersions: Codable, Equatable, Sendable {
    public var phoneRefreshSeconds: Date
    public var watchRefreshSeconds: Date
    public var colorConvention: Date
    public var widgetSymbol: Date
    public var marketDataSource: Date
    public var phoneAppearance: Date
    public var buttonTheme: Date
    public var fontSize: Date
    public var smartRefreshEnabled: Date
    public var additionalClosedDates: Date

    public init(date: Date = .distantPast) {
        phoneRefreshSeconds = date
        watchRefreshSeconds = date
        colorConvention = date
        widgetSymbol = date
        marketDataSource = date
        phoneAppearance = date
        buttonTheme = date
        fontSize = date
        smartRefreshEnabled = date
        additionalClosedDates = date
    }

    private enum CodingKeys: String, CodingKey {
        case phoneRefreshSeconds, watchRefreshSeconds, colorConvention, widgetSymbol, marketDataSource, phoneAppearance, buttonTheme
        case fontSize, smartRefreshEnabled, additionalClosedDates
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        phoneRefreshSeconds = try values.decodeIfPresent(Date.self, forKey: .phoneRefreshSeconds) ?? .distantPast
        watchRefreshSeconds = try values.decodeIfPresent(Date.self, forKey: .watchRefreshSeconds) ?? .distantPast
        colorConvention = try values.decodeIfPresent(Date.self, forKey: .colorConvention) ?? .distantPast
        widgetSymbol = try values.decodeIfPresent(Date.self, forKey: .widgetSymbol) ?? .distantPast
        marketDataSource = try values.decodeIfPresent(Date.self, forKey: .marketDataSource) ?? .distantPast
        phoneAppearance = try values.decodeIfPresent(Date.self, forKey: .phoneAppearance) ?? .distantPast
        buttonTheme = try values.decodeIfPresent(Date.self, forKey: .buttonTheme) ?? .distantPast
        fontSize = try values.decodeIfPresent(Date.self, forKey: .fontSize) ?? .distantPast
        smartRefreshEnabled = try values.decodeIfPresent(Date.self, forKey: .smartRefreshEnabled) ?? .distantPast
        additionalClosedDates = try values.decodeIfPresent(Date.self, forKey: .additionalClosedDates) ?? .distantPast
    }

    public var latest: Date {
        max(phoneRefreshSeconds, watchRefreshSeconds, colorConvention, widgetSymbol, marketDataSource, phoneAppearance,
            buttonTheme, fontSize, smartRefreshEnabled, additionalClosedDates)
    }

    public mutating func recordChanges(from old: AppSettings, to new: AppSettings, at date: Date) {
        if old.phoneRefreshSeconds != new.phoneRefreshSeconds { phoneRefreshSeconds = date }
        if old.watchRefreshSeconds != new.watchRefreshSeconds { watchRefreshSeconds = date }
        if old.colorConvention != new.colorConvention { colorConvention = date }
        if old.widgetSymbol != new.widgetSymbol { widgetSymbol = date }
        if old.marketDataSource != new.marketDataSource { marketDataSource = date }
        if old.phoneAppearance != new.phoneAppearance { phoneAppearance = date }
        if old.buttonTheme != new.buttonTheme { buttonTheme = date }
        if old.fontSize != new.fontSize { fontSize = date }
        if old.smartRefreshEnabled != new.smartRefreshEnabled { smartRefreshEnabled = date }
        if old.additionalClosedDates != new.additionalClosedDates { additionalClosedDates = date }
    }

    public mutating func merge(local: inout AppSettings, incoming: AppSettings, versions: SettingsVersions) {
        if versions.phoneRefreshSeconds > phoneRefreshSeconds {
            local.phoneRefreshSeconds = incoming.phoneRefreshSeconds
            phoneRefreshSeconds = versions.phoneRefreshSeconds
        }
        if versions.watchRefreshSeconds > watchRefreshSeconds {
            local.watchRefreshSeconds = incoming.watchRefreshSeconds
            watchRefreshSeconds = versions.watchRefreshSeconds
        }
        if versions.colorConvention > colorConvention {
            local.colorConvention = incoming.colorConvention
            colorConvention = versions.colorConvention
        }
        if versions.widgetSymbol > widgetSymbol {
            local.widgetSymbol = incoming.widgetSymbol
            widgetSymbol = versions.widgetSymbol
        }
        if versions.marketDataSource > marketDataSource {
            local.marketDataSource = incoming.marketDataSource
            marketDataSource = versions.marketDataSource
        }
        if versions.phoneAppearance > phoneAppearance {
            local.phoneAppearance = incoming.phoneAppearance
            phoneAppearance = versions.phoneAppearance
        }
        if versions.buttonTheme > buttonTheme {
            local.buttonTheme = incoming.buttonTheme
            buttonTheme = versions.buttonTheme
        }
        if versions.fontSize > fontSize {
            local.fontSize = incoming.fontSize
            fontSize = versions.fontSize
        }
        if versions.smartRefreshEnabled > smartRefreshEnabled {
            local.smartRefreshEnabled = incoming.smartRefreshEnabled
            smartRefreshEnabled = versions.smartRefreshEnabled
        }
        if versions.additionalClosedDates > additionalClosedDates {
            local.additionalClosedDates = incoming.additionalClosedDates
            additionalClosedDates = versions.additionalClosedDates
        }
        local.normalize()
    }
}

public enum QuoteMerge {
    public static func shouldReplace(_ current: Quote?, with incoming: Quote,
                                     preferredSource: MarketDataSource? = nil) -> Bool {
        guard let current else { return true }
        if let preferredSource {
            let currentMatches = current.source == preferredSource
            let incomingMatches = incoming.source == preferredSource
            // Different providers can report different source times. Once a
            // user switches, prefer that provider's valid quote over old-source
            // cache without relabeling or letting the cache overwrite it again.
            if currentMatches != incomingMatches { return incomingMatches }
        }
        return incoming.timestamp > current.timestamp ||
            (incoming.timestamp == current.timestamp && incoming.fetchedAt > current.fetchedAt)
    }
}

public enum RefreshPolicy {
    /// Failed requests back off instead of retrying a failing public service every second.
    public static func delay(interval: Int, failures: Int) -> TimeInterval {
        let base = AppSettings.refreshOptions.contains(interval) ? interval : 5
        guard failures > 0 else { return TimeInterval(base) }
        return min(60, max(TimeInterval(base), pow(2, Double(min(failures, 6)))))
    }
}
