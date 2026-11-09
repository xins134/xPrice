import Foundation
import Testing
@testable import XPriceCore

/// Synthetic responses verify that the saved setting routes quotes and searches
/// through the chosen provider. No test contacts a live market data service.
@Suite(.serialized)
struct MarketDataProviderRoutingTests {
    @Test(arguments: MarketDataSource.allCases)
    func persistedSourceRoutesCodeSearchAndPreservesFundPrice(source: MarketDataSource) async throws {
        let settings = AppSettings(marketDataSource: source)
        let saved = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: saved)
        let expectedHost: String
        let payload: Data
        switch source {
        case .tencent:
            expectedHost = "qt.gtimg.cn"
            var fields = Array(repeating: "", count: 40)
            fields[0] = "1"
            fields[1] = "合成ETF"
            fields[2] = "510300"
            fields[3] = "3.851"
            fields[4] = "3.800"
            fields[30] = "20261106154000"
            fields[32] = "1.34"
            payload = Data("v_sh510300=\"\(fields.joined(separator: "~"))\";".utf8)
        case .eastmoney:
            expectedHost = "push2.eastmoney.com"
            payload = Data(#"{"rc":0,"data":{"diff":[{"f2":3.851,"f3":1.34,"f12":"510300","f13":1,"f14":"合成ETF","f18":3.800,"f124":1793950800}]}}"#.utf8)
        case .sina:
            expectedHost = "hq.sinajs.cn"
            var fields = Array(repeating: "0", count: 33)
            fields[0] = "合成ETF"
            fields[2] = "3.800"
            fields[3] = "3.851"
            fields[30] = "2026-11-06"
            fields[31] = "15:40:00"
            payload = Data("var hq_str_sh510300=\"\(fields.joined(separator: ","))\";".utf8)
        }
        RoutingURLProtocol.state.install(payload: payload)
        let session = makeRoutingSession()
        defer { session.invalidateAndCancel() }
        let provider = MarketDataProviders.make(source: restored.marketDataSource, session: session)
        let matches = try await provider.search("510300.SH")
        let instrument = try #require(matches.first)
        #expect(instrument.symbol == "sh510300")
        #expect(instrument.kind == .etf)
        let quote = try #require(try await provider.quotes(for: [instrument]).first)
        #expect(quote.price == Decimal(string: "3.851"))
        #expect(quote.previousClose == Decimal(string: "3.800"))
        #expect(quote.timestamp == Date(timeIntervalSince1970: 1_793_950_800))
        #expect(RoutingURLProtocol.state.requests.count == 2)
        #expect(RoutingURLProtocol.state.requests.allSatisfy { $0.url?.host == expectedHost })
    }

    @Test func failedSelectedSourceDoesNotSilentlyFetchAnotherSource() async throws {
        RoutingURLProtocol.state.install(payload: Data(), status: 429)
        let session = makeRoutingSession()
        defer { session.invalidateAndCancel() }
        let provider = MarketDataProviders.make(source: .sina, session: session)
        await #expect(throws: MarketDataError.httpStatus(429)) {
            try await provider.quotes(for: [Instrument(symbol: "sh510300", name: "合成ETF", kind: .etf)])
        }
        #expect(RoutingURLProtocol.state.requests.count == 1)
        #expect(RoutingURLProtocol.state.requests.first?.url?.host == "hq.sinajs.cn")
    }
}

private func makeRoutingSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RoutingURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class RoutingURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var payload = Data()
        private var status = 200
        private var recorded: [URLRequest] = []

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func install(payload: Data, status: Int = 200) {
            lock.lock()
            defer { lock.unlock() }
            self.payload = payload
            self.status = status
            recorded = []
        }

        func response(for request: URLRequest) -> (Data, Int) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(request)
            return (payload, status)
        }
    }

    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (data, status) = Self.state.response(for: request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
