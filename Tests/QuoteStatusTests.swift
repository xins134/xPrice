import Foundation
import Testing
@testable import XPriceCore

struct QuoteStatusTests {
    private let now = Date(timeIntervalSince1970: 1_793_950_800)

    @Test func distinguishesNotFetchedFromFailedWithoutInventingAQuote() {
        let pending = QuoteStatus.evaluate(quote: nil, selectedSource: .eastmoney, session: .trading, now: now)
        #expect(pending.availability == .noQuote)
        #expect(pending.message == "尚未取价")
        #expect(pending.sourceLabel == "尚无报价来源")
        let failed = QuoteStatus.evaluate(quote: nil, selectedSource: .eastmoney, session: .trading, requestFailed: true, now: now)
        #expect(failed.availability == .noQuote)
        #expect(failed.requestFailed)
        #expect(failed.message.contains("取价失败"))
        #expect(!failed.usesPreviousSource)
    }

    @Test func failedRequestKeepsPriceTimeAndActualSourceVisibleAsCache() {
        let quote = sample(source: .tencent)
        let status = QuoteStatus.evaluate(quote: quote, selectedSource: .tencent, session: .trading, requestFailed: true, now: now)
        #expect(status.availability == .cachedQuote)
        #expect(status.badge == "失败缓存")
        #expect(status.sourceLabel == "腾讯")
        #expect(quote.price == Decimal(string: "3.851"))
        #expect(quote.timestamp == now)
        #expect(quote.source == .tencent)
    }

    @Test func switchingSelectionNeverRelabelsOldSourceEvenWithRecentTimestamp() {
        let quote = sample(source: .tencent)
        let status = QuoteStatus.evaluate(quote: quote, selectedSource: .eastmoney, session: .trading, now: now)
        #expect(status.usesPreviousSource)
        #expect(status.sourceLabel == "腾讯")
        #expect(status.message == "旧来源缓存")
        #expect(status.availability == .cachedQuote)
        #expect(quote.source == .tencent)
        let failed = QuoteStatus.evaluate(quote: quote, selectedSource: .sina, session: .trading, requestFailed: true, now: now)
        #expect(failed.requestFailed && failed.usesPreviousSource)
        #expect(failed.message.contains("取价失败") && failed.message.contains("旧来源缓存"))
        #expect(failed.badge == "失败·旧源")
    }

    @Test func legacyQuoteShowsUnknownSourceInsteadOfCurrentSelection() {
        let status = QuoteStatus.evaluate(quote: sample(source: nil), selectedSource: .sina, session: .trading, now: now)
        #expect(status.sourceLabel == "来源未记录")
        #expect(!status.usesPreviousSource)
        #expect(status.availability == .quote)
    }

    @Test func oldSourceTimeIsAnObservationWithoutClaimingTransportDelayOrSuspension() {
        let modestAge = QuoteStatus.evaluate(quote: sample(source: .sina, age: 120), selectedSource: .sina, session: .trading, now: now)
        #expect(!modestAge.hasEarlierSourceTime)
        #expect(modestAge.badge == nil)
        let earlier = QuoteStatus.evaluate(quote: sample(source: .sina, age: 301), selectedSource: .sina, session: .trading, now: now)
        #expect(earlier.hasEarlierSourceTime)
        #expect(earlier.message == "源时间较早")
        #expect(!earlier.requestFailed)
        #expect(!earlier.message.contains("延迟") && !earlier.message.contains("停牌"))
        #expect(earlier.availability == .quote)
    }

    @Test(arguments: [TradingSession.preMarket, .middayBreak, .afterHours, .weekend, .closedDay])
    func normalMarketClosureDoesNotTreatOldTimeAsAQuoteFailure(session: TradingSession) {
        let status = QuoteStatus.evaluate(quote: sample(source: .eastmoney, age: 86_400), selectedSource: .eastmoney, session: session, now: now)
        #expect(status.availability == .cachedQuote)
        #expect(status.marketLabel == session.displayName)
        #expect(status.message.contains("保留最近行情"))
        #expect(status.badge == "缓存")
        #expect(!status.hasEarlierSourceTime && !status.requestFailed)
    }

    @Test func partialFailureOnlyMarksTheRequestedFailedSymbol() {
        let quotes = [sample(source: .tencent), Quote(symbol: "sz000001", name: "合成股票", price: 12,
                                                      previousClose: 11, changePercent: 9,
                                                      timestamp: now, fetchedAt: now, source: .tencent)]
        let failures: Set<String> = [quotes[0].symbol]
        let statuses = quotes.map {
            QuoteStatus.evaluate(quote: $0, selectedSource: .tencent, session: .trading,
                                 requestFailed: failures.contains($0.symbol), now: now)
        }
        #expect(statuses[0].availability == .cachedQuote)
        #expect(statuses[1].availability == .quote)
        #expect(!statuses[1].requestFailed)
    }

    @Test(arguments: MarketDataSource.allCases)
    func quoteSourceSurvivesPersistence(source: MarketDataSource) throws {
        let quote = sample(source: source)
        let restored = try JSONDecoder().decode(Quote.self, from: JSONEncoder().encode(quote))
        #expect(restored == quote)
        #expect(restored.source == source)
    }

