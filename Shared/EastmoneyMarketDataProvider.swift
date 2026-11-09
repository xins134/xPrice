import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Adapter for Eastmoney's public website endpoints, which have no API SLA.
/// `fltt=2` requests decimal prices and percentage points: an ETF price of
/// 3.851 is already 3.851, and must not be divided by 100 or rounded to cents.
public struct EastmoneyMarketDataProvider: MarketDataProviding {
    private let session: URLSession
    private static let maximumResponseBytes = 2_000_000
    private static let quoteBatchSize = 50

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func quotes(for instruments: [Instrument]) async throws -> [Quote] {
        guard !instruments.isEmpty else { return [] }
        var seen = Set<String>()
        let unique = try instruments.filter { instrument in
            guard Self.securityID(for: instrument.symbol) != nil else {
                throw MarketDataError.invalidSymbol(instrument.symbol)
            }
            return seen.insert(instrument.symbol).inserted
        }
        var result: [Quote] = []
        for start in stride(from: 0, to: unique.count, by: Self.quoteBatchSize) {
            try Task.checkCancellation()
            let batch = Array(unique[start..<min(start + Self.quoteBatchSize, unique.count)])
            let ids = batch.compactMap { Self.securityID(for: $0.symbol) }.joined(separator: ",")
            let url = try Self.url(host: "push2.eastmoney.com", path: "/api/qt/ulist.np/get", items: [
                URLQueryItem(name: "secids", value: ids),
                URLQueryItem(name: "fields", value: "f12,f13,f14,f2,f18,f3,f124"),
                URLQueryItem(name: "fltt", value: "2"),
                URLQueryItem(name: "invt", value: "2")
            ])
            let data = try await load(url)
            result.append(contentsOf: try Self.parseQuotes(data, requested: batch, fetchedAt: Date()))
        }
        return result
    }

