import CoreFoundation
import Foundation
import Testing
@testable import XPriceCore

/// Synthetic protocol fixtures only; no test establishes live availability.
@Suite(.serialized)
struct SinaMarketDataTests {
    private let receivedAt = Date(timeIntervalSince1970: 1_793_950_800)

    @Test func parsesStocksIndicesAndTradedFundsWithSourceTimeAndPrecision() throws {
        let requested = [
            Instrument(symbol: "sh600519", name: "合成股票"),
            Instrument(symbol: "sh000001", name: "合成指数", kind: .index),
            Instrument(symbol: "sh510300", name: "合成ETF", kind: .etf),
            Instrument(symbol: "sz161725", name: "合成LOF", kind: .lof),
            Instrument(symbol: "bj920001", name: "合成北交所股票")
        ]
        let payload = [
            sinaFixture(symbol: "sz161725", name: "合成LOF", price: "0.891", close: "0.900"),
            sinaFixture(symbol: "sh510300", name: "合成ETF", price: "3.850", close: "3.800"),
            sinaFixture(symbol: "sh600519", name: "合成股票", price: "1500.01", close: "1500.00"),
            sinaFixture(symbol: "sh000001", name: "合成指数", price: "3300.25", close: "3300.00"),
            sinaFixture(symbol: "bj920001", name: "合成北交所股票", price: "12.30", close: "12.00")
        ].joined()
        let quotes = try SinaMarketDataProvider.parseQuotes(payload, requested: requested, fetchedAt: receivedAt)
        #expect(quotes.map(\.symbol) == requested.map(\.symbol))
        #expect(quotes[0].change == Decimal(string: "0.01"))
        #expect(quotes[2].price == Decimal(string: "3.850"))
        #expect(quotes[3].changePercent == Decimal(-1))
        #expect(quotes[4].changePercent == Decimal(string: "2.5"))
        #expect(quotes.allSatisfy { $0.timestamp == receivedAt && $0.fetchedAt == receivedAt })
    }

