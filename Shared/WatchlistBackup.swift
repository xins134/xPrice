import Foundation

public enum BackupImportMode: String, CaseIterable, Sendable {
    case merge, replace

    public var displayName: String {
        self == .merge ? "合并到现有列表" : "替换现有列表"
    }
}

public enum WatchlistBackupError: Error, LocalizedError, Equatable {
    case oversized
    case invalidFormat
    case unsupportedVersion(Int)
    case invalidInstrument(String)
    case tooManyInstruments(String)

    public var errorDescription: String? {
        switch self {
        case .oversized: "备份文件不能超过 1 MB。"
        case .invalidFormat: "无法读取这份备份，请选择由 xPrice 导出的 JSON 文件。"
        case .unsupportedVersion(let version): "暂不支持版本 \(version) 的备份，请更新 xPrice 后重试。"
        case .invalidInstrument(let symbol): "备份中的证券信息无效：\(symbol)。请检查代码、名称和类型。"
        case .tooManyInstruments(let list): "\(list)不能超过 50 只。请减少条目后再导入；现有列表尚未改变。"
        }
    }
}

/// A portable user document: never includes quotes, sync clocks or account data.
public struct WatchlistBackup: Codable, Sendable {
    public static let formatIdentifier = "xprice.watchlist-backup"
    public static let currentVersion = 1
    public static let maximumBytes = 1_000_000

    public let format: String
    public let version: Int
    public let exportedAt: Date
    public let watchlist: [Instrument]
    public let overviewInstruments: [Instrument]
    public let settings: AppSettings