    public func search(_ query: String) async throws -> [Instrument] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 64 else { throw MarketDataError.invalidQuery }
        if let symbols = TencentMarketDataProvider.completeSymbols(from: query) {
            guard !symbols.isEmpty else { throw MarketDataError.invalidSymbol(query) }
            let candidates = try symbols.map { symbol in
                guard let kind = TencentMarketDataProvider.kind(for: symbol) else {
                    throw MarketDataError.invalidSymbol(symbol)
                }
                return Instrument(symbol: symbol, name: symbol, kind: kind)
            }
            return try await quotes(for: candidates).compactMap { quote in
                guard let kind = TencentMarketDataProvider.kind(for: quote.symbol, name: quote.name) else { return nil }
                return Instrument(symbol: quote.symbol, name: quote.name, kind: kind)
            }
        }
        let url = try Self.url(host: "searchapi.eastmoney.com", path: "/api/suggest/get", items: [
            URLQueryItem(name: "input", value: query),
            URLQueryItem(name: "type", value: "14"),
            // Public website client identifier, not a user's API credential.
            URLQueryItem(name: "token", value: "D43BF722C8E33BDC906FB84D85E326E8")
        ])
        let data = try await load(url)
        return try Self.parseSearchResults(data)
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw MarketDataError.invalidResponse }
        guard response.statusCode == 200 else { throw MarketDataError.httpStatus(response.statusCode) }
        guard data.count <= Self.maximumResponseBytes else { throw MarketDataError.responseTooLarge }
        guard !data.isEmpty else { throw MarketDataError.invalidResponse }
        return data
    }

    static func securityID(for symbol: String) -> String? {
        guard TencentMarketDataProvider.kind(for: symbol) != nil else { return nil }
        // Eastmoney places Shenzhen and Beijing securities in market 0.
        return (symbol.hasPrefix("sh") ? "1." : "0.") + String(symbol.dropFirst(2))
    }

    static func parseQuotes(_ data: Data, requested: [Instrument], fetchedAt: Date) throws -> [Quote] {
        guard !requested.isEmpty else { return [] }
        let envelope: QuoteEnvelope = try decode(data)
        guard envelope.rc == 0 else { throw MarketDataError.invalidResponse }
        guard let body = envelope.data else { throw MarketDataError.noValidQuotes }
        guard let rows = body.diff else { throw MarketDataError.invalidResponse }
        let requestedByID = Dictionary(requested.compactMap { instrument -> (String, Instrument)? in
            guard let id = securityID(for: instrument.symbol) else { return nil }
            return (id, instrument)
        }, uniquingKeysWith: { first, _ in first })
        var parsed: [String: Quote] = [:]
        for row in rows {
            guard let code = row.code, code.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil,
                  let market = row.market?.value, market == 0 || market == 1,
                  let instrument = requestedByID["\(market == 1 ? 1 : 0).\(code)"],
                  let rawName = row.name else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  let price = row.price?.value, price > 0,
                  let previousClose = row.previousClose?.value, previousClose > 0,
                  let percent = row.percent?.value,
                  let stamp = row.timestamp?.value, stamp > 0 else { continue }
            var value = stamp
            var whole = Decimal()
            NSDecimalRound(&whole, &value, 0, .plain)
            guard whole == stamp else { continue }
            let seconds = NSDecimalNumber(decimal: stamp).doubleValue
            guard seconds.isFinite else { continue }
            let timestamp = Date(timeIntervalSince1970: seconds)
            guard timestamp <= fetchedAt.addingTimeInterval(300) else { continue }
            parsed[instrument.symbol] = Quote(
                symbol: instrument.symbol, name: name, price: price,
                previousClose: previousClose, changePercent: percent,
                timestamp: timestamp, fetchedAt: fetchedAt, source: .eastmoney
            )
        }
        let result = requested.compactMap { parsed.removeValue(forKey: $0.symbol) }
        guard !result.isEmpty else { throw MarketDataError.noValidQuotes }
        return result
    }

    static func parseSearchResults(_ data: Data) throws -> [Instrument] {
        let envelope: SearchEnvelope = try decode(data)
        let table = envelope.table
        guard table.status == 0 else { throw MarketDataError.invalidResponse }
        var seen = Set<String>()
        return (table.rows ?? []).compactMap { row in
            guard let id = row.quoteID, let code = row.code,
                  id == "0.\(code)" || id == "1.\(code)",
                  let rawName = row.name else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let candidates = id.hasPrefix("1.") ? ["sh" + code] : ["sz" + code, "bj" + code]
            guard let symbol = candidates.first(where: { TencentMarketDataProvider.kind(for: $0, name: name) != nil }),
                  let kind = TencentMarketDataProvider.kind(for: symbol, name: name),
                  seen.insert(symbol).inserted else { return nil }
            return Instrument(symbol: symbol, name: name, kind: kind)
        }
    }

    private static func url(host: String, path: String, items: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = items
        guard let url = components.url else { throw MarketDataError.invalidResponse }
        return url
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MarketDataError.invalidResponse }
    }

    private struct Number: Decodable {
        let value: Decimal?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                guard text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil else {
                    value = nil
                    return
                }
                let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
                value = number.flatMap { $0.isNaN ? nil : $0 }
            } else if let number = try? container.decode(Decimal.self), !number.isNaN {
                value = number
            } else {
                value = nil
            }
        }
    }

    private struct QuoteEnvelope: Decodable {
        let rc: Int
        let data: QuoteBody?
    }

    private struct QuoteBody: Decodable {
        let diff: [QuoteRow]?
    }

    private struct QuoteRow: Decodable {
        let code: String?
        let market: Number?
        let name: String?
        let price: Number?
        let previousClose: Number?
        let percent: Number?
        let timestamp: Number?

        private enum CodingKeys: String, CodingKey {
            case code = "f12", market = "f13", name = "f14", price = "f2"
            case previousClose = "f18", percent = "f3", timestamp = "f124"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            code = try? values.decode(String.self, forKey: .code)
            market = try? values.decode(Number.self, forKey: .market)
            name = try? values.decode(String.self, forKey: .name)
            price = try? values.decode(Number.self, forKey: .price)
            previousClose = try? values.decode(Number.self, forKey: .previousClose)
            percent = try? values.decode(Number.self, forKey: .percent)
            timestamp = try? values.decode(Number.self, forKey: .timestamp)
        }
    }

    private struct SearchEnvelope: Decodable {
        let table: SearchTable
        private enum CodingKeys: String, CodingKey { case table = "QuotationCodeTable" }
    }

    private struct SearchTable: Decodable {
        let status: Int
        let rows: [SearchRow]?
        private enum CodingKeys: String, CodingKey { case status = "Status", rows = "Data" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            status = try values.decode(Int.self, forKey: .status)
            guard values.contains(.rows) else {
                throw DecodingError.keyNotFound(CodingKeys.rows, .init(codingPath: decoder.codingPath, debugDescription: "Missing search result data"))
            }
            rows = try values.decodeIfPresent([SearchRow].self, forKey: .rows)
        }
    }

    private struct SearchRow: Decodable {
        let code: String?
        let name: String?
        let quoteID: String?
        private enum CodingKeys: String, CodingKey { case code = "Code", name = "Name", quoteID = "QuoteID" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            code = try? values.decode(String.self, forKey: .code)
            name = try? values.decode(String.self, forKey: .name)
            quoteID = try? values.decode(String.self, forKey: .quoteID)
        }
    }
}
