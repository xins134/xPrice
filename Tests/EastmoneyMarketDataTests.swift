import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import XPriceCore

/// Synthetic JSON fixtures only. No test requests a public quote endpoint or
/// establishes real market availability, source latency, or redistribution rights.
@Suite(.serialized)
struct EastmoneyMarketDataTests {
    private let receivedAt = Date(timeIntervalSince1970: 1_793_950_800)

    @Test func preservesFormattedStockIndexETFAndLOFDecimals() throws {
        let requested = [
            Instrument(symbol: "sh600519", name: "合成股票"),
            Instrument(symbol: "sh000001", name: "合成指数", kind: .index),
            Instrument(symbol: "sh510300", name: "合成ETF", kind: .etf),
            Instrument(symbol: "sz161725", name: "合成LOF", kind: .lof)
        ]
        // Numeric literals exercise Decimal decoding without a Double round-trip.
        let data = Data(#"{"rc":0,"data":{"diff":[{"f12":"161725","f13":0,"f14":"合成LOF","f2":0.891,"f18":0.900,"f3":-1.00,"f124":1793950800},{"f12":"510300","f13":1,"f14":"合成ETF","f2":3.851,"f18":3.800,"f3":1.34,"f124":1793950800},{"f12":"000001","f13":1,"f14":"合成指数","f2":3300.25,"f18":3300.00,"f3":0.01,"f124":1793950800},{"f12":"600519","f13":1,"f14":"合成股票","f2":1500.01,"f18":1500.00,"f3":0.00,"f124":1793950800}]}}"#.utf8)
        let quotes = try EastmoneyMarketDataProvider.parseQuotes(data, requested: requested, fetchedAt: receivedAt)
        #expect(quotes.map(\.symbol) == requested.map(\.symbol))
        #expect(quotes[0].price == Decimal(string: "1500.01"))
        #expect(quotes[0].change == Decimal(string: "0.01"))
        #expect(quotes[1].price == Decimal(string: "3300.25"))
        #expect(quotes[2].price == Decimal(string: "3.851"))
        #expect(quotes[2].changePercent == Decimal(string: "1.34"))
        #expect(quotes[3].price == Decimal(string: "0.891"))
        #expect(quotes.allSatisfy { $0.timestamp == receivedAt && $0.fetchedAt == receivedAt })
    }

    @Test func rejectsUnavailableNumbersMissingFieldsAndFutureTimestampsWhileKeepingValidRows() throws {
        let stock = Instrument(symbol: "sh600519", name: "合成股票")
        let etf = Instrument(symbol: "sh510300", name: "合成ETF", kind: .etf)
        let invalid: [[String: Any]] = [
            eastmoneySyntheticRow("1.510300", price: "-"),
            eastmoneySyntheticRow("1.510300", price: "0"),
            eastmoneySyntheticRow("1.510300", close: "0"),
            eastmoneySyntheticRow("1.510300", percent: "NaN"),
            eastmoneySyntheticRow("1.510300", percent: NSNull()),
            eastmoneySyntheticRow("1.510300", name: " "),
            eastmoneySyntheticRow("1.510300", stamp: "1793950800.5"),
            eastmoneySyntheticRow("1.510300", stamp: "0"),
            eastmoneySyntheticRow("1.510300", stamp: "1893950800"),
            ["f12": "510300", "f13": 1, "f14": "字段缺失"]
        ]
        for row in invalid {
            let data = try eastmoneySyntheticEnvelope([row, eastmoneySyntheticRow("1.600519"), eastmoneySyntheticRow("0.000001")])
            let quotes = try EastmoneyMarketDataProvider.parseQuotes(data, requested: [etf, stock], fetchedAt: receivedAt)
            #expect(quotes.map(\.symbol) == [stock.symbol])
            #expect(throws: MarketDataError.noValidQuotes) {
                try EastmoneyMarketDataProvider.parseQuotes(eastmoneySyntheticEnvelope([row]), requested: [etf], fetchedAt: receivedAt)
            }
        }
    }

