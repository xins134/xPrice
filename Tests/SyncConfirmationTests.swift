import Foundation
import Testing
@testable import XPriceCore

struct SyncConfirmationTests {
    @Test func olderDeliveryDoesNotConfirmNewerEdits() throws {
        let snapshot = CacheSnapshot(watchlist: [], quotes: [:], settings: AppSettings(),
                                     modifiedAt: Date(timeIntervalSince1970: 100))
        let oldID = UUID()
        let newID = UUID()
        var tracker = SyncConfirmationTracker()
        tracker.sent(id: oldID, snapshot: snapshot)
        tracker.sent(id: newID, snapshot: snapshot)
        let acceptedOld = tracker.receive(SyncConfirmation(deliveryID: oldID, persistedAt: .now, snapshot: snapshot))
        #expect(!acceptedOld)
        #expect(!tracker.isConfirmed)
        let confirmation = SyncConfirmation(deliveryID: newID, persistedAt: .now, snapshot: snapshot)
        let decoded = try JSONDecoder().decode(SyncConfirmation.self, from: JSONEncoder().encode(confirmation))
        let acceptedNew = tracker.receive(decoded)
        #expect(acceptedNew)
        #expect(tracker.isConfirmed)
    }

    @Test func receiverMustHaveSavedAllPendingSettingVersions() {
        var sent = CacheSnapshot(watchlist: [], quotes: [:], settings: AppSettings())
        sent.settingsVersions.buttonTheme = Date(timeIntervalSince1970: 300)
        let id = UUID()
        var tracker = SyncConfirmationTracker()
        tracker.sent(id: id, snapshot: sent)
        let stale = CacheSnapshot(watchlist: [], quotes: [:], settings: AppSettings())
        let acceptedStale = tracker.receive(SyncConfirmation(deliveryID: id, persistedAt: .now, snapshot: stale))
        #expect(!acceptedStale)
        let acceptedSaved = tracker.receive(SyncConfirmation(deliveryID: id, persistedAt: .now, snapshot: sent))
        #expect(acceptedSaved)
    }
}