    @Test func legacyMissingNullAndFutureSourceRemainReadableWithoutFalseAttribution() throws {
        let quote = sample(source: .tencent)
        let encoded = try JSONEncoder().encode(quote)
        let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let replacements: [Any?] = [nil, NSNull(), "future-provider"]
        for replacement in replacements {
            var data = original
            if let replacement { data["source"] = replacement } else { data.removeValue(forKey: "source") }
            let restored = try JSONDecoder().decode(Quote.self, from: JSONSerialization.data(withJSONObject: data))
            #expect(restored.source == nil)
            #expect(restored.price == quote.price)
            #expect(restored.timestamp == quote.timestamp)
            #expect(restored.fetchedAt == quote.fetchedAt)
        }
    }

    @Test func allThreeParsersAttributeTheirSyntheticQuotesToTheActualProvider() throws {
        let instrument = Instrument(symbol: "sh510300", name: "合成ETF", kind: .etf)
        var tencent = Array(repeating: "", count: 40)
        tencent[1] = instrument.name; tencent[2] = "510300"
        tencent[3] = "3.851"; tencent[4] = "3.800"
        tencent[30] = "20261106154000"; tencent[32] = "1.34"
        let tencentQuotes = try TencentMarketDataProvider.parseQuotes("v_sh510300=\"\(tencent.joined(separator: "~"))\";", requested: [instrument], fetchedAt: now)
        var sina = Array(repeating: "", count: 32)
        sina[0] = instrument.name; sina[2] = "3.800"; sina[3] = "3.851"
        sina[30] = "2026-11-06"; sina[31] = "15:40:00"
        let sinaQuotes = try SinaMarketDataProvider.parseQuotes("var hq_str_sh510300=\"\(sina.joined(separator: ","))\";", requested: [instrument], fetchedAt: now)
        let eastmoney = Data(#"{"rc":0,"data":{"diff":[{"f12":"510300","f13":1,"f14":"合成ETF","f2":3.851,"f18":3.800,"f3":1.34,"f124":1793950800}]}}"#.utf8)
        let eastmoneyQuotes = try EastmoneyMarketDataProvider.parseQuotes(eastmoney, requested: [instrument], fetchedAt: now)
        #expect(tencentQuotes.first?.source == .tencent)
        #expect(sinaQuotes.first?.source == .sina)
        #expect(eastmoneyQuotes.first?.source == .eastmoney)
        #expect([tencentQuotes, sinaQuotes, eastmoneyQuotes].allSatisfy { $0.first?.price == Decimal(string: "3.851") })
    }

    @Test func selectedSourceReplacesNewerOldSourceCacheWithoutFakingItsTime() {
        let oldTencent = sample(source: .tencent)
        let delayedSina = sample(source: .sina, age: 30)
        #expect(QuoteMerge.shouldReplace(oldTencent, with: delayedSina, preferredSource: .sina))
        #expect(!QuoteMerge.shouldReplace(delayedSina, with: oldTencent, preferredSource: .sina))
        let status = QuoteStatus.evaluate(quote: delayedSina, selectedSource: .sina, session: .trading, now: now)
        #expect(!status.usesPreviousSource)
        #expect(status.sourceLabel == "新浪")
        #expect(delayedSina.timestamp == now.addingTimeInterval(-30))
    }

    @Test func selectedSourceReplacesUnknownLegacySourceButUnknownCannotOverwriteIt() {
        let unknown = sample(source: nil)
        let selected = sample(source: .eastmoney, age: 30)
        #expect(QuoteMerge.shouldReplace(unknown, with: selected, preferredSource: .eastmoney))
        #expect(!QuoteMerge.shouldReplace(selected, with: unknown, preferredSource: .eastmoney))
    }

    @Test func sameSourceStillRequiresLaterMarketOrReceiveTime() {
        let selected = sample(source: .sina)
        let earlier = sample(source: .sina, age: 30)
        let sameTimeReceivedLater = Quote(symbol: selected.symbol, name: selected.name, price: selected.price,
                                          previousClose: selected.previousClose, changePercent: selected.changePercent,
                                          timestamp: selected.timestamp, fetchedAt: selected.fetchedAt.addingTimeInterval(1),
                                          source: .sina)
        #expect(!QuoteMerge.shouldReplace(selected, with: earlier, preferredSource: .sina))
        #expect(!QuoteMerge.shouldReplace(selected, with: selected, preferredSource: .sina))
        #expect(QuoteMerge.shouldReplace(selected, with: sameTimeReceivedLater, preferredSource: .sina))
        #expect(!QuoteMerge.shouldReplace(sameTimeReceivedLater, with: selected, preferredSource: .sina))
    }

    @Test func omittedPreferenceAndTwoNonPreferredSourcesKeepTimestampOrdering() {
        let newerTencent = sample(source: .tencent)
        let olderSina = sample(source: .sina, age: 30)
        #expect(!QuoteMerge.shouldReplace(newerTencent, with: olderSina))
        #expect(QuoteMerge.shouldReplace(olderSina, with: newerTencent))
        #expect(!QuoteMerge.shouldReplace(newerTencent, with: olderSina, preferredSource: .eastmoney))
        #expect(QuoteMerge.shouldReplace(olderSina, with: newerTencent, preferredSource: .eastmoney))
        #expect(QuoteMerge.shouldReplace(nil, with: olderSina, preferredSource: .eastmoney))
    }

    private func sample(source: MarketDataSource?, age: TimeInterval = 0) -> Quote {
        Quote(symbol: "sh510300", name: "合成ETF", price: Decimal(string: "3.851")!,
              previousClose: Decimal(string: "3.800")!, changePercent: Decimal(string: "1.34")!,
              timestamp: now.addingTimeInterval(-age), fetchedAt: now, source: source)
    }
}