    public init(watchlist: [Instrument], overviewInstruments: [Instrument] = [],
                settings: AppSettings, exportedAt: Date = .now) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.watchlist = watchlist
        self.overviewInstruments = overviewInstruments
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, watchlist, overviewInstruments, settings
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        version = try values.decode(Int.self, forKey: .version)
        guard format == Self.formatIdentifier else { throw WatchlistBackupError.invalidFormat }
        guard version == Self.currentVersion else { throw WatchlistBackupError.unsupportedVersion(version) }
        exportedAt = try values.decode(Date.self, forKey: .exportedAt)
        watchlist = try values.decode([Instrument].self, forKey: .watchlist)
        overviewInstruments = try values.decode([Instrument].self, forKey: .overviewInstruments)
        settings = try values.decode(BackupSettings.self, forKey: .settings).value
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(format, forKey: .format)
        try values.encode(version, forKey: .version)
        try values.encode(exportedAt, forKey: .exportedAt)
        try values.encode(watchlist, forKey: .watchlist)
        try values.encode(overviewInstruments, forKey: .overviewInstruments)
        try values.encode(settings, forKey: .settings)
    }

    public static func decode(_ data: Data) throws -> WatchlistBackup {
        guard data.count <= maximumBytes else { throw WatchlistBackupError.oversized }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: value) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                guard let date = formatter.date(from: value) else { throw WatchlistBackupError.invalidFormat }
                return date
            }
            return try decoder.decode(Self.self, from: data).validated()
        } catch let error as WatchlistBackupError {
            throw error
        } catch {
            throw WatchlistBackupError.invalidFormat
        }
    }

    public func encode() throws -> Data {
        let backup = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        let data = try encoder.encode(backup)
        guard data.count <= Self.maximumBytes else { throw WatchlistBackupError.oversized }
        return data
    }

    /// Preview is the same pure calculation as apply; neither persists changes.
    public func preview(to snapshot: CacheSnapshot, mode: BackupImportMode = .merge,
                        includeSettings: Bool = false, date: Date = .now) throws -> CacheSnapshot {
        try apply(to: snapshot, mode: mode, includeSettings: includeSettings, date: date)
    }

    public func apply(to snapshot: CacheSnapshot, mode: BackupImportMode = .merge,
                      includeSettings: Bool = false, date: Date = .now) throws -> CacheSnapshot {
        let backup = try validated()
        var result = snapshot
        if mode == .replace {
            result.watchlist = backup.watchlist
            result.overviewInstruments = backup.overviewInstruments
        } else {
            let localWatchlist = try Self.validatedList(snapshot.watchlist, label: "现有自选")
            let localOverview = try Self.validatedList(snapshot.overviewInstruments, label: "现有行情栏")
            let localBySymbol = Dictionary((localWatchlist + localOverview).map { ($0.symbol, $0) },
                                           uniquingKeysWith: { first, _ in first })
            result.watchlist = try Self.merged(localWatchlist, with: backup.watchlist,
                                             localBySymbol: localBySymbol, label: "合并后的自选")
            result.overviewInstruments = try Self.merged(localOverview, with: backup.overviewInstruments,
                                                       localBySymbol: localBySymbol, label: "合并后的行情栏")
        }

        let previousSettings = result.settings
        if includeSettings { result.settings = backup.settings }
        result.settings.normalize()
        if !result.watchlist.contains(where: { $0.symbol == result.settings.widgetSymbol }) {
            result.settings.widgetSymbol = result.watchlist.first?.symbol
        }
        // A local clock adjustment must not give this edit an older sync version.
        let latest = max(snapshot.watchlistUpdatedAt, snapshot.settingsVersions.latest)
        let changedAt = date > latest ? date : latest.addingTimeInterval(0.001)
        if result.watchlist != snapshot.watchlist { result.watchlistUpdatedAt = changedAt }
        result.settingsVersions.recordChanges(from: previousSettings, to: result.settings, at: changedAt)
        result.settingsUpdatedAt = max(snapshot.settingsUpdatedAt, result.settingsVersions.latest)
        result.modifiedAt = max(snapshot.modifiedAt, changedAt)
        let allowed = Set((result.watchlist + result.overviewInstruments).map(\.symbol))
        result.quotes = result.quotes.filter { allowed.contains($0.key) && $0.key == $0.value.symbol }
        return result
    }

    private func validated() throws -> WatchlistBackup {
        guard format == Self.formatIdentifier, exportedAt.timeIntervalSince1970.isFinite else {
            throw WatchlistBackupError.invalidFormat
        }
        guard version == Self.currentVersion else { throw WatchlistBackupError.unsupportedVersion(version) }
        let watchlist = try Self.validatedList(watchlist, label: "备份中的自选")
        let overview = try Self.validatedList(overviewInstruments, label: "备份中的行情栏")
        var settings = settings
        settings.normalize()
        if let symbol = settings.widgetSymbol, TencentMarketDataProvider.kind(for: symbol) == nil {
            settings.widgetSymbol = nil
        }
        return WatchlistBackup(watchlist: watchlist, overviewInstruments: overview,
                               settings: settings, exportedAt: exportedAt)
    }

    private static func validatedList(_ instruments: [Instrument], label: String) throws -> [Instrument] {
        guard instruments.count <= 50 else { throw WatchlistBackupError.tooManyInstruments(label) }
        var seen = Set<String>()
        var result: [Instrument] = []
        for raw in instruments {
            let instrument = Instrument(symbol: raw.symbol, name: raw.name, kind: raw.kind)
            guard !instrument.name.isEmpty, instrument.name.count <= 128,
                  instrument.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  let expected = TencentMarketDataProvider.kind(for: instrument.symbol, name: instrument.name),
                  instrument.kind == expected ||
                    (instrument.kind == .fund && [.fund, .etf, .lof].contains(expected)) else {
                throw WatchlistBackupError.invalidInstrument(String(raw.symbol.prefix(32)))
            }
            guard seen.insert(instrument.symbol).inserted else { continue }
            result.append(instrument)
        }
        return result
    }

    private static func merged(_ local: [Instrument], with incoming: [Instrument],
                               localBySymbol: [String: Instrument], label: String) throws -> [Instrument] {
        var result = local
        var seen = Set(local.map(\.symbol))
        for instrument in incoming where seen.insert(instrument.symbol).inserted {
            result.append(localBySymbol[instrument.symbol] ?? instrument)
        }
        guard result.count <= 50 else { throw WatchlistBackupError.tooManyInstruments(label) }
        return result
    }

    /// Unknown optional preferences use today's defaults; malformed field types
    /// still fail decoding so a damaged document cannot silently reset settings.
    private struct BackupSettings: Decodable {
        let value: AppSettings
        private enum CodingKeys: String, CodingKey {
            case phoneRefreshSeconds, watchRefreshSeconds, colorConvention, widgetSymbol
            case marketDataSource, phoneAppearance, buttonTheme
            case smartRefreshEnabled, additionalClosedDates
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) throws -> String? { try fields.decodeIfPresent(String.self, forKey: key) }
            value = try AppSettings(
                phoneRefreshSeconds: fields.decodeIfPresent(Int.self, forKey: .phoneRefreshSeconds) ?? 3,
                watchRefreshSeconds: fields.decodeIfPresent(Int.self, forKey: .watchRefreshSeconds) ?? 5,
                colorConvention: text(.colorConvention).flatMap(PriceColorConvention.init(rawValue:)) ?? .redUp,
                widgetSymbol: text(.widgetSymbol),
                marketDataSource: text(.marketDataSource).flatMap(MarketDataSource.init(rawValue:)) ?? .tencent,
                phoneAppearance: text(.phoneAppearance).flatMap(AppAppearance.init(rawValue:)) ?? .system,
                buttonTheme: text(.buttonTheme).flatMap(ButtonTheme.init(rawValue:)) ?? .teal,
                smartRefreshEnabled: fields.decodeIfPresent(Bool.self, forKey: .smartRefreshEnabled) ?? true,
                additionalClosedDates: fields.decodeIfPresent([String].self, forKey: .additionalClosedDates) ?? []
            )
        }
    }
}
