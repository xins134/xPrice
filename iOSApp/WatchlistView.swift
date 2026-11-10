import SwiftUI
import Combine
import UIKit

@MainActor
private final class WatchlistScreenState: ObservableObject {
    @Published var showingSearch = false
    @Published var showingOverviewSearch = false
    @Published var showingOverviewManager = false
    @Published var showingSettings = false
    @Published var showingScreenOff = false
    @Published var screenOffInstrument: Instrument?
    @Published var screenOffBlocksHome = false
    @Published var showingScreenOffSetup = false
    @Published var path: [Instrument] = []
}

struct WatchlistView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var scaledOverviewHeight: CGFloat = 88
    @StateObject private var ui = WatchlistScreenState()

    var body: some View {
        NavigationStack(path: $ui.path) {
            quoteList
            .navigationTitle("自选")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("设置", systemImage: "slider.horizontal.3") { ui.showingSettings = true }
                        .labelStyle(.iconOnly)
                        .tint(store.settings.buttonTheme.color)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("一键熄屏", systemImage: "moon.zzz") {
                        presentScreenOff()
                    }
                    .labelStyle(.iconOnly)
                    .tint(store.settings.buttonTheme.color)
                    .accessibilityIdentifier("home.screenOff")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("添加自选", systemImage: "plus") { ui.showingSearch = true }
                        .labelStyle(.iconOnly)
                        .tint(store.settings.buttonTheme.color)
                }
            }
            .navigationDestination(for: Instrument.self) { instrument in
                InstrumentDetailView(instrument: instrument) {
                    presentScreenOff(instrument: instrument)
                }
            }
            .sheet(isPresented: $ui.showingSearch) { StockSearchView() }
            .sheet(isPresented: $ui.showingOverviewSearch) { StockSearchView(destination: .overview) }
            .sheet(isPresented: $ui.showingOverviewManager) { OverviewManagementView() }
            .sheet(isPresented: $ui.showingSettings) { SettingsView() }
            .alert("先选择熄屏行情", isPresented: $ui.showingScreenOffSetup) {
                Button("好", role: .cancel) {}
            } message: {
                Text("在自选详情中开启“显示在熄屏行情”，每行最多显示 4 个涨跌幅，超过后多行显示。点击涨跌幅可打开东方财富，屏幕中央区域退出熄屏模式，其他区域隐藏或再次显示行情。")
            }
            .onOpenURL { url in
                guard url.scheme == "xprice", url.host == "quote",
                      let instrument = (store.watchlist + store.overviewInstruments)
                        .first(where: { $0.symbol == url.lastPathComponent }) else { return }
                ui.path = [instrument]
            }
        }
        .allowsHitTesting(!ui.screenOffBlocksHome)
        .accessibilityHidden(ui.screenOffBlocksHome)
        .overlay {
            if ui.showingScreenOff {
                ScreenOffQuoteView(store: store, instrument: ui.screenOffInstrument) {
                    dismissScreenOff()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .statusBarHidden(ui.screenOffBlocksHome)
        .persistentSystemOverlays(ui.screenOffBlocksHome ? .hidden : .automatic)
    }

    private func presentScreenOff(instrument: Instrument? = nil) {
        guard instrument != nil || !store.screenOffInstruments.isEmpty else {
            ui.showingScreenOffSetup = true
            return
        }
        ui.screenOffInstrument = instrument
        ui.screenOffBlocksHome = true
        withAnimation(.easeInOut(duration: 0.2)) {
            ui.showingScreenOff = true
        }
    }

    private func dismissScreenOff() {
        guard ui.showingScreenOff else { return }
        withAnimation(.easeInOut(duration: 0.2), completionCriteria: .removed) {
            ui.showingScreenOff = false
        } completion: {
            // Keep the underlying page inactive until the fading screen is removed.
            if !ui.showingScreenOff {
                ui.screenOffBlocksHome = false
                ui.screenOffInstrument = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("关心的价格，一眼看到")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("添加 A 股、指数、ETF、LOF 或可转债，\n在 iPhone 和 Apple Watch 查看行情。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                ui.showingSearch = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                    Text("添加第一只自选")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.headline)
                .foregroundStyle(colorScheme == .dark ? .black : .white)
            }
            .buttonStyle(.borderedProminent)
            .tint(store.settings.buttonTheme.color)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
    }

    private var quoteList: some View {
        let widgetSymbol = store.widgetInstrument?.symbol
        let overviewSymbols = Set(store.overviewInstruments.map(\.symbol))
        return List {
            Section {
                if store.watchlist.isEmpty { emptyState }
                ForEach(store.watchlist) { instrument in
                    NavigationLink(value: instrument) {
                        QuoteRow(instrument: instrument, quote: store.quote(for: instrument),
                                 colorConvention: store.settings.colorConvention,
                                 isWidget: widgetSymbol == instrument.symbol, typeSize: typeSize)
                            .equatable()
                    }
                    .contextMenu {
                        Button("显示在表盘", systemImage: "applewatch") { store.selectWidgetSymbol(instrument.symbol) }
                            .tint(store.settings.buttonTheme.color)
                        Button("添加到行情栏", systemImage: "plus.rectangle.on.rectangle") {
                            store.addToOverview(instrument)
                        }
                        .tint(store.settings.buttonTheme.color)
                        .disabled(overviewSymbols.contains(instrument.symbol)
                                  || store.overviewInstruments.count >= 50)
                        Button("上移", systemImage: "arrow.up") { store.move(instrument, by: -1) }
                            .tint(store.settings.buttonTheme.color)
                        Button("下移", systemImage: "arrow.down") { store.move(instrument, by: 1) }
                            .tint(store.settings.buttonTheme.color)
                        Button("删除自选", systemImage: "trash", role: .destructive) { store.remove(instrument) }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) { store.remove(instrument) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("表盘", systemImage: "applewatch") { store.selectWidgetSymbol(instrument.symbol) }
                            .tint(store.settings.buttonTheme.color)
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
                .onDelete { offsets in
                    let selected = offsets.map { store.watchlist[$0] }
                    selected.forEach { store.remove($0) }
                }
            } header: {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        refreshStatus
                            .padding(.horizontal, 4)
                        marketOverview
                    }
                    HStack {
                        Text("全部自选 · \(store.watchlist.count)")
                        Spacer()
                        Text("现价 / 涨跌幅")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .textCase(nil)
                .foregroundStyle(.primary)
                .padding(.bottom, 8)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } footer: {
                Text("人民币报价 · 涨跌幅相对昨收\n行情时间为北京时间，公开接口可能延迟。")
                    .padding(.top, 8)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    private var marketOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("行情概览")
                    .font(.subheadline.weight(.medium))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("管理") { ui.showingOverviewManager = true }
                    .tint(store.settings.buttonTheme.color)
                    .foregroundStyle(.tint)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("管理行情栏")
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)

            if store.overviewInstruments.isEmpty {
                Button {
                    ui.showingOverviewSearch = true
                } label: {
                    VStack(alignment: .center, spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.title2)
                            .foregroundStyle(store.settings.buttonTheme.color)
                            .accessibilityHidden(true)
                        Text("添加证券")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(store.settings.buttonTheme.color)
                        Text("左右滑动查看多个行情")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 96)
                }
                .buttonStyle(.plain)
                .tint(store.settings.buttonTheme.color)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(store.overviewInstruments) { instrument in
                            OverviewQuoteControl(
                                instrument: instrument, quote: store.quote(for: instrument),
                                colorConvention: store.settings.colorConvention,
                                tint: store.settings.buttonTheme.color,
                                canMoveEarlier: store.overviewInstruments.first?.symbol != instrument.symbol,
                                canMoveLater: store.overviewInstruments.last?.symbol != instrument.symbol,
                                openDetail: { ui.path.append(instrument) },
                                moveEarlier: { store.moveOverview(instrument, by: -1) },
                                moveLater: { store.moveOverview(instrument, by: 1) },
                                remove: { store.removeFromOverview(instrument) }
                            )
                            .containerRelativeFrame(.horizontal, count: 3, spacing: 8)
                            .frame(height: overviewHeight)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: overviewHeight)
            }
        }
    }

    private var refreshStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .accessibilityHidden(true)
                Text(store.isRefreshing ? "正在获取行情" :
                     store.settings.smartRefreshEnabled && !store.tradingSession.isTrading
                     ? "休市期间降低刷新频率" : "每 \(store.refreshSeconds) 秒请求更新")
                Spacer()
                Button("立即刷新", systemImage: "arrow.clockwise") {
                    Task { await store.refresh() }
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .tint(store.settings.buttonTheme.color)
                .foregroundStyle(store.settings.buttonTheme.color)
                .disabled(store.isRefreshing)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let error = store.errorMessage {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var overviewHeight: CGFloat {
        max(typeSize.isAccessibilitySize ? 160 : 88, scaledOverviewHeight)
    }
}

// Give each card its own native interaction; the list header shares a SwiftUI menu host.
private struct OverviewQuoteControl: UIViewRepresentable {
    let instrument: Instrument
    let quote: Quote?
    let colorConvention: PriceColorConvention
    let tint: Color
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let openDetail: () -> Void
    let moveEarlier: () -> Void
    let moveLater: () -> Void
    let remove: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> OverviewQuoteControlView {
        let view = OverviewQuoteControlView(frame: .zero)
        view.addTarget(context.coordinator, action: #selector(Coordinator.openDetail), for: .touchUpInside)
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        context.coordinator.control = view
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: OverviewQuoteControlView, context: Context) {
        context.coordinator.parent = self
        view.update(card: OverviewQuoteCard(instrument: instrument, quote: quote,
                                           colorConvention: colorConvention,
                                           typeSize: context.environment.dynamicTypeSize))
        view.tintColor = UIColor(tint)
        view.accessibilityLabel = [instrument.name, quote.map { QuoteFormatting.price($0.price, kind: instrument.kind) },
                                   quote.map { QuoteFormatting.percent($0.changePercent) } ?? "等待行情"]
            .compactMap { $0 }.joined(separator: "，")
        view.accessibilityHint = "查看行情详情，长按管理行情"
        view.accessibilityCustomActions = context.coordinator.accessibilityActions()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: OverviewQuoteControlView,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: OverviewQuoteControl
        weak var control: OverviewQuoteControlView?
        private var isShowingMenu = false

        init(parent: OverviewQuoteControl) { self.parent = parent }

        @objc func openDetail() {
            guard !isShowingMenu else { return }
            parent.openDetail()
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let control, control.bounds.contains(location) else { return nil }
            return UIContextMenuConfiguration(identifier: parent.instrument.symbol as NSString,
                                              previewProvider: nil) { [weak self] _ in
                self?.menu()
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
            preview()
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
            preview()
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            isShowingMenu = true
            control?.isHighlighted = false
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willEndFor configuration: UIContextMenuConfiguration,
                                    animator: (any UIContextMenuInteractionAnimating)?) {
            if let animator {
                animator.addCompletion { [weak self] in self?.isShowingMenu = false }
            } else {
                isShowingMenu = false
            }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                                    animator: any UIContextMenuInteractionCommitAnimating) {
            animator.preferredCommitStyle = .dismiss
            animator.addCompletion { [weak self] in self?.parent.openDetail() }
        }

        private func preview() -> UITargetedPreview? {
            guard let control, control.window != nil else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: control.bounds, cornerRadius: 20)
            return UITargetedPreview(view: control, parameters: parameters)
        }

        private func menu() -> UIMenu {
            let tint = UIColor(parent.tint)
            return UIMenu(children: [
                UIAction(title: "向前移", image: UIImage(systemName: "arrow.left")?
                    .withTintColor(tint, renderingMode: .alwaysOriginal),
                         attributes: parent.canMoveEarlier ? [] : .disabled) { [weak self] _ in
                    guard let self, self.parent.canMoveEarlier else { return }
                    self.parent.moveEarlier()
                },
                UIAction(title: "向后移", image: UIImage(systemName: "arrow.right")?
                    .withTintColor(tint, renderingMode: .alwaysOriginal),
                         attributes: parent.canMoveLater ? [] : .disabled) { [weak self] _ in
                    guard let self, self.parent.canMoveLater else { return }
                    self.parent.moveLater()
                },
                UIAction(title: "从行情栏移除", image: UIImage(systemName: "minus.circle")?
                    .withTintColor(tint, renderingMode: .alwaysOriginal),
                         attributes: .destructive) { [weak self] _ in self?.parent.remove() },
            ])
        }

        func accessibilityActions() -> [UIAccessibilityCustomAction] {
            var actions: [UIAccessibilityCustomAction] = []
            if parent.canMoveEarlier {
                actions.append(UIAccessibilityCustomAction(name: "向前移") { [weak self] _ in
                    guard let self, self.parent.canMoveEarlier else { return false }
                    self.parent.moveEarlier()
                    return true
                })
            }
            if parent.canMoveLater {
                actions.append(UIAccessibilityCustomAction(name: "向后移") { [weak self] _ in
                    guard let self, self.parent.canMoveLater else { return false }
                    self.parent.moveLater()
                    return true
                })
            }
            actions.append(UIAccessibilityCustomAction(name: "从行情栏移除") { [weak self] _ in
                self?.parent.remove()
                return self != nil
            })
            return actions
        }
    }
}

private final class OverviewQuoteControlView: UIControl {
    private var contentView: (UIView & UIContentView)?
    private var currentCard: OverviewQuoteCard?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.65 : 1 }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        UIBezierPath(roundedRect: bounds, cornerRadius: 20).contains(point)
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    func update(card: OverviewQuoteCard) {
        guard currentCard != card else { return }
        currentCard = card
        let configuration = UIHostingConfiguration {
            card.equatable().dynamicTypeSize(card.typeSize)
        }.margins(.all, 0)
        if let contentView {
            contentView.configuration = configuration
        } else {
            let contentView = configuration.makeContentView()
            contentView.isUserInteractionEnabled = false
            contentView.accessibilityElementsHidden = true
            contentView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
                contentView.topAnchor.constraint(equalTo: topAnchor),
                contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.contentView = contentView
        }
    }
}

private struct OverviewQuoteCard: View, Equatable {
    let instrument: Instrument
    let quote: Quote?
    let colorConvention: PriceColorConvention
    let typeSize: DynamicTypeSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.instrument == rhs.instrument && lhs.quote?.price == rhs.quote?.price
            && lhs.quote?.changePercent == rhs.quote?.changePercent && lhs.colorConvention == rhs.colorConvention
            && lhs.typeSize == rhs.typeSize
    }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(instrument.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let quote {
                Text(QuoteFormatting.price(quote.price, kind: instrument.kind))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(QuoteFormatting.percent(quote.changePercent))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(QuoteColor.color(for: quote.changePercent, convention: colorConvention))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            } else {
                Text("—").font(.subheadline.weight(.semibold))
                Text("等待行情").font(.caption).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 88)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

private struct QuoteRow: View, Equatable {
    let instrument: Instrument
    let quote: Quote?
    let colorConvention: PriceColorConvention
    let isWidget: Bool
    let typeSize: DynamicTypeSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.instrument == rhs.instrument && lhs.quote?.price == rhs.quote?.price
            && lhs.quote?.changePercent == rhs.quote?.changePercent && lhs.colorConvention == rhs.colorConvention
            && lhs.isWidget == rhs.isWidget && lhs.typeSize == rhs.typeSize
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { identity; numbers }
            } else {
                HStack(alignment: .center, spacing: 8) { identity; Spacer(minLength: 4); numbers }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(instrument.name)
                    .font(typeSize.isAccessibilitySize ? .body : .subheadline.weight(.medium))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                if isWidget {
                    Image(systemName: "applewatch")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("表盘关注")
                }
            }
            HStack(spacing: 4) {
                Text("\(instrument.marketLabel) \(instrument.code)")
                    .monospacedDigit()
                if instrument.kind != .stock {
                    Text(instrument.kind.displayName)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .layoutPriority(-1)
    }

    private var numbers: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { quoteNumbers }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) { quoteNumbers }
            }
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private var quoteNumbers: some View {
        if let quote {
            Text(QuoteFormatting.price(quote.price, kind: instrument.kind))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .lineLimit(1)
            Text(QuoteFormatting.percent(quote.changePercent))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(QuoteColor.color(for: quote.changePercent, convention: colorConvention))
                .lineLimit(1)
        } else {
            Text("—").font(.subheadline)
            Text("暂无报价").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private final class OverviewManagementScreenState: ObservableObject {
    @Published var showingSearch = false
}

private struct OverviewManagementView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ui = OverviewManagementScreenState()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.overviewInstruments) { instrument in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(instrument.name).font(.body.weight(.medium))
                                Text("\(instrument.marketLabel) \(instrument.code) · \(instrument.kind.displayName)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Menu {
                                Button("向前移", systemImage: "arrow.up") { store.moveOverview(instrument, by: -1) }
                                    .tint(store.settings.buttonTheme.color)
                                    .disabled(store.overviewInstruments.first?.symbol == instrument.symbol)
                                Button("向后移", systemImage: "arrow.down") { store.moveOverview(instrument, by: 1) }
                                    .tint(store.settings.buttonTheme.color)
                                    .disabled(store.overviewInstruments.last?.symbol == instrument.symbol)
                                Button("移除", systemImage: "minus.circle", role: .destructive) {
                                    store.removeFromOverview(instrument)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .tint(store.settings.buttonTheme.color)
                            .accessibilityLabel("管理\(instrument.name)")
                        }
                    }
                    .onMove { store.moveOverview(from: $0, to: $1) }
                    .onDelete { offsets in
                        let selected = offsets.map { store.overviewInstruments[$0] }
                        selected.forEach { store.removeFromOverview($0) }
                    }
                    Button {
                        ui.showingSearch = true
                    } label: {
                        Label("添加证券", systemImage: "plus")
                            .frame(minHeight: 44)
                    }
                    .tint(store.settings.buttonTheme.color)
                    .disabled(store.overviewInstruments.count >= 50)
                    .deleteDisabled(true)
                    .moveDisabled(true)
                } footer: {
                    Text("已添加 \(store.overviewInstruments.count) / 50 只。左右滑动可删除，使用右侧菜单调整顺序。")
                }
            }
            .navigationTitle("管理行情栏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .tint(store.settings.buttonTheme.color)
                }
            }
            .sheet(isPresented: $ui.showingSearch) { StockSearchView(destination: .overview) }
        }
    }
}
