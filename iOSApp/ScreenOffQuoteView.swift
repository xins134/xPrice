import SwiftUI
import Combine
import UIKit

enum ScreenOffBrightnessSetting {
    static let defaultsKey = "xprice.screenOffBrightnessPercent.v1"
    static let defaultPercent = 10
    static let quoteFontSizeKey = "xprice.screenOffQuoteFontSize.v1"
    static let defaultQuoteFontSize = 13
    static let quoteFontSizeRange = 8...36

    static func percent(from defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: defaultsKey) as? Int else { return defaultPercent }
        return min(100, max(1, value))
    }

    static func brightness(from defaults: UserDefaults = .standard) -> CGFloat {
        CGFloat(percent(from: defaults)) / 100
    }
}

struct ScreenOffQuoteView: UIViewControllerRepresentable {
    @AppStorage(ScreenOffBrightnessSetting.quoteFontSizeKey)
    private var quoteFontSize = ScreenOffBrightnessSetting.defaultQuoteFontSize
    let store: AppStore
    var instrument: Instrument? = nil
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        ScreenOffQuoteController(store: store, instrument: instrument,
                                 typeSize: context.environment.dynamicTypeSize,
                                 quoteFontSize: CGFloat(quoteFontSize), onDismiss: onDismiss)
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard let controller = controller as? ScreenOffQuoteController else { return }
        controller.onDismiss = onDismiss
        if controller.rootView.instrument != instrument { controller.rootView.instrument = instrument }
        let typeSize = context.environment.dynamicTypeSize
        if controller.rootView.typeSize != typeSize { controller.rootView.typeSize = typeSize }
        let quoteFontSize = CGFloat(quoteFontSize)
        if controller.rootView.quoteFontSize != quoteFontSize { controller.rootView.quoteFontSize = quoteFontSize }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        (controller as? ScreenOffQuoteController)?.finishDisplaySession()
    }
}

@MainActor
private final class ScreenOffDisplayState: ObservableObject {
    @Published var showsQuotes = true
}

private struct ScreenOffQuoteContent: View {
    @ObservedObject var store: AppStore
    @ObservedObject var display: ScreenOffDisplayState
    var instrument: Instrument?
    var typeSize: DynamicTypeSize
    var quoteFontSize: CGFloat
    var screenInsets = EdgeInsets()
    let onDismiss: () -> Void

    var body: some View {
        ScreenOffQuoteLayout(store: store, display: display, instrument: instrument,
                             quoteFontSize: quoteFontSize, screenInsets: screenInsets, onDismiss: onDismiss)
            .dynamicTypeSize(typeSize)
    }
}

private struct ScreenOffQuoteLayout: View {
    @Environment(\.openURL) private var openURL
    @State private var isEastmoneyUnavailable = false
    @ObservedObject var store: AppStore
    @ObservedObject var display: ScreenOffDisplayState
    let instrument: Instrument?
    let quoteFontSize: CGFloat
    let screenInsets: EdgeInsets
    let onDismiss: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var scaledRowHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let instruments = displayedInstruments
            let columnCount = min(4, max(1, instruments.count))
            let rowCount = max(1, (instruments.count + columnCount - 1) / columnCount)
            let rowHeight = max(max(44, scaledRowHeight), quoteFontSize * 1.5)
            let contentHeight = CGFloat(rowCount) * rowHeight
            let availableHeight = max(0, geometry.size.height - screenInsets.top - screenInsets.bottom)

