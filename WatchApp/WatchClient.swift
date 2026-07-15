import Foundation
import Models
import WatchConnectivity

@MainActor
final class WatchClient: NSObject, ObservableObject {
    @Published var snapshot: SessionSnapshot?
    @Published var statusMessage: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refresh() {
        guard WCSession.default.activationState == .activated else { return }
        statusMessage = "refreshing…"
        WCSession.default.sendMessage(["type": "status"]) { [weak self] reply in
            Task { @MainActor in
                self?.handleReply(reply)
            }
        } errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    func send(window: SessionSnapshot.Window, text: String, pressEnter: Bool) {
        statusMessage = "sending…"
        let message: [String: Any] = [
            "type": "send",
            "host": window.host,
            "session": window.session,
            "window": window.index,
            "text": text,
            "enter": pressEnter,
        ]
        WCSession.default.sendMessage(message) { [weak self] reply in
            Task { @MainActor in
                self?.statusMessage = reply["ok"] != nil ? "sent" : (reply["error"] as? String ?? "failed")
                self?.refresh()
            }
        } errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    private func handleReply(_ reply: [String: Any]) {
        if let data = reply["snapshot"] as? Data,
            let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        {
            snapshot = decoded
            statusMessage = nil
        } else {
            statusMessage = reply["error"] as? String ?? "no data"
        }
    }
}

extension WatchClient: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let data = context["snapshot"] as? Data
        Task { @MainActor in
            guard let data,
                let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
            else { return }
            self.snapshot = decoded
        }
    }
}
