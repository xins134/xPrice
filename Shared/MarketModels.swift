import Foundation

public enum InstrumentKind: String, Codable, CaseIterable, Sendable {
    case stock
    case index
    case etf
    case lof
    /// An exchange-traded fund whose more specific category is not known.
    case fund

    public var displayName: String {
        switch self {
        case .stock: "股票"
        case .index: "指数"
        case .etf: "ETF"
        case .lof: "LOF"
        case .fund: "基金"
        }
    }
}

public struct Instrument: Codable, Hashable, Identifiable, Sendable {
    public let symbol: String
    public let name: String
    public let kind: InstrumentKind

    public init(symbol: String, name: String, kind: InstrumentKind = .stock) {
        self.symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
    }

    public var id: String { symbol }
    public var code: String { String(symbol.dropFirst(2)) }

    public var marketLabel: String {
        switch symbol.prefix(2) {
        case "sh": "沪"
        case "sz": "深"
        case "bj": "北"
        default: "未知"
        }
    }
}

public struct Quote: Codable, Equatable, Sendable {
    public let symbol: String
    public let name: String
    public let price: Decimal
    public let previousClose: Decimal
    public let changePercent: Decimal
    /// The timestamp supplied by the quote service, interpreted in Asia/Shanghai.
    public let timestamp: Date
    /// When this device received the response. This is not the market timestamp.
    public let fetchedAt: Date
    /// The provider that actually returned this quote. Legacy caches leave it nil.
    public let source: MarketDataSource?

    public init(
        symbol: String,
        name: String,
        price: Decimal,
        previousClose: Decimal,
        changePercent: Decimal,
        timestamp: Date,
        fetchedAt: Date,
        source: MarketDataSource? = nil
    ) {
        self.symbol = symbol
        self.name = name
        self.price = price
        self.previousClose = previousClose
        self.changePercent = changePercent
        self.timestamp = timestamp
        self.fetchedAt = fetchedAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case symbol, name, price, previousClose, changePercent, timestamp, fetchedAt, source
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try values.decode(String.self, forKey: .symbol)
        name = try values.decode(String.self, forKey: .name)
        price = try values.decode(Decimal.self, forKey: .price)
        previousClose = try values.decode(Decimal.self, forKey: .previousClose)
        changePercent = try values.decode(Decimal.self, forKey: .changePercent)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
        let rawSource = try values.decodeIfPresent(String.self, forKey: .source)
        source = rawSource.flatMap(MarketDataSource.init(rawValue:))
    }

    public var change: Decimal { price - previousClose }
}

public protocol MarketDataProviding: Sendable {
    func quotes(for instruments: [Instrument]) async throws -> [Quote]
    func search(_ query: String) async throws -> [Instrument]
}

public enum MarketDataError: Error, LocalizedError, Equatable, Sendable {
    case invalidSymbol(String)
    case invalidQuery
    case invalidResponse
    case httpStatus(Int)
    case invalidEncoding
    case responseTooLarge
    case noValidQuotes

    public var errorDescription: String? {
        switch self {
        case .invalidSymbol(let symbol):
            "不支持的证券代码：\(symbol)。请使用 A 股、指数、ETF 或 LOF 的完整代码。"
        case .invalidQuery:
            "请输入证券名称或完整的 6 位证券代码。"
        case .invalidResponse:
            "行情接口返回了无法识别的内容，请稍后重试。"
        case .httpStatus(let status):
            "行情接口暂时不可用（HTTP \(status)）。"
        case .invalidEncoding:
            "无法解码行情接口返回的内容。"
        case .responseTooLarge:
            "行情接口返回的内容超出允许大小。"
        case .noValidQuotes:
            "未取得有效行情。证券可能不存在、暂不支持或接口暂时不可用。"
        }
    }
}
