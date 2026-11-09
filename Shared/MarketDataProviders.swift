import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Each device creates its provider from the persisted, synced source selection.
public enum MarketDataProviders {
    public static func make(source: MarketDataSource, session: URLSession = .shared) -> any MarketDataProviding {
        switch source {
        case .tencent: TencentMarketDataProvider(session: session)
        case .eastmoney: EastmoneyMarketDataProvider(session: session)
        case .sina: SinaMarketDataProvider(session: session)
        }
    }
}
