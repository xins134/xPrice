import Foundation
import Combine
import WidgetKit

@MainActor
final class AppStore: ObservableObject {
    enum Platform { case phone, watch }

    @Published private(set) var watchlist: [Instrument]
    @Published private(set) var overviewInstruments: [Instrument]
    @Published private(set) var quotes: [String: Quote]
    @Published private(set) var settings: AppSettings
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var syncStatus = "等待连接"
    @Published private(set) var lastSyncConfirmedAt: Date?
    @Published private(set) var confirmedWatchlistCount: Int?
    @Published private(set) var quoteFailures: Set<String> = []
    @Published private(set) var tradingSession = TradingSchedule.session(at: .now)
    @Published private var screenOffSelection = ScreenOffSelection(watchlist: [])

    private let platform: Platform
    private let injectedProvider: (any MarketDataProviding)?
    private var bridge: WatchSyncBridge?
    private var watchlistUpdatedAt: Date
    private var settingsUpdatedAt: Date
    private var settingsVersions: SettingsVersions
    private var isActive = false
    private var isScreenOffRefreshPaused = false
    private var failureCount = 0
    private var loopTask: Task<Void, Never>?
    private let refreshCoordinator = QuoteRefreshCoordinator()
    private var refreshGeneration = UUID()
    private var sourceRevision = UUID()
    private var lastWidgetReload = Date.distantPast

    var refreshSeconds: Int { platform == .phone ? settings.phoneRefreshSeconds : settings.watchRefreshSeconds }
    var effectiveRefreshSeconds: Int {
        Int(tradingSession.autoRefreshDelay(interval: refreshSeconds, failures: failureCount,
                                            smartEnabled: settings.smartRefreshEnabled))
    }
    private var provider: any MarketDataProviding {
        injectedProvider ?? MarketDataProviders.make(source: settings.marketDataSource)
    }
    var widgetInstrument: Instrument? {
        watchlist.first { $0.symbol == settings.widgetSymbol } ?? watchlist.first
    }
    var screenOffInstruments: [Instrument] { screenOffSelection.instruments(in: watchlist) }

    private var canRefresh: Bool { isActive && !isScreenOffRefreshPaused }

    private var quoteInstruments: [Instrument] {
        var seen = Set<String>()
        return (watchlist + overviewInstruments).filter { seen.insert($0.symbol).inserted }
    }

    init(platform: Platform, provider: (any MarketDataProviding)? = nil) {
        self.platform = platform
        self.injectedProvider = provider
        let cached = SnapshotStore.load()
        watchlist = cached?.watchlist ?? []
        overviewInstruments = platform == .phone ? cached?.overviewInstruments ?? [] : []
        quotes = cached?.quotes ?? [:]
        settings = cached?.settings ?? AppSettings()
        watchlistUpdatedAt = cached?.watchlistUpdatedAt ?? .distantPast
        settingsUpdatedAt = cached?.settingsUpdatedAt ?? .distantPast
        settingsVersions = cached?.settingsVersions ?? SettingsVersions()
        if platform == .phone {
            screenOffSelection = ScreenOffSelection.load(from: .standard, watchlist: watchlist)
            screenOffSelection.save(to: .standard)
        }
        tradingSession = TradingSchedule.session(at: .now, additionalClosedDates: settings.additionalClosedDates)
        if let data = UserDefaults.standard.data(forKey: "xprice.lastSyncConfirmation.v1"),
           let confirmation = try? JSONDecoder().decode(SyncConfirmation.self, from: data) {
            lastSyncConfirmedAt = confirmation.persistedAt
            confirmedWatchlistCount = confirmation.watchlistCount
        }
        let bridge = WatchSyncBridge()
        self.bridge = bridge
        bridge.onReceive = { [weak self] in self?.receive($0) }
        bridge.onReady = { [weak self] in self?.sync() }
        bridge.onStatus = { [weak self] in self?.syncStatus = $0 }
        bridge.onConfirmation = { [weak self] confirmation in
            guard let self else { return }
            self.lastSyncConfirmedAt = confirmation.persistedAt
            self.confirmedWatchlistCount = confirmation.watchlistCount
            self.syncStatus = self.platform == .phone ? "手表已确认接收" : "iPhone 已确认接收"
            if let data = try? JSONEncoder().encode(confirmation) {
                UserDefaults.standard.set(data, forKey: "xprice.lastSyncConfirmation.v1")
            }
        }
    }

