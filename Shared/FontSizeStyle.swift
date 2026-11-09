import SwiftUI

extension AppFontSize {
    /// The default keeps the existing system size, including accessibility sizes.
    func dynamicTypeSize(relativeTo systemSize: DynamicTypeSize) -> DynamicTypeSize {
        let sizes = DynamicTypeSize.allCases.sorted()
        let offset: Int
        switch self {
        case .small: offset = -1
        case .smaller: offset = 0
        case .medium: offset = 1
        case .larger: offset = 2
        case .large: offset = 3
        }
        guard let index = sizes.firstIndex(of: systemSize) else { return systemSize }
        return sizes[min(max(index + offset, 0), sizes.count - 1)]
    }
}

private struct AppFontSizeModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var systemSize
    let size: AppFontSize

    func body(content: Content) -> some View {
        content.dynamicTypeSize(size.dynamicTypeSize(relativeTo: systemSize))
    }
}

extension View {
    func appFontSize(_ size: AppFontSize) -> some View {
        modifier(AppFontSizeModifier(size: size))
    }
}
