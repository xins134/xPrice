import Foundation

public struct SyncConfirmation: Codable, Equatable, Sendable {
    public let deliveryID: UUID
    public let persistedAt: Date
    public let watchlistUpdatedAt: Date
    public let settingsVersions: SettingsVersions
    public let watchlistCount: Int

    public init(deliveryID: UUID, persistedAt: Date, snapshot: CacheSnapshot) {
        self.deliveryID = deliveryID
        self.persistedAt = persistedAt
        self.watchlistUpdatedAt = snapshot.watchlistUpdatedAt
        self.settingsVersions = snapshot.settingsVersions
        self.watchlistCount = snapshot.watchlist.count
    }
}

/// An old acknowledgement must not mark more recent edits as synchronized.
public struct SyncConfirmationTracker {
    private var pendingID: UUID?
    private var watchlistVersion = Date.distantPast
    private var settingsVersions = SettingsVersions()
    public private(set) var confirmation: SyncConfirmation?

    public init() {}

    public var isConfirmed: Bool { pendingID != nil && confirmation?.deliveryID == pendingID }

    public mutating func sent(id: UUID, snapshot: CacheSnapshot) {
        pendingID = id
        watchlistVersion = snapshot.watchlistUpdatedAt
        settingsVersions = snapshot.settingsVersions
    }

    @discardableResult
    public mutating func receive(_ incoming: SyncConfirmation) -> Bool {
        let versions = incoming.settingsVersions
        guard incoming.deliveryID == pendingID,
              (0...50).contains(incoming.watchlistCount),
              incoming.watchlistUpdatedAt >= watchlistVersion,
              versions.phoneRefreshSeconds >= settingsVersions.phoneRefreshSeconds,
              versions.watchRefreshSeconds >= settingsVersions.watchRefreshSeconds,
              versions.colorConvention >= settingsVersions.colorConvention,
              versions.widgetSymbol >= settingsVersions.widgetSymbol,
              versions.marketDataSource >= settingsVersions.marketDataSource,
              versions.phoneAppearance >= settingsVersions.phoneAppearance,
              versions.buttonTheme >= settingsVersions.buttonTheme,
              versions.fontSize >= settingsVersions.fontSize,
              versions.smartRefreshEnabled >= settingsVersions.smartRefreshEnabled,
              versions.additionalClosedDates >= settingsVersions.additionalClosedDates else { return false }
        confirmation = incoming
        return true
    }
}
