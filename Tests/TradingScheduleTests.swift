import Foundation
import Testing
@testable import XPriceCore

struct TradingScheduleTests {
    @Test(arguments: [
        ("2026-11-09T09:14:59+08:00", TradingSession.preMarket),
        ("2026-11-09T09:15:00+08:00", TradingSession.auction),
        ("2026-11-09T09:29:59+08:00", TradingSession.auction),
        ("2026-11-09T09:30:00+08:00", TradingSession.trading),
        ("2026-11-09T11:29:59+08:00", TradingSession.trading),
        ("2026-11-09T11:30:00+08:00", TradingSession.middayBreak),
        ("2026-11-09T12:59:59+08:00", TradingSession.middayBreak),
        ("2026-11-09T13:00:00+08:00", TradingSession.trading),
        ("2026-11-09T14:59:59+08:00", TradingSession.trading),
        ("2026-11-09T15:00:00+08:00", TradingSession.afterHours),
        ("2026-11-08T10:00:00+08:00", TradingSession.weekend)
    ])
    func usesBeijingTimeAndExactHalfOpenSessionBoundaries(stamp: String, expected: TradingSession) throws {
        #expect(TradingSchedule.session(at: try date(stamp)) == expected)
    }

    @Test func deviceTimezoneDoesNotChangeSessionAndSuppliedClosuresTakePrecedence() throws {
        let utc = try date("2026-11-09T01:15:00Z")
        #expect(TradingSchedule.session(at: utc) == .auction)
        #expect(TradingSchedule.dateString(for: utc) == "2026-11-09")
        #expect(TradingSchedule.session(at: utc, additionalClosedDates: ["2026-11-09"]) == .closedDay)
        #expect(TradingSchedule.coverage(at: utc, additionalClosedDates: ["2026-11-09"]) == .additionalClosedDate)
        #expect(TradingSchedule.coverageNotice(at: utc, additionalClosedDates: ["2026-11-09"]) == "今日为自定义休市日。")
        let saturday = try date("2026-11-07T10:00:00+08:00")
        #expect(TradingSchedule.session(at: saturday, additionalClosedDates: ["2026-11-07"]) == .closedDay)
    }

    @Test func smartModeKeepsConfiguredTradingIntervalsAndReducesOtherSessions() {
        for interval in AppSettings.refreshOptions {
            #expect(TradingSession.auction.autoRefreshDelay(interval: interval, failures: 0, smartEnabled: true) == Double(interval))
            #expect(TradingSession.trading.autoRefreshDelay(interval: interval, failures: 0, smartEnabled: true) == Double(interval))
            #expect(TradingSession.middayBreak.autoRefreshDelay(interval: interval, failures: 0, smartEnabled: true) == 60)
            for session in [TradingSession.preMarket, .afterHours, .weekend, .closedDay] {
                #expect(session.autoRefreshDelay(interval: interval, failures: 0, smartEnabled: true) == 300)
            }
            for session in TradingSession.allCases {
                #expect(session.autoRefreshDelay(interval: interval, failures: 0, smartEnabled: false) == Double(interval))
            }
        }
        #expect(TradingSession.trading.autoRefreshDelay(interval: 1, failures: 4, smartEnabled: true) == 16)
        #expect(TradingSession.middayBreak.autoRefreshDelay(interval: 1, failures: 9, smartEnabled: true) == 60)
        #expect(TradingSession.closedDay.autoRefreshDelay(interval: 1, failures: 9, smartEnabled: true) == 300)
        #expect(TradingSession.closedDay.autoRefreshDelay(interval: 1, failures: 4, smartEnabled: false) == 16)
        #expect(TradingSession.trading.isTrading)
        #expect(TradingSession.auction.isTrading)
        #expect(!TradingSession.middayBreak.isTrading)
    }

    @Test(arguments: [
        ("2026-11-09T09:14:59+08:00", "2026-11-09T09:15:00+08:00"),
        ("2026-11-09T09:15:00+08:00", "2026-11-09T09:30:00+08:00"),
        ("2026-11-09T11:29:59+08:00", "2026-11-09T11:30:00+08:00"),
        ("2026-11-09T12:59:59+08:00", "2026-11-09T13:00:00+08:00"),
        ("2026-11-09T13:00:00+08:00", "2026-11-09T15:00:00+08:00"),
        ("2026-11-09T15:00:00+08:00", "2026-11-10T00:00:00+08:00"),
        ("2026-11-08T10:00:00+08:00", "2026-11-09T00:00:00+08:00")
    ])
    func nextTransitionWakesExactlyAtTheNextSessionBoundary(from: String, to: String) throws {
        #expect(TradingSchedule.nextTransition(after: try date(from)) == (try date(to)))
    }

    @Test func nextTransitionSkipsAllDayClosureBoundariesWithoutInventingTradingDays() throws {
        let from = try date("2026-11-09T09:00:00+08:00")
        let dates = ["2026-11-09", "2026-11-10", "2026-11-11"]
        #expect(TradingSchedule.nextTransition(after: from, additionalClosedDates: dates) == (try date("2026-11-12T00:00:00+08:00")))
        #expect(TradingSchedule.nextTransition(after: try date("2026-11-06T15:01:00+08:00")) == (try date("2026-11-07T00:00:00+08:00")))
    }

