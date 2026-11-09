import CoreFoundation
import Foundation
import Testing
@testable import XPriceCore

/// All payloads below are synthetic protocol fixtures. They are not captured
/// market prices, and these tests do not establish live endpoint availability.
@Suite(.serialized)
struct MarketDataTests {
    private let receivedAt = Date(timeIntervalSince1970: 1_793_950_800) // 2026-11-06 07:40 UTC

    @Test func parsesStockETFAndLOFWithoutLosingDecimalPrecision() throws {
        let requested = [
            Instrument(symbol: "sh600519", name: "贵州茅台"),
            Instrument(symbol: "sh510300", name: "沪深300ETF", kind: .etf),
            Instrument(symbol: "sz161725", name: "白酒LOF", kind: .lof)
        ]
        let payload = [
            syntheticQuote(symbol: "sz161725", name: "白酒LOF", price: "0.891", close: "0.900", percent: "-1.00"),
            syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1500.01", close: "1500.00", percent: "0.00"),
            syntheticQuote(symbol: "sh510300", name: "沪深300ETF", price: "3.850", close: "3.800", percent: "1.32")
        ].joined(separator: "\n")
        let result = try TencentMarketDataProvider.parseQuotes(payload, requested: requested, fetchedAt: receivedAt)
        #expect(result.map(\.symbol) == requested.map(\.symbol))
        #expect(result[0].price == Decimal(string: "1500.01"))
        #expect(result[0].change == Decimal(string: "0.01"))
        #expect(result[2].changePercent == Decimal(-1))
        #expect(result[0].fetchedAt == receivedAt)
        #expect(result[0].timestamp == Date(timeIntervalSince1970: 1_793_950_800))
    }

    @Test func decodingGB18030PreservesChineseNames() throws {
        let text = syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1500", close: "1490", percent: "0.67")
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let data = try #require(text.data(using: encoding))
        #expect(String(data: data, encoding: .utf8) == nil)
        #expect(try TencentMarketDataProvider.decodePayload(data) == text)
    }

    @Test func parsesBatchAssignmentsWithoutLineBreaks() throws {
        let requested = [
            Instrument(symbol: "sh600519", name: "贵州茅台"),
            Instrument(symbol: "sh510300", name: "300ETF", kind: .etf),
            Instrument(symbol: "sz161725", name: "白酒LOF", kind: .lof)
        ]
        let assignments = [
            syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1500", close: "1490", percent: "0.67"),
            syntheticQuote(symbol: "sh510300", name: "300ETF", price: "3.850", close: "3.800", percent: "1.32"),
            syntheticQuote(symbol: "sz161725", name: "白酒LOF", price: "0.891", close: "0.900", percent: "-1.00")
        ]
        for separator in ["", "  ", "\r\n"] {
            let payload = assignments.joined(separator: separator)
            let result = try TencentMarketDataProvider.parseQuotes(payload, requested: requested, fetchedAt: receivedAt)
            #expect(result.map(\.symbol) == requested.map(\.symbol))
            #expect(result.last?.price == Decimal(string: "0.891"))
        }
    }

    @Test func parsesWebsiteSearchStockAndFundTablesWithoutDuplicates() throws {
        let payload = #"{"stock":[{"code":"sh600519","name":"贵州茅台"},{"code":"sh510300","name":"300ETF"}],"fund":[{"code":"sh510300","name":"重复ETF"},{"code":"sz161725","name":"白酒LOF"}]}"#
        let result = try TencentMarketDataProvider.parseSearchResults(payload)
        #expect(result.map(\.symbol) == ["sh600519", "sh510300", "sz161725"])
        #expect(result.map(\.name) == ["贵州茅台", "300ETF", "白酒LOF"])
        #expect(result.map(\.kind) == [.stock, .etf, .lof])
        #expect(try TencentMarketDataProvider.parseSearchResults(#"{"stock":[],"fund":[]}"#).isEmpty)
    }

