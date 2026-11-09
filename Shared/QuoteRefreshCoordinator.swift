import Foundation

/// Cancellation releases the slot immediately, even if a provider finishes late.
@MainActor
public final class QuoteRefreshCoordinator {
    private var requestID: UUID?
    private var task: Task<[Quote], Error>?

    public init() {}
    public var isRefreshing: Bool { requestID != nil }

    public func cancel() {
        task?.cancel()
        task = nil
        requestID = nil
    }

    public func fetch(using provider: any MarketDataProviding, instruments: [Instrument]) async throws -> [Quote]? {
        guard !isRefreshing, !Task.isCancelled else { return nil }
        let id = UUID()
        let request = Task { try await provider.quotes(for: instruments) }
        requestID = id
        task = request
        defer {
            if requestID == id {
                requestID = nil
                task = nil
            }
        }
        do {
            let quotes = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            guard requestID == id, !request.isCancelled, !Task.isCancelled else { return nil }
            return quotes
        } catch {
            guard requestID == id, !request.isCancelled, !Task.isCancelled else { return nil }
            throw error
        }
    }
}
