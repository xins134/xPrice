// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Keep the parser and persisted-state policy testable without an iOS simulator.
let coreSources = [
    "MarketModels.swift",
    "TencentMarketDataProvider.swift",
    "EastmoneyMarketDataProvider.swift",
    "SinaMarketDataProvider.swift",
    "MarketDataProviders.swift",
    "AppSettings.swift",
    "SnapshotStore.swift",
    "TradingSchedule.swift",
    "QuoteStatus.swift",
    "QuoteRefreshCoordinator.swift",
    "SyncConfirmation.swift",
    "WatchlistBackup.swift",
]
let sharedDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Shared")
let excludedSources = (try? FileManager.default.contentsOfDirectory(atPath: sharedDirectory.path))?
    .filter { $0.hasSuffix(".swift") && !coreSources.contains($0) } ?? []

let package = Package(
    name: "xPrice",
    platforms: [.macOS(.v14), .iOS("26.0"), .watchOS("26.0")],
    products: [.library(name: "XPriceCore", targets: ["XPriceCore"])],
    targets: [
        .target(name: "XPriceCore", path: "Shared", exclude: excludedSources, sources: coreSources),
        .testTarget(name: "XPriceCoreTests", dependencies: ["XPriceCore"], path: "Tests"),
    ],
    swiftLanguageModes: [.v5]
)