    @Test func rejectsMalformedAndErrorEnvelopesAndDoesNotReplaceTimeWithFetchTime() throws {
        let requested = [Instrument(symbol: "sh600519", name: "合成股票")]
        for payload in ["<html>Service unavailable</html>", "{}", #"{"rc":1,"data":{"diff":[]}}"#, #"{"rc":0,"data":{}}"#] {
            #expect(throws: MarketDataError.invalidResponse) {
                try EastmoneyMarketDataProvider.parseQuotes(Data(payload.utf8), requested: requested, fetchedAt: receivedAt)
            }
        }
        for payload in [#"{"rc":0,"data":null}"#, #"{"rc":0,"data":{"diff":[]}}"#] {
            #expect(throws: MarketDataError.noValidQuotes) {
                try EastmoneyMarketDataProvider.parseQuotes(Data(payload.utf8), requested: requested, fetchedAt: receivedAt)
            }
        }
        let stale = try EastmoneyMarketDataProvider.parseQuotes(
            eastmoneySyntheticEnvelope([eastmoneySyntheticRow("1.600519", stamp: "1693950800")]),
            requested: requested, fetchedAt: receivedAt
        )
        #expect(stale[0].timestamp == Date(timeIntervalSince1970: 1_693_950_800))
        #expect(stale[0].fetchedAt == receivedAt)
    }

    @Test func preservesMarketForAmbiguousIndexStockAndBeijingCodes() throws {
        let requested = [
            Instrument(symbol: "sh000001", name: "合成指数", kind: .index),
            Instrument(symbol: "sz000001", name: "合成股票"),
            Instrument(symbol: "bj920001", name: "合成北股"),
            Instrument(symbol: "bj899050", name: "合成北指", kind: .index)
        ]
        let data = try eastmoneySyntheticEnvelope([
            eastmoneySyntheticRow("0.920001"), eastmoneySyntheticRow("0.899050"),
            eastmoneySyntheticRow("0.000001", price: "12.30"), eastmoneySyntheticRow("1.000001", price: "3300.25")
        ])
        let quotes = try EastmoneyMarketDataProvider.parseQuotes(data, requested: requested, fetchedAt: receivedAt)
        #expect(quotes.map(\.symbol) == requested.map(\.symbol))
        #expect(quotes[0].price == Decimal(string: "3300.25"))
        #expect(quotes[1].price == Decimal(string: "12.30"))
    }

    @Test func completeCodeSearchConfirmsQuoteAndUsesDecimalFormatParameters() async throws {
        EastmoneyStubURLProtocol.state.install { request in
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "push2.eastmoney.com")
            #expect(request.url?.path == "/api/qt/ulist.np/get")
            #expect(request.timeoutInterval == 8)
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://quote.eastmoney.com/")
            let items = eastmoneyQueryItems(request)
            #expect(items["secids"] == "0.161725")
            #expect(items["fltt"] == "2")
            #expect(items["fields"] == "f12,f13,f14,f2,f18,f3,f124")
            return .response(status: 200, data: try eastmoneySyntheticEnvelope([
                eastmoneySyntheticRow("0.161725", name: "合成LOF", price: "0.891", close: "0.900", percent: "-1.00")
            ]))
        }
        let provider = EastmoneyMarketDataProvider(session: eastmoneyStubSession())
        #expect(try await provider.search("161725.SZ") == [Instrument(symbol: "sz161725", name: "合成LOF", kind: .lof)])
        #expect(EastmoneyStubURLProtocol.state.requests.count == 1)
    }

    @Test func ambiguousCompleteCodeSearchReturnsBothMarketsWithoutNameEndpoint() async throws {
        EastmoneyStubURLProtocol.state.install { request in
            #expect(eastmoneyQueryItems(request)["secids"] == "1.000001,0.000001")
            return .response(status: 200, data: try eastmoneySyntheticEnvelope([
                eastmoneySyntheticRow("0.000001", name: "合成股票"), eastmoneySyntheticRow("1.000001", name: "合成指数")
            ]))
        }
        let provider = EastmoneyMarketDataProvider(session: eastmoneyStubSession())
        #expect(try await provider.search(" 000001\n") == [
            Instrument(symbol: "sh000001", name: "合成指数", kind: .index),
            Instrument(symbol: "sz000001", name: "合成股票")
        ])
        #expect(EastmoneyStubURLProtocol.state.requests.count == 1)
    }

    @Test func nameSearchUsesSuggestionEndpointAndFiltersUnsupportedAndDuplicateSymbols() async throws {
        let payload = Data(#"{"QuotationCodeTable":{"Status":0,"Data":[{"Code":"000001","Name":"合成指数","QuoteID":"1.000001"},{"Code":"510300","Name":"合成ETF","QuoteID":"1.510300"},{"Code":"161725","Name":"合成LOF","QuoteID":"0.161725"},{"Code":"920001","Name":"合成北股","QuoteID":"0.920001"},{"Code":"00700","Name":"合成港股","QuoteID":"116.00700"},{"Code":"AAPL","Name":"合成美股","QuoteID":"105.AAPL"},{"Code":"900901","Name":"合成B股","QuoteID":"1.900901"},{"Code":"000001","Name":"重复指数","QuoteID":"1.000001"},{"Code":"600519","Name":"错码","QuoteID":"1.600000"}]}}"#.utf8)
        EastmoneyStubURLProtocol.state.install { request in
            #expect(request.url?.host == "searchapi.eastmoney.com")
            #expect(request.url?.path == "/api/suggest/get")
            #expect(request.url?.scheme == "https")
            #expect(eastmoneyQueryItems(request)["input"] == "合成证券")
            #expect(eastmoneyQueryItems(request)["type"] == "14")
            return .response(status: 200, data: payload)
        }
        let provider = EastmoneyMarketDataProvider(session: eastmoneyStubSession())
        let results = try await provider.search("合成证券")
        #expect(results.map(\.symbol) == ["sh000001", "sh510300", "sz161725", "bj920001"])
        #expect(results.map(\.kind) == [.index, .etf, .lof, .stock])
    }

    @Test func nameSearchDistinguishesEmptyMatchesFromInvalidResponses() throws {
        for payload in [#"{"QuotationCodeTable":{"Status":0,"Data":[]}}"#, #"{"QuotationCodeTable":{"Status":0,"Data":null}}"#] {
            #expect(try EastmoneyMarketDataProvider.parseSearchResults(Data(payload.utf8)).isEmpty)
        }
        for payload in ["{}", "<html>Error</html>", #"{"QuotationCodeTable":{"Status":1,"Data":[]}}"#, #"{"QuotationCodeTable":{"Data":[]}}"#, #"{"QuotationCodeTable":{"Status":0}}"#] {
            #expect(throws: MarketDataError.invalidResponse) {
                try EastmoneyMarketDataProvider.parseSearchResults(Data(payload.utf8))
            }
        }
    }

    @Test func batchesFiftyDeduplicatesAndPreservesRequestedOrder() async throws {
        EastmoneyStubURLProtocol.state.install { request in
            let ids = try #require(eastmoneyQueryItems(request)["secids"]).components(separatedBy: ",")
            #expect(ids.count <= 50)
            return .response(status: 200, data: try eastmoneySyntheticEnvelope(ids.reversed().map { eastmoneySyntheticRow($0) }))
        }
        let provider = EastmoneyMarketDataProvider(session: eastmoneyStubSession())
        let requested = (0..<51).map { Instrument(symbol: String(format: "sh600%03d", $0), name: "合成股票") }
        let quotes = try await provider.quotes(for: requested + [requested[0]])
        #expect(quotes.map(\.symbol) == requested.map(\.symbol))
        #expect(EastmoneyStubURLProtocol.state.requests.count == 2)
    }

    @Test func rejectsOutOfScopeSymbolsAndEmptyInputsBeforeRequest() async throws {
        EastmoneyStubURLProtocol.state.install { _ in .failure(URLError(.notConnectedToInternet)) }
        let provider = EastmoneyMarketDataProvider(session: eastmoneyStubSession())
        #expect(try await provider.quotes(for: []).isEmpty)
        for symbol in ["hk00700", "sh900901", "sh600519&bad=1"] {
            await #expect(throws: MarketDataError.invalidSymbol(symbol)) {
                try await provider.quotes(for: [Instrument(symbol: symbol, name: "无效")])
            }
        }
        await #expect(throws: MarketDataError.invalidQuery) { try await provider.search(" \n") }
        await #expect(throws: MarketDataError.invalidQuery) { try await provider.search(String(repeating: "测", count: 65)) }
        await #expect(throws: MarketDataError.invalidSymbol("700001")) { try await provider.search("700001") }
        #expect(EastmoneyStubURLProtocol.state.requests.isEmpty)
    }

    @Test func propagatesNetworkHTTPAndOversizedResponseFailures() async throws {
        let provider = EastmoneyMarketDataProvider(session: eastmoneyStubSession())
        let requested = [Instrument(symbol: "sh600519", name: "合成股票")]
        EastmoneyStubURLProtocol.state.install { _ in .failure(URLError(.notConnectedToInternet)) }
        await #expect(throws: URLError.self) { try await provider.quotes(for: requested) }
        EastmoneyStubURLProtocol.state.install { _ in .response(status: 429, data: Data()) }
        await #expect(throws: MarketDataError.httpStatus(429)) { try await provider.quotes(for: requested) }
        EastmoneyStubURLProtocol.state.install { _ in .response(status: 200, data: Data(repeating: 0x20, count: 2_000_001)) }
        await #expect(throws: MarketDataError.responseTooLarge) { try await provider.quotes(for: requested) }
        EastmoneyStubURLProtocol.state.install { _ in .response(status: 200, data: Data()) }
        await #expect(throws: MarketDataError.invalidResponse) { try await provider.quotes(for: requested) }
    }

    @Test func cancellationStopsBeforeAnyBatchRequest() async throws {
        EastmoneyStubURLProtocol.state.install { _ in .failure(URLError(.unknown)) }
        let provider = EastmoneyMarketDataProvider(session: eastmoneyStubSession())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.quotes(for: [Instrument(symbol: "sh600519", name: "合成股票")])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(EastmoneyStubURLProtocol.state.requests.isEmpty)
    }
}

