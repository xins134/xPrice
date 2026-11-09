import Foundation

/// A phone-local selection. It is intentionally separate from synced settings and backups.
public struct ScreenOffSelection: Equatable, Sendable {
    public static let defaultsKey = "xprice.screenOffSelection.v1"

    public private(set) var symbols: [String]

    public init(symbols: [String] = [], watchlist: [Instrument]) {
        let selected = Set(symbols)
        var seen = Set<String>()
        self.symbols = watchlist
            .filter { selected.contains($0.symbol) && seen.insert($0.symbol).inserted }
            .map(\.symbol)
    }

    public func instruments(in watchlist: [Instrument]) -> [Instrument] {
        let selected = Set(symbols)
        var seen = Set<String>()
        return watchlist.filter { selected.contains($0.symbol) && seen.insert($0.symbol).inserted }
    }

    public func contains(_ instrument: Instrument) -> Bool {
        symbols.contains(instrument.symbol)
    }

    public mutating func reconcile(with watchlist: [Instrument]) {
        self = Self(symbols: symbols, watchlist: watchlist)
    }

    @discardableResult
    public mutating func setSelected(_ selected: Bool, for instrument: Instrument,
                                    watchlist: [Instrument]) -> Bool {
        reconcile(with: watchlist)
        guard watchlist.contains(where: { $0.symbol == instrument.symbol }) else { return false }
        if selected {
            guard !contains(instrument) else { return true }
            symbols.append(instrument.symbol)
            reconcile(with: watchlist)
        } else {
            symbols.removeAll { $0 == instrument.symbol }
        }
        return true
    }

    public static func load(from defaults: UserDefaults, watchlist: [Instrument]) -> Self {
        Self(symbols: defaults.stringArray(forKey: defaultsKey) ?? [], watchlist: watchlist)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(symbols, forKey: Self.defaultsKey)
    }
}
