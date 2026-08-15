import Foundation
import Models
import MonitorKit
import SSHKit
import TmuxKit
import UserNotifications

@MainActor
final class ApprovalService {
    static let shared = ApprovalService()
    static let category = "agent.needsInput"

    weak var store: AppStore?

    static func registerCategory() {
        let approve = UNNotificationAction(
            identifier: AgentApproval.Choice.approve.rawValue,
            title: "Approve",
            options: []
        )
        let deny = UNNotificationAction(
            identifier: AgentApproval.Choice.deny.rawValue,
            title: "Deny",
            options: [.destructive]
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: category,
                actions: [approve, deny],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    func respond(to target: SessionTarget, choice: AgentApproval.Choice) async {
        guard let store, let host = store.hosts.first(where: { $0.id == target.hostID }),
            let paneTarget = paneTarget(for: target)
        else {
            report("Host is gone", body: "PocketShell could not find that session.")
            return
        }
        guard let key = try? store.key(for: host) else {
            report("Locked", body: "Open PocketShell to unlock the key for \(host.name).")
            return
        }
        let connection = SSHConnection(
            host: host,
            key: key,
            knownHosts: store.knownHosts,
            hops: store.hops(for: host)
        )
        do {
            try await connection.connect()
            defer { Task { await connection.disconnect() } }
            let capture = try await connection.exec(Tmux.capturePaneSnapshotCommand(target: paneTarget))
            let screen = Tmux.parsePaneSnapshot(capture)?.text ?? capture
            guard let keys = AgentApproval.keys(for: choice, screen: screen) else {
                report("Nothing sent", body: "The agent is no longer waiting for that answer.")
                return
            }
            _ = try await connection.exec(
                Tmux.sendKeysCommand(target: paneTarget, text: keys.text, pressEnter: keys.pressEnter))
            report(choice == .approve ? "Approved" : "Denied", body: "\(host.name) · \(paneTarget)")
        } catch {
            report("Failed", body: "\(host.name): \(error.localizedDescription)")
        }
    }

    private func paneTarget(for target: SessionTarget) -> String? {
        if target.backend == "herdr" {
            return target.paneID
        }
        guard let session = target.session, let index = target.windowIndex else { return nil }
        return "\(session):\(index)"
    }

    private func report(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "approval-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