private func eastmoneySyntheticRow(
    _ securityID: String, name: String = "合成测试证券", price: Any = "12.30",
    close: Any = "12.00", percent: Any = "2.50", stamp: Any = "1793950800"
) -> [String: Any] {
    let parts = securityID.components(separatedBy: ".")
    return ["f12": parts[1], "f13": Int(parts[0])!, "f14": name,
            "f2": price, "f18": close, "f3": percent, "f124": stamp]
}

private func eastmoneySyntheticEnvelope(_ rows: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["rc": 0, "data": ["diff": rows]])
}

private func eastmoneyQueryItems(_ request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
    return Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
}

private func eastmoneyStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [EastmoneyStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class EastmoneyStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome: Sendable {
        case response(status: Int, data: Data)
        case failure(URLError)
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (URLRequest) throws -> Outcome)?
        private var recordedRequests: [URLRequest] = []

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        func install(_ handler: @escaping @Sendable (URLRequest) throws -> Outcome) {
            lock.lock()
            defer { lock.unlock() }
            self.handler = handler
            recordedRequests = []
        }

        func respond(to request: URLRequest) throws -> Outcome {
            lock.lock()
            recordedRequests.append(request)
            let handler = self.handler
            lock.unlock()
            guard let handler else { throw URLError(.unknown) }
            return try handler(request)
        }
    }

    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            switch try Self.state.respond(to: request) {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .response(let status, let data):
                guard let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
