import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sina's publicly reachable, undocumented quote and suggestion endpoints.
/// Free access does not guarantee market coverage, latency or a refresh rate.
public struct SinaMarketDataProvider: MarketDataProviding {
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
            guard TencentMarketDataProvider.kind(for: instrument.symbol, name: instrument.name) != nil else {
                throw MarketDataError.invalidSymbol(instrument.symbol)
            }
            return seen.insert(instrument.symbol).inserted
        }

        var result: [Quote] = []
        for start in stride(from: 0, to: unique.count, by: Self.quoteBatchSize) {
            try Task.checkCancellation()
            let batch = Array(unique[start..<min(start + Self.quoteBatchSize, unique.count)])
            let symbols = batch.map(\.symbol).joined(separator: ",")
            guard let url = URL(string: "https://hq.sinajs.cn/list=\(symbols)") else {
                throw MarketDataError.invalidResponse
            }
            let payload = try TencentMarketDataProvider.decodePayload(try await load(url))
            result.append(contentsOf: try Self.parseQuotes(payload, requested: batch, fetchedAt: Date()))
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

        // Sina uses path parameters here. Encode the search text separately so
        // an ampersand in a user's query cannot become another path parameter.
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: safeCharacters),
              let url = URL(string: "https://suggest3.sinajs.cn/suggest/type=11,12,13,14,15&key=\(encoded)&name=suggestvalue") else {
            throw MarketDataError.invalidQuery
        }
        return try Self.parseSearchResults(TencentMarketDataProvider.decodePayload(try await load(url)))
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://finance.sina.com.cn/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw MarketDataError.invalidResponse }
        guard response.statusCode == 200 else { throw MarketDataError.httpStatus(response.statusCode) }
        guard data.count <= Self.maximumResponseBytes else { throw MarketDataError.responseTooLarge }
        return data
    }

    static func parseQuotes(_ payload: String, requested: [Instrument], fetchedAt: Date) throws -> [Quote] {
        guard !requested.isEmpty else { return [] }
        let requestedSymbols = Set(requested.map(\.symbol))
        let pattern = #"(?m)(?:^|(?<=;))\s*(?:var\s+)?hq_str_((?:sh|sz|bj)[0-9]{6})\s*=\s*"((?:\\.|[^"\\])*)"\s*;?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(payload.startIndex..<payload.endIndex, in: payload)
        let formatter = marketDateFormatter()
        var parsed: [String: Quote] = [:]

        for match in regex.matches(in: payload, range: range) {
            guard let symbolRange = Range(match.range(at: 1), in: payload),
                  let valueRange = Range(match.range(at: 2), in: payload) else { continue }
            let symbol = String(payload[symbolRange])
            guard requestedSymbols.contains(symbol),
                  let value = decodeJavaScriptString(String(payload[valueRange])) else { continue }
            let fields = value.components(separatedBy: ",")
            guard fields.count >= 32 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let stamp = fields[30] + " " + fields[31]
            guard !name.isEmpty,
                  let previousClose = decimal(fields[2]), previousClose > 0,
                  let price = decimal(fields[3]), price > 0,
                  stamp.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil,
                  let timestamp = formatter.date(from: stamp),
                  formatter.string(from: timestamp) == stamp,
                  timestamp <= fetchedAt.addingTimeInterval(300) else { continue }
            let percent = (price - previousClose) / previousClose * 100
            guard !percent.isNaN else { continue }
            parsed[symbol] = Quote(
                symbol: symbol, name: name, price: price, previousClose: previousClose,
                changePercent: percent, timestamp: timestamp, fetchedAt: fetchedAt, source: .sina
            )
        }

        let result = requested.compactMap { parsed.removeValue(forKey: $0.symbol) }
        guard !result.isEmpty else { throw MarketDataError.noValidQuotes }
        return result
    }

    static func parseSearchResults(_ payload: String) throws -> [Instrument] {
        let pattern = #"(?m)(?:^|(?<=;))\s*(?:var\s+)?suggestvalue\s*=\s*"((?:\\.|[^"\\])*)"\s*;?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(payload.startIndex..<payload.endIndex, in: payload)
        guard let match = regex.firstMatch(in: payload, range: range),
              let valueRange = Range(match.range(at: 1), in: payload),
              let value = decodeJavaScriptString(String(payload[valueRange])) else {
            throw MarketDataError.invalidResponse
        }
        var seen = Set<String>()
        return value.components(separatedBy: ";").compactMap { row in
            let fields = row.components(separatedBy: ",")
            guard fields.count >= 5, ["11", "13", "15"].contains(fields[1]) else { return nil }
            let symbol = fields[3].lowercased()
            let name = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            guard fields[2] == String(symbol.dropFirst(2)), !name.isEmpty,
                  let kind = TencentMarketDataProvider.kind(for: symbol, name: name),
                  seen.insert(symbol).inserted else { return nil }
            return Instrument(symbol: symbol, name: name, kind: kind)
        }
    }

    private static func decodeJavaScriptString(_ value: String) -> String? {
        // Returned data is a string literal, never executable JavaScript.
        try? JSONDecoder().decode(String.self, from: Data(("\"" + value + "\"").utf8))
    }

    private static func decimal(_ value: String) -> Decimal? {
        guard value.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { return nil }
        return number
    }

    private static func marketDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        return formatter
    }
}