            ZStack(alignment: .top) {
                Button(action: toggleQuotes) {
                    Color.black
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(toggleLabel)

                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columnCount), spacing: 0) {
                        ForEach(instruments) { instrument in
                            let quote = store.quote(for: instrument)
                            let text = quote
                                .map { QuoteFormatting.percent($0.changePercent) } ?? "—"
                            ZStack {
                                Button {
                                    guard let url = EastmoneyLink.stockPage(for: instrument) else { return }
                                    openURL(url) { accepted in
                                        isEastmoneyUnavailable = !accepted
                                    }
                                } label: {
                                    Text(text)
                                        .font(.system(size: quoteFontSize, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(quote.map {
                                            QuoteColor.color(for: $0.changePercent, convention: store.settings.colorConvention)
                                        } ?? .secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.35)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(instrument.name)，涨跌幅 \(text)，在东方财富查看")
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: rowHeight)
                        }
                    }
                    .opacity(display.showsQuotes ? 1 : 0)
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDisabled(contentHeight <= availableHeight)
                .frame(maxWidth: .infinity)
                .frame(height: min(contentHeight, availableHeight))
                .background(.black)
                .contentShape(Rectangle())
                .allowsHitTesting(display.showsQuotes)
                .padding(.leading, screenInsets.leading)
                .padding(.trailing, screenInsets.trailing)
                .padding(.top, screenInsets.top)

                Button(action: onDismiss) {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: 100, height: 100)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dismissLabel)
                .accessibilityHint("退出熄屏模式")
                .frame(width: 100, height: 100)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .zIndex(1)
            }
            .alert("无法打开东方财富", isPresented: $isEastmoneyUnavailable) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请确认已安装东方财富 App，然后重试。")
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("熄屏行情")
        .accessibilityValue(display.showsQuotes ? "显示行情" : "行情已隐藏")
        .accessibilityAction(named: Text(toggleLabel), toggleQuotes)
        .accessibilityAction(named: Text(dismissLabel), onDismiss)
    }

    private var toggleLabel: String { display.showsQuotes ? "隐藏行情" : "显示行情" }
    private var dismissLabel: String { instrument == nil ? "返回首页" : "返回详情页" }

    private var displayedInstruments: [Instrument] {
        instrument.map { [$0] } ?? store.screenOffInstruments
    }

    private func toggleQuotes() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            display.showsQuotes.toggle()
            store.setScreenOffRefreshPaused(!display.showsQuotes)
        }
    }

}

@MainActor
private final class ScreenOffQuoteController: UIHostingController<ScreenOffQuoteContent> {
    var onDismiss: () -> Void
    private let store: AppStore
    private let display: ScreenOffDisplayState
    private weak var modeScene: UIWindowScene?
    private var modeScreen: UIScreen?
    private var originalBrightness: CGFloat?
    private var originalIdleTimerDisabled: Bool?
    private var displaySessionIsApplied = false
    private var isClosing = false

    init(store: AppStore, instrument: Instrument?, typeSize: DynamicTypeSize,
         quoteFontSize: CGFloat, onDismiss: @escaping () -> Void) {
        let display = ScreenOffDisplayState()
        self.store = store
        self.display = display
        self.onDismiss = onDismiss
        super.init(rootView: ScreenOffQuoteContent(store: store, display: display, instrument: instrument,
                                                 typeSize: typeSize, quoteFontSize: quoteFontSize,
                                                 onDismiss: onDismiss))
        rootView = ScreenOffQuoteContent(store: store, display: display, instrument: instrument,
                                        typeSize: typeSize, quoteFontSize: quoteFontSize,
                                        onDismiss: { [weak self] in
            self?.closeMode()
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
                           name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidActivate(_:)),
                           name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidEnterBackground(_:)),
                           name: UIScene.didEnterBackgroundNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Capture the screen from this window rather than the deprecated global main screen.
        startDisplaySession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The window can still be nil during the first viewWillAppear callback.
        startDisplaySession()
        updateScreenInsets()
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateScreenInsets()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateScreenInsets()
    }

