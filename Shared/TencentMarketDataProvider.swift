import CoreFoundation
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Adapter for Tencent's public, undocumented quote and search endpoints.
/// Availability, coverage, timing and a particular refresh rate are not guaranteed.
/// The parser is deliberately strict; a failed request never becomes a zero quote.
public struct TencentMarketDataProvider: MarketDataProviding {
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
            guard Self.kind(for: instrument.symbol, name: instrument.name) != nil else {
                throw MarketDataError.invalidSymbol(instrument.symbol)
            }
            return seen.insert(instrument.symbol).inserted
        }

        var result: [Quote] = []
        for start in stride(from: 0, to: unique.count, by: Self.quoteBatchSize) {
            try Task.checkCancellation()
            let batch = Array(unique[start..<min(start + Self.quoteBatchSize, unique.count)])
            let joinedSymbols = batch.map(\.symbol).joined(separator: ",")
            guard let url = URL(string: "https://qt.gtimg.cn/q=\(joinedSymbols)") else {
                throw MarketDataError.invalidResponse
            }
            let response = try await load(url)
            result.append(contentsOf: try Self.parseQuotes(
                Self.decodePayload(response),
                requested: batch,
                fetchedAt: Date()
            ))
        }
        return result
    }

    public func search(_ query: String) async throws -> [Instrument] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 64 else { throw MarketDataError.invalidQuery }

        // Resolve every supported market for a bare code: sh000001 is an index,
        // while sz000001 is a stock. Confirm each candidate through quotes so
        // code search still works independently of the name-search endpoint.
        if let symbols = Self.completeSymbols(from: query) {
            guard !symbols.isEmpty else { throw MarketDataError.invalidSymbol(query) }
            let candidates = try symbols.map { symbol in
                guard let category = Self.kind(for: symbol) else {
                    throw MarketDataError.invalidSymbol(symbol)
                }
                return Instrument(symbol: symbol, name: symbol, kind: category)
            }
            let found = try await quotes(for: candidates)
            return found.compactMap { quote in
                guard let category = Self.kind(for: quote.symbol, name: quote.name) else { return nil }
                return Instrument(symbol: quote.symbol, name: quote.name, kind: category)
            }
        }

        var components = URLComponents()
        components.scheme = "https"
        // Tencent's current website search includes convertible bonds, which
        // the older smartbox.gtimg.cn endpoint omits even for exact names.
        components.host = "proxy.finance.qq.com"
        components.path = "/cgi/cgi-bin/smartbox/search"
        components.queryItems = [
            URLQueryItem(name: "stockFlag", value: "1"),
            URLQueryItem(name: "fundFlag", value: "1"),
            URLQueryItem(name: "app", value: "official_website"),
            URLQueryItem(name: "c", value: "1"),
            URLQueryItem(name: "query", value: query)
        ]
        guard let url = components.url else { throw MarketDataError.invalidQuery }
        return try Self.parseSearchResults(Self.decodePayload(try await load(url)))
    }

    private func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw MarketDataError.invalidResponse }
        guard response.statusCode == 200 else { throw MarketDataError.httpStatus(response.statusCode) }
        guard data.count <= Self.maximumResponseBytes else { throw MarketDataError.responseTooLarge }
        return data
    }

    static func decodePayload(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw MarketDataError.invalidResponse }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        guard let decoded = String(data: data, encoding: gb18030) else {
            throw MarketDataError.invalidEncoding
        }
        return decoded
    }

    static func parseQuotes(_ payload: String, requested: [Instrument], fetchedAt: Date) throws -> [Quote] {
        guard !requested.isEmpty else { return [] }
        let requestedBySymbol = Dictionary(requested.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        // A batch may put assignments on separate lines or directly after a
        // semicolon. Do not consume that boundary when finding the next row.
        let pattern = #"(?m)(?:^|(?<=;))\s*v_((?:sh|sz|bj)[0-9]{6})\s*=\s*"((?:\\.|[^"\\])*)"\s*;?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(payload.startIndex..<payload.endIndex, in: payload)
        let formatter = marketDateFormatter()
        var parsed: [String: Quote] = [:]

        for match in regex.matches(in: payload, range: range) {
            guard let symbolRange = Range(match.range(at: 1), in: payload),
                  let valueRange = Range(match.range(at: 2), in: payload) else { continue }
            let symbol = String(payload[symbolRange])
            guard requestedBySymbol[symbol] != nil,
                  let value = decodeJavaScriptString(String(payload[valueRange])) else { continue }
            let fields = value.components(separatedBy: "~")
            guard fields.count > 32 else { continue }
            let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let stamp = fields[30]
            guard !name.isEmpty,
                  fields[2] == String(symbol.dropFirst(2)),
                  let price = decimal(fields[3]), price > 0,
                  let previousClose = decimal(fields[4]), previousClose > 0,
                  let percent = decimal(fields[32]),
                  stamp.count == 14, stamp.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let timestamp = formatter.date(from: stamp),
                  formatter.string(from: timestamp) == stamp,
                  timestamp <= fetchedAt.addingTimeInterval(300) else { continue }

            parsed[symbol] = Quote(
                symbol: symbol, name: name, price: price, previousClose: previousClose,
                changePercent: percent, timestamp: timestamp, fetchedAt: fetchedAt, source: .tencent
            )
        }
        let result = requested.compactMap { parsed.removeValue(forKey: $0.symbol) }
        guard !result.isEmpty else { throw MarketDataError.noValidQuotes }
        return result
    }

    static func parseSearchResults(_ payload: String) throws -> [Instrument] {
        let envelope: SearchEnvelope
        do { envelope = try JSONDecoder().decode(SearchEnvelope.self, from: Data(payload.utf8)) }
        catch { throw MarketDataError.invalidResponse }
        var seen = Set<String>()
        return (envelope.stock + (envelope.fund ?? [])).compactMap { row in
            guard let code = row.code, let rawName = row.name else { return nil }
            let symbol = code.lowercased()
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let category = kind(for: symbol, name: name),
                  seen.insert(symbol).inserted else { return nil }
            return Instrument(symbol: symbol, name: name, kind: category)
        }
    }

    private struct SearchEnvelope: Decodable {
        let stock: [SearchRow]
        let fund: [SearchRow]?
    }

    private struct SearchRow: Decodable {
        let code: String?
        let name: String?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            do { code = try values.decodeIfPresent(String.self, forKey: .code) }
            catch DecodingError.typeMismatch(_, _) { code = nil }
            do { name = try values.decodeIfPresent(String.self, forKey: .name) }
            catch DecodingError.typeMismatch(_, _) { name = nil }
        }

        private enum CodingKeys: String, CodingKey { case code, name }
    }

    static func completeSymbols(from input: String) -> [String]? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if input.range(of: #"^(sh|sz|bj)[0-9]{6}$"#, options: .regularExpression) != nil { return [input] }
        if input.range(of: #"^[0-9]{6}\.(sh|sz|bj)$"#, options: .regularExpression) != nil {
            return [String(input.suffix(2)) + String(input.prefix(6))]
        }
        guard input.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else { return nil }
        return ["sh", "sz", "bj"].map { $0 + input }.filter { kind(for: $0) != nil }
    }

    static func kind(for symbol: String, name: String = "") -> InstrumentKind? {
        guard symbol.range(of: #"^(sh|sz|bj)[0-9]{6}$"#, options: .regularExpression) != nil else { return nil }
        let code = String(symbol.dropFirst(2))
        let exchange = symbol.prefix(2)
        let isIndex = (exchange == "sh" && (code.hasPrefix("000") || code.hasPrefix("950")))
            || (exchange == "sz" && code.hasPrefix("399"))
            || (exchange == "bj" && code.hasPrefix("899"))
        if isIndex { return .index }
        // Exchange-traded convertible bonds only: subscription/allotment codes,
        // ordinary bonds and Shanghai 111 exchangeable bonds stay out of scope.
        let isConvertibleBond = (exchange == "sh" && ["110", "113", "118"].contains { code.hasPrefix($0) })
            || (exchange == "sz" && ["123", "127", "128"].contains { code.hasPrefix($0) })
        if isConvertibleBond { return .convertibleBond }
        let isStock: Bool
        switch exchange {
        case "sh": isStock = ["600", "601", "603", "605", "688", "689"].contains { code.hasPrefix($0) }
        case "sz": isStock = ["000", "001", "002", "003", "300", "301"].contains { code.hasPrefix($0) }
        case "bj": isStock = code.hasPrefix("4") || code.hasPrefix("8") || code.hasPrefix("92")
        default: return nil
        }
        if isStock { return .stock }
        let isFund = (exchange == "sh" && ["50", "51", "52", "56", "58"].contains { code.hasPrefix($0) })
            || (exchange == "sz" && (code.hasPrefix("15") || code.hasPrefix("16")))
        guard isFund else { return nil }
        let name = name.uppercased()
        if name.contains("ETF") { return .etf }
        if name.contains("LOF") { return .lof }
        if exchange == "sz", code.hasPrefix("159") { return .etf }
        if exchange == "sz", code.hasPrefix("16") { return .lof }
        if exchange == "sh", ["501", "502", "506"].contains(where: { code.hasPrefix($0) }) { return .lof }
        if exchange == "sh", ["510", "511", "512", "513", "515", "516", "517", "518", "520", "560", "561", "562", "563", "588", "589"].contains(where: { code.hasPrefix($0) }) { return .etf }
        return .fund
    }

    private static func decodeJavaScriptString(_ value: String) -> String? {
        // Decode only a string literal, never evaluate returned JavaScript.
        try? JSONDecoder().decode(String.self, from: Data(("\"" + value + "\"").utf8))
    }

    private static func decimal(_ value: String) -> Decimal? {
        guard value.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil else { return nil }
        guard let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !result.isNaN else { return nil }
        return result
    }

    private static func marketDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.isLenient = false
        return formatter
    }
}