    @Test func rejectsInvalidPricesDatesAndUnrequestedAssignments() throws {
        let requested = [Instrument(symbol: "sh600519", name: "合成股票")]
        let invalid = [
            sinaFixture(symbol: "sh600519", name: "合成股票", price: "0", close: "1500"),
            sinaFixture(symbol: "sh600519", name: "合成股票", price: "1500", close: "0"),
            sinaFixture(symbol: "sh600519", name: "合成股票", price: "NaN", close: "1500"),
            sinaFixture(symbol: "sh600519", name: "合成股票", price: "1,500", close: "1500"),
            sinaFixture(symbol: "sh600519", name: "", price: "1500", close: "1500"),
            sinaFixture(symbol: "sh600519", name: "合成股票", price: "1500", close: "1500", date: "2026-02-30"),
            sinaFixture(symbol: "sh600519", name: "合成股票", price: "1500", close: "1500", time: "15:60:00"),
            sinaFixture(symbol: "sh600519", name: "合成股票", price: "1500", close: "1500", date: "2027-11-06"),
            sinaFixture(symbol: "sz000001", name: "其他股票", price: "12", close: "12"),
            #"var hq_str_sh600519="合成股票,1500,1500,1500";"#,
            "<html>Unavailable</html>"
        ]
        for payload in invalid {
            #expect(throws: MarketDataError.noValidQuotes) {
                try SinaMarketDataProvider.parseQuotes(payload, requested: requested, fetchedAt: receivedAt)
            }
        }
        let mixed = sinaFixture(symbol: "sh600519", name: "合成股票", price: "1500", close: "1500")
            + #"var hq_str_sh510300="";"#
        #expect(try SinaMarketDataProvider.parseQuotes(mixed, requested: requested, fetchedAt: receivedAt).count == 1)
    }

    @Test func convertibleQuotesPreserveThreeDecimalPricesAndCalculatedPercent() throws {
        let requested = [
            Instrument(symbol: "sh113052", name: "合成沪转债", kind: .convertibleBond),
            Instrument(symbol: "sz127045", name: "合成深转债", kind: .convertibleBond)
        ]
        let payload = sinaFixture(symbol: "sz127045", name: "合成深转债", price: "120.123", close: "120.000")
            + sinaFixture(symbol: "sh113052", name: "合成沪转债", price: "113.052", close: "113.051")
        let quotes = try SinaMarketDataProvider.parseQuotes(payload, requested: requested, fetchedAt: receivedAt)
        #expect(quotes.map(\.symbol) == requested.map(\.symbol))
        #expect(quotes[0].price == Decimal(string: "113.052"))
        #expect(quotes[0].change == Decimal(string: "0.001"))
        #expect(quotes[1].price == Decimal(string: "120.123"))
        #expect(quotes[1].changePercent == Decimal(string: "0.1025"))
        #expect(quotes.allSatisfy { $0.source == .sina && $0.timestamp == receivedAt })
        #expect(throws: MarketDataError.noValidQuotes) {
            try SinaMarketDataProvider.parseQuotes(
                sinaFixture(symbol: "sh113052", name: "合成沪转债", price: "0.000", close: "113.051"),
                requested: [requested[0]], fetchedAt: receivedAt
            )
        }
    }

    @Test func convertibleCodeSearchConfirmsNamesForBareAndExplicitMarketCodes() async throws {
        let provider = SinaMarketDataProvider(session: sinaStubSession())
        for (query, symbol) in [("113052", "sh113052"), ("118003.SH", "sh118003"), ("SZ127045", "sz127045")] {
            SinaStubURLProtocol.state.install { request in
                #expect(request.url?.host == "hq.sinajs.cn")
                #expect(request.url?.path == "/list=\(symbol)")
                return .response(200, Data(sinaFixture(symbol: symbol, name: "合成转债", price: "113.052", close: "113.051").utf8))
            }
            #expect(try await provider.search(query) == [Instrument(symbol: symbol, name: "合成转债", kind: .convertibleBond)])
            #expect(SinaStubURLProtocol.state.requests.count == 1)
        }
    }

    @Test func convertibleNameSearchRequestsBondCategoryAndFiltersOtherDebt() async throws {
        let payload = #"var suggestvalue="合成沪转债,81,113052,sh113052,合成沪转债,,合成沪转债,99,1,,,,;合成深转债,81,127045,sz127045,合成深转债,,合成深转债,99,1,,,,;合成可交换债,81,111001,sh111001,合成可交换债;合成国债,81,019001,sh019001,合成国债;重复沪转债,81,113052,sh113052,重复沪转债;错码,81,113052,sh113053,错码;错类股票,81,600519,sh600519,错类股票";"#
        SinaStubURLProtocol.state.install { request in
            #expect(request.url?.host == "suggest3.sinajs.cn")
            #expect(request.url?.absoluteString.contains("type=11,12,13,14,15,81&") == true)
            return .response(200, Data(payload.utf8))
        }
        let provider = SinaMarketDataProvider(session: sinaStubSession())
        #expect(try await provider.search("合成转债") == [
            Instrument(symbol: "sh113052", name: "合成沪转债", kind: .convertibleBond),
            Instrument(symbol: "sz127045", name: "合成深转债", kind: .convertibleBond)
        ])
    }

    @Test func completeCodeSearchConfirmsNamesAndResolvesIndexStockAmbiguity() async throws {
        SinaStubURLProtocol.state.install { request in
            #expect(request.url?.scheme == "https")
            #expect(request.url?.host == "hq.sinajs.cn")
            #expect(request.url?.path == "/list=sh000001,sz000001")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://finance.sina.com.cn/")
            #expect(request.timeoutInterval == 8)
            let payload = sinaFixture(symbol: "sh000001", name: "上证指数", price: "3300.25", close: "3300")
                + sinaFixture(symbol: "sz000001", name: "平安银行", price: "12.30", close: "12")
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            ))
            return .response(200, try #require(payload.data(using: encoding)))
        }
        let provider = SinaMarketDataProvider(session: sinaStubSession())
        #expect(try await provider.search(" 000001\n") == [
            Instrument(symbol: "sh000001", name: "上证指数", kind: .index),
            Instrument(symbol: "sz000001", name: "平安银行", kind: .stock)
        ])
        #expect(SinaStubURLProtocol.state.requests.count == 1)
    }

    @Test func explicitMarketAndFundSearchOnlyRequestTheSelectedCode() async throws {
        let provider = SinaMarketDataProvider(session: sinaStubSession())
        for (query, symbol) in [("510300.SH", "sh510300"), (" SZ161725 ", "sz161725"), ("920001", "bj920001")] {
            SinaStubURLProtocol.state.install { request in
                #expect(request.url?.path == "/list=\(symbol)")
                return .response(200, Data(sinaFixture(symbol: symbol, name: "合成证券", price: "0.891", close: "0.900").utf8))
            }
            let result = try await provider.search(query)
            #expect(result.first?.symbol == symbol)
            #expect(result.first?.kind == TencentMarketDataProvider.kind(for: symbol))
        }
    }

    @Test func suggestionSearchUsesSinaAndEscapesPathParameters() async throws {
        SinaStubURLProtocol.state.install { request in
            #expect(request.url?.host == "suggest3.sinajs.cn")
            #expect(request.url?.absoluteString.contains("%26name%3Dbad") == true)
            #expect(request.url?.absoluteString.hasSuffix("&name=suggestvalue") == true)
            return .response(200, Data(#"var suggestvalue="上证指数,13,000001,sh000001,上证指数,szzs";"#.utf8))
        }
        let provider = SinaMarketDataProvider(session: sinaStubSession())
        #expect(try await provider.search("上证指数&name=bad") == [Instrument(symbol: "sh000001", name: "上证指数", kind: .index)])
    }

    @Test func suggestionParserFiltersUnsupportedMarketsAndDuplicateOrMismatchedCodes() throws {
        let payload = #"var suggestvalue="合成股票,11,600519,sh600519,合成股票,hcgp;合成ETF,15,510300,sh510300,合成ETF,hcetf;合成LOF,15,161725,sz161725,合成LOF,hclof;指数,13,000001,sh000001,指数,zs;重复,11,600519,sh600519,重复,cf;B股,12,900901,sh900901,B股,b;港股,31,00700,hk00700,港股,g;错码,11,600519,sh600000,错码,c";"#
        let result = try SinaMarketDataProvider.parseSearchResults(payload)
        #expect(result.map(\.symbol) == ["sh600519", "sh510300", "sz161725", "sh000001"])
        #expect(result.map(\.kind) == [.stock, .etf, .lof, .index])
        #expect(try SinaMarketDataProvider.parseSearchResults(#"var suggestvalue="";"#).isEmpty)
        #expect(throws: MarketDataError.invalidResponse) { try SinaMarketDataProvider.parseSearchResults("<html>Error</html>") }
        #expect(throws: MarketDataError.invalidResponse) { try SinaMarketDataProvider.parseSearchResults(#"var suggestvalue="\uZZZZ";"#) }
    }

    @Test func batchesAtFiftyAndDeduplicatesBeforeRequesting() async throws {
        SinaStubURLProtocol.state.install { request in
            let symbols = try #require(request.url?.path).replacingOccurrences(of: "/list=", with: "").components(separatedBy: ",")
            #expect(symbols.count <= 50)
            let payload = symbols.map { sinaFixture(symbol: $0, name: "合成股票", price: "12", close: "10") }.joined()
            return .response(200, Data(payload.utf8))
        }
        let requested = (0..<51).map { Instrument(symbol: String(format: "sh600%03d", $0), name: "合成股票") }
        let provider = SinaMarketDataProvider(session: sinaStubSession())
        #expect(try await provider.quotes(for: requested + [requested[0]]).count == 51)
        #expect(SinaStubURLProtocol.state.requests.count == 2)
    }

    @Test func rejectsInvalidInputAndPropagatesNetworkHTTPAndOversizeErrors() async throws {
        let provider = SinaMarketDataProvider(session: sinaStubSession())
        let requested = [Instrument(symbol: "sh600519", name: "合成股票")]
        SinaStubURLProtocol.state.install { _ in .failure(URLError(.notConnectedToInternet)) }
        #expect(try await provider.quotes(for: []).isEmpty)
        await #expect(throws: MarketDataError.invalidSymbol("hk00700")) {
            try await provider.quotes(for: [Instrument(symbol: "hk00700", name: "港股")])
        }
        await #expect(throws: MarketDataError.invalidQuery) { try await provider.search(" ") }
        #expect(SinaStubURLProtocol.state.requests.isEmpty)
        await #expect(throws: URLError.self) { try await provider.quotes(for: requested) }
        SinaStubURLProtocol.state.install { _ in .response(429, Data()) }
        await #expect(throws: MarketDataError.httpStatus(429)) { try await provider.quotes(for: requested) }
        SinaStubURLProtocol.state.install { _ in .response(200, Data(repeating: 0x20, count: 2_000_001)) }
        await #expect(throws: MarketDataError.responseTooLarge) { try await provider.quotes(for: requested) }
    }
}

private func sinaFixture(symbol: String, name: String, price: String, close: String,
                         date: String = "2026-11-06", time: String = "15:40:00") -> String {
    var fields = Array(repeating: "0", count: 33)
    fields[0] = name
    fields[2] = close
    fields[3] = price
    fields[30] = date
    fields[31] = time
    return "var hq_str_\(symbol)=\"\(fields.joined(separator: ","))\";"
}

private func sinaStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SinaStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class SinaStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome: Sendable {
        case response(Int, Data)
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
