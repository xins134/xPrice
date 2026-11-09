import Foundation
import Testing
@testable import XPriceCore

private actor SuspendedQuoteProvider: MarketDataProviding {
    private var continuations: [CheckedContinuation<[Quote], Error>] = []
    private var starts: [CheckedContinuation<Void, Never>] = []

    func search(_ query: String) async throws -> [Instrument] { [] }
    func quotes(for instruments: [Instrument]) async throws -> [Quote] {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            let waiters = starts
            starts.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
    func waitForStart() async {
        if !continuations.isEmpty { return }
        await withCheckedContinuation { starts.append($0) }
    }
    func finish(_ result: Result<[Quote], Error>) {
        continuations.removeFirst().resume(with: result)
    }
}

struct RefreshCoordinatorTests {
    private let instrument = Instrument(symbol: "sh600519", name: "测试股票")

    @Test @MainActor func foregroundReentryStartsBeforeCancelledProviderFinishes() async throws {
        let coordinator = QuoteRefreshCoordinator()
        let oldProvider = SuspendedQuoteProvider()
        let newProvider = SuspendedQuoteProvider()
        let old = Task { try await coordinator.fetch(using: oldProvider, instruments: [instrument]) }
        await oldProvider.waitForStart()
        #expect(coordinator.isRefreshing)
        coordinator.cancel()
        #expect(!coordinator.isRefreshing)
        let new = Task { try await coordinator.fetch(using: newProvider, instruments: [instrument]) }
        await newProvider.waitForStart()
        #expect(coordinator.isRefreshing)
        await oldProvider.finish(.success([]))
        #expect(try await old.value == nil)
        #expect(coordinator.isRefreshing)
        await newProvider.finish(.success([]))
        #expect(try await new.value == [])
        #expect(!coordinator.isRefreshing)
    }

    @Test @MainActor func lateFailureAfterSourceSwitchCannotCancelNewRequest() async throws {
        let coordinator = QuoteRefreshCoordinator()
        let oldProvider = SuspendedQuoteProvider()
        let newProvider = SuspendedQuoteProvider()
        let old = Task { try await coordinator.fetch(using: oldProvider, instruments: [instrument]) }
        await oldProvider.waitForStart()
        coordinator.cancel()
        let new = Task { try await coordinator.fetch(using: newProvider, instruments: [instrument]) }
        await newProvider.waitForStart()
        await oldProvider.finish(.failure(URLError(.timedOut)))
        #expect(try await old.value == nil)
        #expect(coordinator.isRefreshing)
        await newProvider.finish(.success([]))
        #expect(try await new.value == [])
    }

    @Test @MainActor func currentFailureReleasesSlotAndCanBeRetried() async throws {
        let coordinator = QuoteRefreshCoordinator()
        let provider = SuspendedQuoteProvider()
        let first = Task { try await coordinator.fetch(using: provider, instruments: [instrument]) }
        await provider.waitForStart()
        await provider.finish(.failure(URLError(.notConnectedToInternet)))
        do { _ = try await first.value; Issue.record("Expected current network failure") }
        catch { #expect((error as? URLError)?.code == .notConnectedToInternet) }
        #expect(!coordinator.isRefreshing)
        let retry = Task { try await coordinator.fetch(using: provider, instruments: [instrument]) }
        await provider.waitForStart()
        await provider.finish(.success([]))
        #expect(try await retry.value == [])
    }
}