    @Test func nameSearchDecodesUnicodeAndFiltersOtherMarketsAndDuplicates() throws {
        let payload = #"{"stock":[{"code":"sh600519","name":"\u8d35\u5dde\u8305\u53f0"},{"code":"sh510300","name":"300ETF"},{"code":"sz161725","name":"白酒LOF"},{"code":"sh000001","name":"上证指数"},{"code":"sz000001","name":"平安银行"},{"code":"sz399001","name":"深证成指"},{"code":"hk00700","name":"腾讯控股"},{"code":"sh600519","name":"重复股票"},{"code":"sh000001","name":"重复指数"},{"code":123,"name":"错码"},{"code":"sh600000","name":null}]}"#
        let result = try TencentMarketDataProvider.parseSearchResults(payload)
        #expect(result.map(\.symbol) == ["sh600519", "sh510300", "sz161725", "sh000001", "sz000001", "sz399001"])
        #expect(result.map(\.kind) == [.stock, .etf, .lof, .index, .stock, .index])
        #expect(result.first?.name == "贵州茅台")
        #expect(try TencentMarketDataProvider.parseSearchResults(#"{"stock":[{}]}"#).isEmpty)
    }

    @Test func rejectsMissingFieldsZerosInvalidNumbersAndMismatchedCodes() throws {
        let instrument = Instrument(symbol: "sh600519", name: "贵州茅台")
        let payloads = [
            #"v_sh600519="1~贵州茅台~600519~1500";"#,
            syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "0", close: "1500", percent: "-100"),
            syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1500", close: "0", percent: "0"),
            syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1,500", close: "1490", percent: "0.67"),
            syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "NaN", close: "1490", percent: "0.67"),
            syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1500", close: "1490", percent: "--"),
            syntheticQuote(symbol: "sh600519", name: "", price: "1500", close: "1490", percent: "0.67"),
            syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1500", close: "1490", percent: "0.67", code: "600000"),
            "<html>Service unavailable</html>"
        ]
        for payload in payloads {
            #expect(throws: MarketDataError.noValidQuotes) {
                try TencentMarketDataProvider.parseQuotes(payload, requested: [instrument], fetchedAt: receivedAt)
            }
        }
    }

    @Test func validatesMarketDateAndRejectsFutureTimestamp() throws {
        let instrument = Instrument(symbol: "sh600519", name: "贵州茅台")
        for stamp in ["20260230154000", "20261106156000", "202611061540", "20271106154000"] {
            let payload = syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1500", close: "1490", percent: "0.67", stamp: stamp)
            #expect(throws: MarketDataError.noValidQuotes) {
                try TencentMarketDataProvider.parseQuotes(payload, requested: [instrument], fetchedAt: receivedAt)
            }
        }
        let old = syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1500", close: "1490", percent: "0.67", stamp: "20241106154000")
        let result = try TencentMarketDataProvider.parseQuotes(old, requested: [instrument], fetchedAt: receivedAt)
        #expect(result[0].timestamp < receivedAt.addingTimeInterval(-86_400))
        #expect(result[0].fetchedAt == receivedAt)
    }

    @Test func keepsValidRowsAndIgnoresUnrequestedRows() throws {
        let requested = [Instrument(symbol: "sh600519", name: "贵州茅台"), Instrument(symbol: "sh510300", name: "300ETF", kind: .etf)]
        let payload = [
            syntheticQuote(symbol: "sh600519", name: "贵州茅台", price: "1500", close: "1490", percent: "0.67"),
            #"v_sh510300="";"#,
            syntheticQuote(symbol: "sz161725", name: "白酒LOF", price: "0.891", close: "0.900", percent: "-1.00")
        ].joined(separator: "\n")
        let result = try TencentMarketDataProvider.parseQuotes(payload, requested: requested, fetchedAt: receivedAt)
        #expect(result.map(\.symbol) == ["sh600519"])
    }

    @Test func completeCodeSearchUsesQuoteEndpointAndReturnsConfirmedName() async throws {
        StubURLProtocol.state.install { request in
            #expect(request.url?.host == "qt.gtimg.cn")
            #expect(request.url?.path == "/q=sz161725")
            #expect(request.timeoutInterval == 8)
            return .response(status: 200, data: Data(syntheticQuote(symbol: "sz161725", name: "白酒LOF", price: "0.891", close: "0.900", percent: "-1.00").utf8))
        }
        let provider = TencentMarketDataProvider(session: makeStubSession())
        let results = try await provider.search("161725")
        #expect(results == [Instrument(symbol: "sz161725", name: "白酒LOF", kind: .lof)])
        #expect(StubURLProtocol.state.requests.count == 1)
    }

    @Test func ambiguousCodeSearchReturnsBothIndexAndStockFromOneQuoteBatch() async throws {
        let payload = [
            syntheticQuote(symbol: "sz000001", name: "平安银行", price: "12.30", close: "12.00", percent: "2.50"),
            syntheticQuote(symbol: "sh000001", name: "上证指数", price: "3300.25", close: "3300.00", percent: "0.01")
        ].joined()
        let provider = TencentMarketDataProvider(session: makeStubSession())
        for query in ["000001", " 000001\n"] {
            StubURLProtocol.state.install { request in
                #expect(request.url?.host == "qt.gtimg.cn")
                #expect(request.url?.path == "/q=sh000001,sz000001")
                return .response(status: 200, data: Data(payload.utf8))
            }
            let results = try await provider.search(query)
            #expect(results == [
                Instrument(symbol: "sh000001", name: "上证指数", kind: .index),
                Instrument(symbol: "sz000001", name: "平安银行", kind: .stock)
            ])
            #expect(StubURLProtocol.state.requests.count == 1)
        }
    }

    @Test func explicitMarketSearchOnlyResolvesTheRequestedIndexOrStock() async throws {
        let index = Instrument(symbol: "sh000001", name: "上证指数", kind: .index)
        let stock = Instrument(symbol: "sz000001", name: "平安银行", kind: .stock)
        let cases = [("SH000001", index), (" 000001.Sh\n", index),
                     (" sz000001 ", stock), ("000001.SZ", stock)]
        let provider = TencentMarketDataProvider(session: makeStubSession())
        for (query, expected) in cases {
            StubURLProtocol.state.install { request in
                #expect(request.url?.host == "qt.gtimg.cn")
                #expect(request.url?.path == "/q=\(expected.symbol)")
                return .response(status: 200, data: Data(syntheticQuote(
                    symbol: expected.symbol, name: expected.name,
                    price: "12.30", close: "12.00", percent: "2.50"
                ).utf8))
            }
            #expect(try await provider.search(query) == [expected])
            #expect(StubURLProtocol.state.requests.count == 1)
        }
    }

    @Test func indexNameSearchUsesSearchEndpointAndRetainsIndexCategory() async throws {
        StubURLProtocol.state.install { request in
            #expect(request.url?.host == "proxy.finance.qq.com")
            #expect(request.url?.path == "/cgi/cgi-bin/smartbox/search")
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.queryItems?.first(where: { $0.name == "query" })?.value == "上证指数")
            return .response(status: 200, data: Data(#"{"stock":[{"code":"sh000001","name":"上证指数","type":"ZS"}]}"#.utf8))
        }
        let provider = TencentMarketDataProvider(session: makeStubSession())
        #expect(try await provider.search("上证指数") == [Instrument(symbol: "sh000001", name: "上证指数", kind: .index)])
        #expect(StubURLProtocol.state.requests.count == 1)
    }

    @Test func shenzhenIndexCodeSearchAndIndexQuoteRefreshAreSupported() async throws {
        let indices = [
            Instrument(symbol: "sh000001", name: "上证指数", kind: .index),
            Instrument(symbol: "sz399001", name: "深证成指", kind: .index),
            Instrument(symbol: "sz399006", name: "创业板指", kind: .index)
        ]
        StubURLProtocol.state.install { request in
            #expect(request.url?.host == "qt.gtimg.cn")
            let symbols = try #require(request.url?.path).replacingOccurrences(of: "/q=", with: "").components(separatedBy: ",")
            let payload = indices.filter { symbols.contains($0.symbol) }.map {
                syntheticQuote(symbol: $0.symbol, name: $0.name, price: "3300.25", close: "3300.00", percent: "0.01")
            }.joined()
            return .response(status: 200, data: Data(payload.utf8))
        }
        let provider = TencentMarketDataProvider(session: makeStubSession())
        #expect(try await provider.search("399001") == [indices[1]])
        let quotes = try await provider.quotes(for: indices)
        #expect(quotes.map(\.symbol) == indices.map(\.symbol))
        #expect(quotes.allSatisfy { $0.price == Decimal(string: "3300.25") })
        #expect(StubURLProtocol.state.requests.count == 2)
    }

    @Test func ambiguousCodeOnlyReturnsCandidatesWithValidQuotes() async throws {
        let provider = TencentMarketDataProvider(session: makeStubSession())
        let candidates = [
            Instrument(symbol: "sh000001", name: "上证指数", kind: .index),
            Instrument(symbol: "sz000001", name: "平安银行", kind: .stock)
        ]
        for valid in candidates {
            StubURLProtocol.state.install { request in
                #expect(request.url?.path == "/q=sh000001,sz000001")
                let payload = candidates.map { candidate in
                    candidate.symbol == valid.symbol
                        ? syntheticQuote(symbol: candidate.symbol, name: candidate.name, price: "12.30", close: "12.00", percent: "2.50")
                        : "v_\(candidate.symbol)=\"\";"
                }.joined()
                return .response(status: 200, data: Data(payload.utf8))
            }
            #expect(try await provider.search("000001") == [valid])
            #expect(StubURLProtocol.state.requests.count == 1)
        }
        StubURLProtocol.state.install { _ in
            .response(status: 200, data: Data(#"v_sh000001="";v_sz000001="";"#.utf8))
        }
        await #expect(throws: MarketDataError.noValidQuotes) { try await provider.search("000001") }
        #expect(StubURLProtocol.state.requests.count == 1)
    }

    @Test func emptyBatchDoesNotRequestAndInvalidSymbolsFailBeforeRequest() async throws {
        StubURLProtocol.state.install { _ in .failure(URLError(.notConnectedToInternet)) }
        let provider = TencentMarketDataProvider(session: makeStubSession())
        #expect(try await provider.quotes(for: []).isEmpty)
        await #expect(throws: MarketDataError.invalidSymbol("sh900901")) {
            try await provider.quotes(for: [Instrument(symbol: "sh900901", name: "不支持的 B 股")])
        }
        for query in ["700001", "sh900901"] {
            await #expect(throws: MarketDataError.self) { try await provider.search(query) }
        }
        #expect(StubURLProtocol.state.requests.isEmpty)
    }

    @Test func batchesAtFiftyAndDeduplicatesSymbols() async throws {
        StubURLProtocol.state.install { request in
            let path = try #require(request.url?.path)
            let symbols = path.replacingOccurrences(of: "/q=", with: "").components(separatedBy: ",")
            #expect(symbols.count <= 50)
            let payload = symbols.map { syntheticQuote(symbol: $0, name: "合成测试证券", price: "12.00", close: "10.00", percent: "20.00") }.joined(separator: "\n")
            return .response(status: 200, data: Data(payload.utf8))
        }
        let provider = TencentMarketDataProvider(session: makeStubSession())
        let requested = (0..<51).map { Instrument(symbol: String(format: "sh600%03d", $0), name: "合成测试证券") }
        let results = try await provider.quotes(for: requested + [requested[0]])
        #expect(results.count == 51)
        #expect(StubURLProtocol.state.requests.count == 2)
    }

    @Test func propagatesNetworkAndHTTPFailuresWithoutInventingPrices() async throws {
        let provider = TencentMarketDataProvider(session: makeStubSession())
        let requested = [Instrument(symbol: "sh600519", name: "贵州茅台")]
        StubURLProtocol.state.install { _ in .failure(URLError(.notConnectedToInternet)) }
        await #expect(throws: URLError.self) { try await provider.quotes(for: requested) }
        StubURLProtocol.state.install { _ in .response(status: 429, data: Data("rate limited".utf8)) }
        await #expect(throws: MarketDataError.httpStatus(429)) { try await provider.quotes(for: requested) }
        StubURLProtocol.state.install { _ in .response(status: 204, data: Data()) }
        await #expect(throws: MarketDataError.httpStatus(204)) { try await provider.quotes(for: requested) }
    }

    @Test func searchFailureDoesNotPreventSubsequentCompleteCodeLookup() async throws {
        StubURLProtocol.state.install { request in
            if request.url?.host == "proxy.finance.qq.com" { return .response(status: 503, data: Data()) }
            return .response(status: 200, data: Data(syntheticQuote(symbol: "sh510300", name: "300ETF", price: "3.85", close: "3.80", percent: "1.32").utf8))
        }
        let provider = TencentMarketDataProvider(session: makeStubSession())
        await #expect(throws: MarketDataError.httpStatus(503)) { try await provider.search("沪深300") }
        let result = try await provider.search("510300.SH")
        #expect(result.first?.symbol == "sh510300")
        #expect(result.first?.kind == .etf)
    }

    @Test func rejectsEmptyEncodingAndMalformedSearchInsteadOfPretendingNoMatches() throws {
        #expect(throws: MarketDataError.invalidResponse) { try TencentMarketDataProvider.decodePayload(Data()) }
        #expect(throws: MarketDataError.invalidEncoding) { try TencentMarketDataProvider.decodePayload(Data([0xFF, 0xFF])) }
        #expect(throws: MarketDataError.invalidResponse) { try TencentMarketDataProvider.parseSearchResults("<html>Unavailable</html>") }
        for payload in [#"{"stock":[{"code":"sh600519","name":"\uZZZZ"}]}"#, #"{"fund":[]}"#, #"{"stock":null}"#, #"{"stock":{}}"#] {
            #expect(throws: MarketDataError.invalidResponse) { try TencentMarketDataProvider.parseSearchResults(payload) }
        }
    }

    @Test func recognizesConvertibleTradingCodesAndRejectsOtherDebtAndSubscriptionCodes() {
        let symbols = ["sh110059", "sh113052", "sh118003", "sz123189", "sz127045", "sz128138"]
        for symbol in symbols {
            #expect(TencentMarketDataProvider.kind(for: symbol) == .convertibleBond)
            let code = String(symbol.dropFirst(2))
            #expect(TencentMarketDataProvider.completeSymbols(from: code) == [symbol])
            #expect(TencentMarketDataProvider.completeSymbols(from: symbol.uppercased()) == [symbol])
            #expect(TencentMarketDataProvider.completeSymbols(from: code + "." + symbol.prefix(2).uppercased()) == [symbol])
        }
        for symbol in ["sh111001", "sh132001", "sh019001", "sh070059", "sh733052", "sh718003", "sz083189", "sz072714", "sz080002", "sz110059", "sh123189", "bj113052"] {
            #expect(TencentMarketDataProvider.kind(for: symbol, name: "合成转债") == nil)
        }
    }

    @Test func convertibleNameSearchIncludesPartialMatchesAndFiltersOtherBonds() async throws {
        StubURLProtocol.state.install { request in
            #expect(request.url?.host == "proxy.finance.qq.com")
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = try #require(components.queryItems)
            let items = Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            #expect(items["query"] == "兴业")
            #expect(items["stockFlag"] == "1")
            #expect(items["fundFlag"] == "1")
            return .response(status: 200, data: Data(#"{"stock":[{"code":"sh601166","name":"兴业银行","type":"GP-A"},{"code":"sh113052","name":"兴业转债","type":"ZQ-KZZ"},{"code":"sz127045","name":"合成转债","type":"ZQ-KZZ"},{"code":"sh111001","name":"合成交换债","type":"ZQ"},{"code":"sh733052","name":"合成申购","type":"ZQ"}],"fund":[{"code":"sh113052","name":"重复转债"}]}"#.utf8))
        }
        let result = try await TencentMarketDataProvider(session: makeStubSession()).search("兴业")
        #expect(result.map(\.symbol) == ["sh601166", "sh113052", "sz127045"])
        #expect(result.map(\.kind) == [.stock, .convertibleBond, .convertibleBond])
        #expect(StubURLProtocol.state.requests.count == 1)
    }

    @Test func convertibleCodeSearchConfirmsQuoteAndPreservesThreeDecimalChange() async throws {
        let instruments = [
            Instrument(symbol: "sh113052", name: "合成沪转债", kind: .convertibleBond),
            Instrument(symbol: "sz127045", name: "合成深转债", kind: .convertibleBond)
        ]
        let provider = TencentMarketDataProvider(session: makeStubSession())
        for instrument in instruments {
            for query in [instrument.code, instrument.symbol.uppercased(), instrument.code + "." + instrument.symbol.prefix(2).uppercased()] {
                StubURLProtocol.state.install { request in
                    #expect(request.url?.host == "qt.gtimg.cn")
                    #expect(request.url?.path == "/q=\(instrument.symbol)")
                    return .response(status: 200, data: Data(syntheticQuote(symbol: instrument.symbol, name: instrument.name, price: "123.457", close: "123.456", percent: "0.00").utf8))
                }
                #expect(try await provider.search(query) == [instrument])
                #expect(StubURLProtocol.state.requests.count == 1)
            }
        }
        let payload = instruments.map { syntheticQuote(symbol: $0.symbol, name: $0.name, price: "123.457", close: "123.456", percent: "0.00") }.joined()
        let quotes = try TencentMarketDataProvider.parseQuotes(payload, requested: instruments, fetchedAt: receivedAt)
        #expect(quotes.map(\.symbol) == instruments.map(\.symbol))
        #expect(quotes.allSatisfy { $0.price == Decimal(string: "123.457") && $0.change == Decimal(string: "0.001") && $0.source == .tencent })
    }

    @Test func convertibleDisplayPreservesPriceAndChangeTickAcrossScreens() {
        #expect(InstrumentKind.convertibleBond.displayName == "可转债")
        #expect(QuoteFormatting.price(Decimal(string: "123.457")!, kind: .convertibleBond) == "123.457")
        #expect(QuoteFormatting.price(123, kind: .convertibleBond) == "123.000")
        #expect(QuoteFormatting.signedPrice(Decimal(string: "0.001")!, kind: .convertibleBond) == "+0.001")
        #expect(QuoteFormatting.signedPrice(Decimal(string: "-0.001")!, kind: .convertibleBond) == "-0.001")
        #expect(QuoteFormatting.price(Decimal(string: "123.457")!, kind: .stock) == "123.46")
        #expect(QuoteFormatting.price(Decimal(string: "3.851")!, kind: .etf) == "3.851")
    }

    @Test func recognizesExplicitExchangesAndRejectsOutOfScopeCodes() {
        #expect(TencentMarketDataProvider.completeSymbols(from: "600519") == ["sh600519"])
        #expect(TencentMarketDataProvider.completeSymbols(from: "000001") == ["sh000001", "sz000001"])
        #expect(TencentMarketDataProvider.completeSymbols(from: "399001") == ["sz399001"])
        #expect(TencentMarketDataProvider.completeSymbols(from: "920001") == ["bj920001"])
        #expect(TencentMarketDataProvider.completeSymbols(from: "600519.SH") == ["sh600519"])
        #expect(TencentMarketDataProvider.completeSymbols(from: "SH000001") == ["sh000001"])
        #expect(TencentMarketDataProvider.completeSymbols(from: "000001.SZ") == ["sz000001"])
        #expect(TencentMarketDataProvider.completeSymbols(from: "700001") == [])
        #expect(TencentMarketDataProvider.completeSymbols(from: "上证指数") == nil)
        #expect(TencentMarketDataProvider.completeSymbols(from: "00001") == nil)
        #expect(TencentMarketDataProvider.completeSymbols(from: "sh000001&bad=1") == nil)
        #expect(TencentMarketDataProvider.kind(for: "sh900901") == nil)
        #expect(TencentMarketDataProvider.kind(for: "sh000001") == .index)
        #expect(TencentMarketDataProvider.kind(for: "sz000001") == .stock)
        #expect(TencentMarketDataProvider.kind(for: "sz399001") == .index)
        #expect(TencentMarketDataProvider.kind(for: "sz399006") == .index)
        #expect(TencentMarketDataProvider.kind(for: "hk00700") == nil)
        #expect(TencentMarketDataProvider.kind(for: "sh600519&bad=1") == nil)
    }

    @Test func modelsRoundTripForPersistenceAndWatchConnectivity() throws {
        let quote = Quote(symbol: "sh510300", name: "300ETF", price: Decimal(string: "3.85")!, previousClose: Decimal(string: "3.80")!, changePercent: Decimal(string: "1.32")!, timestamp: receivedAt, fetchedAt: receivedAt)
        let encoded = try JSONEncoder().encode(quote)
        #expect(try JSONDecoder().decode(Quote.self, from: encoded) == quote)
        let instrument = Instrument(symbol: " SH510300 ", name: "300ETF", kind: .etf)
        #expect(instrument.code == "510300")
        #expect(instrument.marketLabel == "沪")
        #expect(try JSONDecoder().decode(Instrument.self, from: JSONEncoder().encode(instrument)) == instrument)
    }
}

private func syntheticQuote(
    symbol: String, name: String, price: String, close: String, percent: String,
    stamp: String = "20261106154000", code: String? = nil
) -> String {
    var fields = Array(repeating: "", count: 40)
    fields[0] = "1"
    fields[1] = name
    fields[2] = code ?? String(symbol.dropFirst(2))
    fields[3] = price
    fields[4] = close
    fields[30] = stamp
    fields[32] = percent
    return "v_\(symbol)=\"\(fields.joined(separator: "~"))\";"
}

private func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
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
