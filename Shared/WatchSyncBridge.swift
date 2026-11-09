import Foundation
import WatchConnectivity

@MainActor
final class WatchSyncBridge: NSObject, WCSessionDelegate {
    /// Return the state that was successfully saved before sending a receipt.
    var onReceive: ((CacheSnapshot) -> CacheSnapshot?)?
    var onReady: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var onConfirmation: ((SyncConfirmation) -> Void)?
    private var latestSnapshot: CacheSnapshot?
    private var deliveryID: UUID?
    private var deliveryData: Data?
    private var tracker = SyncConfirmationTracker()
    private var receivedDeliveries: [UUID: SyncConfirmation] = [:]
    private var session: WCSession?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    func send(_ snapshot: CacheSnapshot, force: Bool = false) {
        latestSnapshot = snapshot
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(snapshot)
            if force || data != deliveryData || deliveryID == nil {
                let id = UUID()
                deliveryID = id
                deliveryData = data
                tracker.sent(id: id, snapshot: snapshot)
            }
            guard let session, session.activationState == .activated else {
                onStatus?("同步连接准备中")
                return
            }
            #if os(iOS)
            guard session.isPaired, session.isWatchAppInstalled else {
                onStatus?("安装并打开手表 App 后同步")
                return
            }
            #endif
            guard !tracker.isConfirmed, let id = deliveryID else { return }
            let context: [String: Any] = ["snapshot": data, "deliveryID": id.uuidString]
            try session.updateApplicationContext(context)
            if session.isReachable {
                session.sendMessage(context, replyHandler: nil, errorHandler: nil)
            }
            onStatus?(session.isReachable ? "已发送，等待接收确认" : "已排队，等待设备连接")
        } catch {
            onStatus?("同步暂不可用，可点重新同步重试")
        }
    }

    private func receive(_ context: [String: Any]) {
        if let data = context["syncConfirmation"] as? Data,
           let confirmation = try? JSONDecoder().decode(SyncConfirmation.self, from: data),
           tracker.receive(confirmation) {
            onConfirmation?(confirmation)
        }
        guard let data = context["snapshot"] as? Data,
              let snapshot = try? JSONDecoder().decode(CacheSnapshot.self, from: data) else { return }
        let id = (context["deliveryID"] as? String).flatMap(UUID.init(uuidString:))
        if let id, let confirmation = receivedDeliveries[id] {
            sendConfirmation(confirmation)
            return
        }
        guard let saved = onReceive?(snapshot) else {
            onStatus?("收到数据但保存失败，请重新同步")
            return
        }
        guard let id else {
            onStatus?("已接收旧版同步数据；更新两端 App 可启用确认")
            return
        }
        let confirmation = SyncConfirmation(deliveryID: id, persistedAt: .now, snapshot: saved)
        if receivedDeliveries.count >= 32 { receivedDeliveries.removeAll() }
        receivedDeliveries[id] = confirmation
        sendConfirmation(confirmation)
    }

    private func sendConfirmation(_ confirmation: SyncConfirmation) {
        guard let session, session.activationState == .activated,
              let data = try? JSONEncoder().encode(confirmation) else { return }
        let message: [String: Any] = ["syncConfirmation": data]
        session.transferUserInfo(message)
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                self.onStatus?("同步未就绪：\(error.localizedDescription)")
                return
            }
            self.receive(session.receivedApplicationContext)
            self.onReady?()
            if let snapshot = self.latestSnapshot { self.send(snapshot) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor [weak self] in self?.receive(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in self?.receive(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor [weak self] in self?.receive(userInfo) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.onReady?() }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif
}