    @Test func weekdaysUseTheChosenPolicyAndLeaveHolidayAdjustmentToSuppliedDates() throws {
        let date = try date("2040-01-02T10:00:00+08:00")
        #expect(TradingSchedule.coverage(at: date) == .weekdayInference(2040))
        #expect(TradingSchedule.coverageNotice(at: date) == "按周一至周五判断，法定节假日请补充休市日期。")
        #expect(TradingSchedule.coverage(at: date).displayName == "按工作日判断")
        #expect(TradingSchedule.coverage(at: date).isVerifiedCalendar == false)
        #expect(!TradingSchedule.verifiedYears.contains(2040))
        #expect(TradingSchedule.session(at: date) == .trading)
    }

    @Test func suppliedDatesAreValidatedNormalizedAndPreservedThroughConfirmedPersistence() throws {
        let dates = ["2026-11-11", " 2026-11-09\n", "2026-11-09", "2026-02-30", "2026-2-03", "not-a-date"]
        let settings = AppSettings(smartRefreshEnabled: false, additionalClosedDates: dates)
        #expect(settings.additionalClosedDates == ["2026-11-09", "2026-11-11"])
        #expect(TradingSchedule.isValidClosedDate("2028-02-29"))
        #expect(!TradingSchedule.isValidClosedDate("2026-02-29"))
        let suite = "xprice.schedule.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var versions = SettingsVersions()
        versions.smartRefreshEnabled = Date(timeIntervalSince1970: 100)
        versions.additionalClosedDates = Date(timeIntervalSince1970: 200)
        let snapshot = CacheSnapshot(watchlist: [], quotes: [:], settings: settings, settingsVersions: versions)
        #expect(SnapshotStore.saveConfirmed(snapshot, to: defaults))
        let restored = try #require(SnapshotStore.load(from: defaults))
        #expect(restored.settings == settings)
        #expect(restored.settingsVersions == versions)
    }

    @Test func smartRefreshAndClosedDatesMergeIndependentlyWithoutResettingOtherChoices() {
        let initial = AppSettings(buttonTheme: .purple)
        var phone = initial
        var phoneVersions = SettingsVersions()
        phone.smartRefreshEnabled = false
        phoneVersions.recordChanges(from: initial, to: phone, at: Date(timeIntervalSince1970: 100))
        var peer = initial
        var peerVersions = SettingsVersions()
        peer.additionalClosedDates = ["2026-11-09"]
        peerVersions.recordChanges(from: initial, to: peer, at: Date(timeIntervalSince1970: 200))
        phoneVersions.merge(local: &phone, incoming: peer, versions: peerVersions)
        peerVersions.merge(local: &peer, incoming: phone, versions: phoneVersions)
        #expect(phone == peer)
        #expect(!phone.smartRefreshEnabled)
        #expect(phone.additionalClosedDates == ["2026-11-09"])
        #expect(phone.buttonTheme == .purple)
        #expect(phoneVersions.latest == Date(timeIntervalSince1970: 200))
        #expect(phoneVersions.marketDataSource == .distantPast)
    }

    @Test(arguments: [false, true])
    func oldSnapshotsCannotOverwriteNewSmartRefreshOrClosedDateSettings(hasFieldVersions: Bool) throws {
        let original = CacheSnapshot(watchlist: [], quotes: [:], settings: AppSettings(),
                                     modifiedAt: Date(timeIntervalSince1970: 400))
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var oldSettings = try #require(legacy["settings"] as? [String: Any])
        oldSettings.removeValue(forKey: "smartRefreshEnabled")
        oldSettings.removeValue(forKey: "additionalClosedDates")
        legacy["settings"] = oldSettings
        if hasFieldVersions {
            var oldVersions = try #require(legacy["settingsVersions"] as? [String: Any])
            oldVersions.removeValue(forKey: "smartRefreshEnabled")
            oldVersions.removeValue(forKey: "additionalClosedDates")
            legacy["settingsVersions"] = oldVersions
        } else {
            legacy.removeValue(forKey: "settingsVersions")
        }
        let restored = try JSONDecoder().decode(CacheSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.settings.smartRefreshEnabled)
        #expect(restored.settings.additionalClosedDates.isEmpty)
        #expect(restored.settingsVersions.smartRefreshEnabled == .distantPast)
        #expect(restored.settingsVersions.additionalClosedDates == .distantPast)
        var local = AppSettings(smartRefreshEnabled: false, additionalClosedDates: ["2026-11-09"])
        var versions = SettingsVersions()
        versions.smartRefreshEnabled = Date(timeIntervalSince1970: 200)
        versions.additionalClosedDates = Date(timeIntervalSince1970: 200)
        versions.merge(local: &local, incoming: restored.settings, versions: restored.settingsVersions)
        #expect(!local.smartRefreshEnabled)
        #expect(local.additionalClosedDates == ["2026-11-09"])
    }

    private func date(_ stamp: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: stamp))
    }
}