    deinit { loopTask?.cancel() }

    func quote(for instrument: Instrument) -> Quote? { quotes[instrument.symbol] }

    func isScreenOffSelected(_ instrument: Instrument) -> Bool {
        platform == .phone && screenOffSelection.contains(instrument)
    }

    @discardableResult
    func setScreenOffSelected(_ selected: Bool, for instrument: Instrument) -> Bool {
        guard platform == .phone else { return false }
        var updated = screenOffSelection
        guard updated.setSelected(selected, for: instrument, watchlist: watchlist) else { return false }
        if updated != screenOffSelection { screenOffSelection = updated }
        updated.save(to: .standard)
        return true
    }

    private func reconcileScreenOffSelection() {
        guard platform == .phone else { return }
        var updated = screenOffSelection
        updated.reconcile(with: watchlist)
        guard updated != screenOffSelection else { return }
        screenOffSelection = updated
        updated.save(to: .standard)
    }

    func setScreenOffRefreshPaused(_ paused: Bool) {
        guard platform == .phone, paused != isScreenOffRefreshPaused else { return }
        isScreenOffRefreshPaused = paused
        if paused {
            loopTask?.cancel()
            loopTask = nil
            cancelRefresh()
        } else if isActive {
            restartLoop()
        }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            if let cached = SnapshotStore.load() {
                for instrument in quoteInstruments where cached.hasSameMarketDataSelection(as: snapshot) {
                    if let quote = cached.quotes[instrument.symbol],
                       QuoteMerge.shouldReplace(quotes[instrument.symbol], with: quote, preferredSource: settings.marketDataSource) {
                        quotes[instrument.symbol] = quote
                    }
                }
            }
            sync()
            restartLoop()
        } else {
            loopTask?.cancel()
            loopTask = nil
            cancelRefresh()
        }
    }

    func search(_ query: String) async throws -> [Instrument] {
        let revision = sourceRevision
        let results = try await provider.search(query)
        try Task.checkCancellation()
        guard sourceRevision == revision else { throw CancellationError() }
        return results
    }

    @discardableResult
    func add(_ instrument: Instrument) -> Bool {
        guard platform == .phone, !watchlist.contains(where: { $0.symbol == instrument.symbol }) else { return false }
        guard watchlist.count < 50 else { errorMessage = "首版最多添加 50 只自选"; return false }
        watchlist.append(instrument)
        reconcileScreenOffSelection()
        watchlistUpdatedAt = nextEditDate()
        if settings.widgetSymbol == nil {
            settings.widgetSymbol = instrument.symbol
            settingsUpdatedAt = nextEditDate()
            settingsVersions.widgetSymbol = settingsUpdatedAt
        }
        persist(sync: true, reloadWidget: true)
        if isActive { restartLoop() }
        return true
    }

    func remove(_ instrument: Instrument) {
        guard platform == .phone else { return }
        watchlist.removeAll { $0.symbol == instrument.symbol }
        reconcileScreenOffSelection()
        if !overviewInstruments.contains(where: { $0.symbol == instrument.symbol }) {
            quotes.removeValue(forKey: instrument.symbol)
        }
        watchlistUpdatedAt = nextEditDate()
        if settings.widgetSymbol == instrument.symbol {
            settings.widgetSymbol = watchlist.first?.symbol
            settingsUpdatedAt = nextEditDate()
            settingsVersions.widgetSymbol = settingsUpdatedAt
        }
        if quoteInstruments.isEmpty { errorMessage = nil }
        persist(sync: true, reloadWidget: true)
    }

    @discardableResult
    func addToOverview(_ instrument: Instrument) -> Bool {
        guard platform == .phone,
              !overviewInstruments.contains(where: { $0.symbol == instrument.symbol }) else { return false }
        guard overviewInstruments.count < 50 else { errorMessage = "行情栏最多添加 50 只证券"; return false }
        overviewInstruments.append(instrument)
        persist()
        if isActive { restartLoop() }
        return true
    }

    func removeFromOverview(_ instrument: Instrument) {
        guard platform == .phone else { return }
        overviewInstruments.removeAll { $0.symbol == instrument.symbol }
        if !watchlist.contains(where: { $0.symbol == instrument.symbol }) {
            quotes.removeValue(forKey: instrument.symbol)
        }
        if quoteInstruments.isEmpty { errorMessage = nil }
        persist()
    }

    func moveOverview(from offsets: IndexSet, to destination: Int) {
        guard platform == .phone else { return }
        let validOffsets = offsets.filter { overviewInstruments.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }
        let moving = validOffsets.sorted().map { overviewInstruments[$0] }
        let adjusted = destination - validOffsets.filter { $0 < destination }.count
        for index in validOffsets.sorted(by: >) { overviewInstruments.remove(at: index) }
        overviewInstruments.insert(contentsOf: moving, at: max(0, min(adjusted, overviewInstruments.count)))
        persist()
    }

    func moveOverview(_ instrument: Instrument, by distance: Int) {
        guard let index = overviewInstruments.firstIndex(where: { $0.symbol == instrument.symbol }) else { return }
        let target = max(0, min(overviewInstruments.count - 1, index + distance))
        guard target != index else { return }
        moveOverview(from: IndexSet(integer: index), to: target > index ? target + 1 : target)
    }

    func move(from offsets: IndexSet, to destination: Int) {
        guard platform == .phone else { return }
        let moving = offsets.sorted().map { watchlist[$0] }
        let adjusted = destination - offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) { watchlist.remove(at: index) }
        watchlist.insert(contentsOf: moving, at: max(0, min(adjusted, watchlist.count)))
        reconcileScreenOffSelection()
        watchlistUpdatedAt = nextEditDate()
        persist(sync: true)
    }

    func move(_ instrument: Instrument, by distance: Int) {
        guard let index = watchlist.firstIndex(of: instrument) else { return }
        let target = max(0, min(watchlist.count - 1, index + distance))
        guard target != index else { return }
        move(from: IndexSet(integer: index), to: target > index ? target + 1 : target)
    }

    func updateSettings(_ update: (inout AppSettings) -> Void) {
        let previousInterval = refreshSeconds
        let oldSettings = settings
        update(&settings)
        settings.normalize()
        updateTradingSession()
        settingsUpdatedAt = nextEditDate()
        settingsVersions.recordChanges(from: oldSettings, to: settings, at: settingsUpdatedAt)
        let sourceChanged = oldSettings.marketDataSource != settings.marketDataSource
        if sourceChanged { invalidateSourceRequests() }
        persist(sync: true, reloadWidget: true)
        if isActive, sourceChanged || previousInterval != refreshSeconds ||
            oldSettings.smartRefreshEnabled != settings.smartRefreshEnabled ||
            oldSettings.additionalClosedDates != settings.additionalClosedDates { restartLoop() }
    }

    func selectWidgetSymbol(_ symbol: String) {
        guard watchlist.contains(where: { $0.symbol == symbol }) else { return }
        updateSettings { $0.widgetSymbol = symbol }
    }

    func refresh() async {
        guard canRefresh, !refreshCoordinator.isRefreshing, !quoteInstruments.isEmpty else { return }
        isRefreshing = true
        let instruments = quoteInstruments
        let provider = provider
        let revision = sourceRevision
        let generation = refreshGeneration
        defer { isRefreshing = refreshCoordinator.isRefreshing }
        do {
            guard let fetched = try await refreshCoordinator.fetch(using: provider, instruments: instruments),
                  canRefresh, revision == sourceRevision, generation == refreshGeneration else { return }
            let allowed = Set(quoteInstruments.map(\.symbol))
            var received = Set<String>()
            for quote in fetched where allowed.contains(quote.symbol) {
                received.insert(quote.symbol)
                guard QuoteMerge.shouldReplace(quotes[quote.symbol], with: quote, preferredSource: settings.marketDataSource) else { continue }
                quotes[quote.symbol] = quote
            }
            let missing = Set(instruments.map(\.symbol)).intersection(allowed).subtracting(received).count
            quoteFailures.subtract(received)
            quoteFailures.formUnion(Set(instruments.map(\.symbol)).intersection(allowed).subtracting(received))
            if missing > 0 {
                errorMessage = "\(missing) 只证券暂未返回有效行情，保留最近报价"
                failureCount += 1
            } else {
                errorMessage = nil
                failureCount = 0
            }
            lastRefreshAt = Date()
            persist()
            if Date().timeIntervalSince(lastWidgetReload) >= 300 { reloadWidgets() }
        } catch {
            guard canRefresh, revision == sourceRevision, generation == refreshGeneration,
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            quoteFailures.formUnion(instruments.map(\.symbol))
            failureCount += 1
            errorMessage = error.localizedDescription
        }
    }

    private func invalidateSourceRequests() {
        sourceRevision = UUID()
        cancelRefresh()
        failureCount = 0
        errorMessage = nil
        quoteFailures = []
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = nil
        cancelRefresh()
        guard canRefresh else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.canRefresh else { return }
                self.updateTradingSession()
                let started = Date()
                await self.refresh()
                guard !Task.isCancelled, self.canRefresh else { return }
                self.updateTradingSession()
                let now = Date()
                let session = TradingSchedule.session(at: now, additionalClosedDates: self.settings.additionalClosedDates)
                let delay = session.autoRefreshDelay(interval: self.refreshSeconds, failures: self.failureCount,
                                                      smartEnabled: self.settings.smartRefreshEnabled)
                let remaining = max(0.1, delay - Date().timeIntervalSince(started))
                let boundary = TradingSchedule.nextTransition(after: now, additionalClosedDates: self.settings.additionalClosedDates)
                let sleep = self.settings.smartRefreshEnabled
                    ? min(remaining, max(0.1, boundary.timeIntervalSinceNow)) : remaining
                do { try await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    private func cancelRefresh() {
        refreshCoordinator.cancel()
        refreshGeneration = UUID()
        isRefreshing = false
    }

    private func updateTradingSession() {
        tradingSession = TradingSchedule.session(at: .now, additionalClosedDates: settings.additionalClosedDates)
    }

    private var snapshot: CacheSnapshot {
        CacheSnapshot(watchlist: watchlist, quotes: quotes, settings: settings,
                      modifiedAt: max(watchlistUpdatedAt, settingsUpdatedAt),
                      watchlistUpdatedAt: watchlistUpdatedAt, settingsUpdatedAt: settingsUpdatedAt,
                      settingsVersions: settingsVersions, overviewInstruments: overviewInstruments)
    }

    @discardableResult
    private func persist(sync shouldSync: Bool = false, reloadWidget: Bool = false) -> Bool {
        guard SnapshotStore.saveConfirmed(snapshot) else {
            errorMessage = "本机保存失败，请重试"
            return false
        }
        if shouldSync { sync() }
        if reloadWidget { reloadWidgets() }
        return true
    }

    private func sync(force: Bool = false) {
        var synced = snapshot
        synced.overviewInstruments = []
        let watchlistSymbols = Set(watchlist.map(\.symbol))
        synced.quotes = synced.quotes.filter { watchlistSymbols.contains($0.key) }
        bridge?.send(synced, force: force)
    }

    func retrySync() { sync(force: true) }

    func exportBackup() -> WatchlistBackup {
        WatchlistBackup(watchlist: watchlist, overviewInstruments: overviewInstruments, settings: settings)
    }

    func importBackup(_ backup: WatchlistBackup, mode: BackupImportMode, includeSettings: Bool) throws {
        guard platform == .phone else { throw WatchlistBackupError.invalidFormat }
        let oldSource = settings.marketDataSource
        let result = try backup.apply(to: snapshot, mode: mode, includeSettings: includeSettings, date: nextEditDate())
        guard SnapshotStore.saveConfirmed(result) else {
            throw CocoaError(.fileWriteUnknown)
        }
        watchlist = result.watchlist
        reconcileScreenOffSelection()
        overviewInstruments = result.overviewInstruments
        quotes = result.quotes
        settings = result.settings
        updateTradingSession()
        watchlistUpdatedAt = result.watchlistUpdatedAt
        settingsUpdatedAt = result.settingsUpdatedAt
        settingsVersions = result.settingsVersions
        if oldSource != settings.marketDataSource { invalidateSourceRequests() }
        quoteFailures = quoteFailures.intersection(Set(quoteInstruments.map(\.symbol)))
        errorMessage = nil
        sync(force: true)
        reloadWidgets()
        if isActive { restartLoop() }
    }

    private func nextEditDate() -> Date {
        let latest = max(watchlistUpdatedAt, settingsVersions.latest)
        let now = Date()
        return now > latest ? now : latest.addingTimeInterval(0.001)
    }

    private func reloadWidgets() {
        lastWidgetReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func receive(_ incoming: CacheSnapshot) -> CacheSnapshot? {
        let oldInterval = refreshSeconds
        let oldSettings = settings
        let oldSource = settings.marketDataSource
        let oldSymbols = watchlist.map(\.symbol)
        if platform == .watch, incoming.watchlistUpdatedAt >= watchlistUpdatedAt {
            var seen = Set<String>()
            watchlist = incoming.watchlist.filter { seen.insert($0.symbol).inserted }.prefix(50).map { $0 }
            watchlistUpdatedAt = incoming.watchlistUpdatedAt
        }
        settingsVersions.merge(local: &settings, incoming: incoming.settings, versions: incoming.settingsVersions)
        updateTradingSession()
        let sourceChanged = oldSource != settings.marketDataSource
        if sourceChanged { invalidateSourceRequests() }
        settingsUpdatedAt = settingsVersions.latest
        if !watchlist.contains(where: { $0.symbol == settings.widgetSymbol }) {
            settings.widgetSymbol = watchlist.first?.symbol
        }
        let allowed = Set(quoteInstruments.map(\.symbol))
        quotes = quotes.filter { allowed.contains($0.key) }
        if incoming.hasSameMarketDataSelection(as: snapshot) {
            for (symbol, quote) in incoming.quotes where allowed.contains(symbol) && symbol == quote.symbol {
                guard QuoteMerge.shouldReplace(quotes[symbol], with: quote, preferredSource: settings.marketDataSource) else { continue }
                quotes[symbol] = quote
            }
        }
        quoteFailures = quoteFailures.intersection(allowed)
        guard persist(reloadWidget: true) else { return nil }
        syncStatus = "收到的数据已保存"
        if isActive, sourceChanged || oldInterval != refreshSeconds || oldSymbols != watchlist.map(\.symbol) ||
            oldSettings.smartRefreshEnabled != settings.smartRefreshEnabled ||
            oldSettings.additionalClosedDates != settings.additionalClosedDates { restartLoop() }
        return snapshot
    }
}
