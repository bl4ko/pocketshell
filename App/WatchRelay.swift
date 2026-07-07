import Foundation
import Models
import SSHKit
import TmuxKit
import WatchConnectivity

final class WatchRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchRelay()

    private var store: AppStore?

    @MainActor
    func activate(store: AppStore) {
        guard WCSession.isSupported() else { return }
        self.store = store
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func push(_ snapshot: SessionSnapshot) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? WCSession.default.updateApplicationContext(["snapshot": data])
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        switch message["type"] as? String {
        case "status":
            replyStatus(replyHandler)
        case "send":
            guard let host = message["host"] as? String,
                  let tmuxSession = message["session"] as? String,
                  let index = message["window"] as? Int,
                  let text = message["text"] as? String
            else {
                replyHandler(["error": "bad request"])
                return
            }
            let pressEnter = message["enter"] as? Bool ?? true
            sendKeys(
                hostName: host,
                session: tmuxSession,
                windowIndex: index,
                text: text,
                pressEnter: pressEnter,
                replyHandler: replyHandler
            )
        default:
            replyHandler(["error": "unknown type"])
        }
    }

    private func replyStatus(_ replyHandler: @escaping ([String: Any]) -> Void) {
        if let snapshot = SnapshotStore.shared.load(),
           let data = try? JSONEncoder().encode(snapshot) {
            replyHandler(["snapshot": data])
        } else {
            replyHandler(["error": "no data"])
        }
    }

    private struct SendableReply: @unchecked Sendable {
        let handler: ([String: Any]) -> Void

        func callAsFunction(_ reply: [String: Any]) {
            handler(reply)
        }
    }

    private func sendKeys(
        hostName: String,
        session: String,
        windowIndex: Int,
        text: String,
        pressEnter: Bool,
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let replyHandler = SendableReply(handler: replyHandler)
        Task { @MainActor in
            guard let store = self.store,
                  let host = store.hosts.first(where: { $0.name == hostName }),
                  let key = try? store.key(for: host)
            else {
                replyHandler(["error": "unknown host"])
                return
            }
            let connection = SSHConnection(host: host, key: key, knownHosts: store.knownHosts)
            do {
                try await connection.connect()
                _ = try await connection.exec(Tmux.sendKeysCommand(
                    session: session,
                    windowIndex: windowIndex,
                    text: text,
                    pressEnter: pressEnter
                ))
                await connection.disconnect()
                replyHandler(["ok": true])
            } catch {
                await connection.disconnect()
                replyHandler(["error": "\(error)"])
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