    private func updateScreenInsets() {
        guard let window = view.window else { return }
        // Use physical window insets because the overlay fills the entire screen.
        let insets = window.safeAreaInsets
        let value = EdgeInsets(top: insets.top, leading: insets.left,
                               bottom: insets.bottom, trailing: insets.right)
        if rootView.screenInsets != value { rootView.screenInsets = value }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func finishDisplaySession() {
        isClosing = true
        restoreDisplaySession(animated: modeScene?.activationState == .foregroundActive)
        store.setScreenOffRefreshPaused(false)
        NotificationCenter.default.removeObserver(self)
    }

    private func startDisplaySession() {
        guard !isClosing, let scene = view.window?.windowScene else { return }
        modeScene = scene
        guard scene.activationState == .foregroundActive, !displaySessionIsApplied else { return }
        modeScreen = scene.screen
        // A quick return can interrupt our restoration; retain its target instead of
        // sampling an intermediate frame. Otherwise respect changes made outside the app.
        originalBrightness = ScreenBrightnessAnimator.shared.pendingTarget(on: scene.screen)
            ?? scene.screen.brightness
        originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        if let modeScreen {
            ScreenBrightnessAnimator.shared.transition(to: ScreenOffBrightnessSetting.brightness(),
                                                       on: modeScreen, in: scene)
        }
        UIApplication.shared.isIdleTimerDisabled = true
        displaySessionIsApplied = true
    }

    private func restoreDisplaySession(animated: Bool = true) {
        guard displaySessionIsApplied else { return }
        displaySessionIsApplied = false
        if let originalBrightness, let modeScreen, let modeScene {
            ScreenBrightnessAnimator.shared.transition(to: originalBrightness, on: modeScreen,
                                                       in: modeScene, animated: animated)
        }
        if let originalIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = originalIdleTimerDisabled
        }
    }

    private func closeMode() {
        guard !isClosing else { return }
        isClosing = true
        restoreDisplaySession()
        onDismiss()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === modeScene else { return }
        restoreDisplaySession()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === modeScene else { return }
        startDisplaySession()
    }

    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === modeScene else { return }
        restoreDisplaySession(animated: false)
    }
}

/// Owns short transitions so restoring brightness can finish after the page is removed.
@MainActor
private final class ScreenBrightnessAnimator: NSObject {
    static let shared = ScreenBrightnessAnimator()

    private struct Transition {
        let screen: UIScreen
        let scene: UIWindowScene
        let start: CGFloat
        let target: CGFloat
        let startedAt: CFTimeInterval
    }

    private var transitions: [ObjectIdentifier: Transition] = [:]
    private var displayLink: CADisplayLink?
    private let duration: CFTimeInterval = 0.4

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidEnterBackground(_:)),
                                               name: UIScene.didEnterBackgroundNotification, object: nil)
    }

    func pendingTarget(on screen: UIScreen) -> CGFloat? {
        transitions[ObjectIdentifier(screen)]?.target
    }

    func transition(to brightness: CGFloat, on screen: UIScreen, in scene: UIWindowScene,
                    animated: Bool = true) {
        let key = ObjectIdentifier(screen)
        let target = min(1, max(0, brightness))
        transitions.removeValue(forKey: key)
        guard animated, abs(screen.brightness - target) > 0.001 else {
            screen.brightness = target
            stopIfFinished()
            return
        }
        transitions[key] = Transition(screen: screen, scene: scene, start: screen.brightness,
                                      target: target, startedAt: CACurrentMediaTime())
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(updateBrightness(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func updateBrightness(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        for (key, transition) in transitions {
            let progress = min(1, max(0, (now - transition.startedAt) / duration))
            let eased = CGFloat(progress * progress * (3 - 2 * progress))
            transition.screen.brightness = transition.start + (transition.target - transition.start) * eased
            if progress >= 1 { transitions.removeValue(forKey: key) }
        }
        stopIfFinished()
    }

    @objc private func sceneDidEnterBackground(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        // Finish restoring before iOS suspends the app and stops display-link callbacks.
        for (key, transition) in transitions where transition.scene === scene {
            transition.screen.brightness = transition.target
            transitions.removeValue(forKey: key)
        }
        stopIfFinished()
    }

    private func stopIfFinished() {
        guard transitions.isEmpty else { return }
        displayLink?.invalidate()
        displayLink = nil
    }
}
