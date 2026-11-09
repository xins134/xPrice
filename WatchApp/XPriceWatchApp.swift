import SwiftUI

@main
struct XPriceWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppStore(platform: .watch)

    var body: some Scene {
        WindowGroup {
            WatchWatchlistView()
                .environmentObject(store)
                .tint(.accentColor)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    store.setActive(phase == .active)
                }
        }
    }
}
