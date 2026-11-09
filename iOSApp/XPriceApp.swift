import SwiftUI

@main
struct XPriceApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppStore(platform: .phone)

    var body: some Scene {
        WindowGroup {
            WatchlistView()
                .environmentObject(store)
                .tint(.accentColor)
                .preferredColorScheme(store.settings.phoneAppearance.preferredColorScheme)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    store.setActive(phase == .active)
                }
        }
    }
}

extension AppAppearance {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
