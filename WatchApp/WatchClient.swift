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
        requestSnapshot()
    }

    nonisolated private func requestSnapshot() {
        WCSession.default.sendMessage(["type": "status"]) { [weak self] reply in
            let data = reply["snapshot"] as? Data
            let message = reply["error"] as? String
            Task { @MainActor in
                self?.handleReply(data: data, error: message)
            }
        } errorHandler: { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                self?.statusMessage = message
            }
        }
    }

    func send(window: SessionSnapshot.Window, text: String, pressEnter: Bool) {
        statusMessage = "sending…"
        sendMessage(window: window, text: text, pressEnter: pressEnter)
    }

    nonisolated private func sendMessage(window: SessionSnapshot.Window, text: String, pressEnter: Bool) {
        let message: [String: Any] = [
            "type": "send",
            "host": window.host,
            "session": window.session,
            "window": window.index,
            "text": text,
            "enter": pressEnter,
        ]
        WCSession.default.sendMessage(message) { [weak self] reply in
            let message = reply["ok"] != nil ? "sent" : (reply["error"] as? String ?? "failed")
            Task { @MainActor in
                self?.statusMessage = message
                self?.refresh()
            }
        } errorHandler: { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                self?.statusMessage = message
            }
        }
    }

    private func handleReply(data: Data?, error: String?) {
        if let data,
            let decoded = try? JSONDecoder().decode(SessionSnapshot.self, from: data)
        {
            snapshot = decoded
            statusMessage = nil
        } else {
            statusMessage = error ?? "no data"
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
