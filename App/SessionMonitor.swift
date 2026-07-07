import BackgroundTasks
import Foundation
import KeyKit
import Models
import MonitorKit
import SSHKit
import TmuxKit
import UserNotifications

@MainActor
final class SessionMonitor: ObservableObject {
    static let refreshTaskID = "com.bl4ko.pocketshell.refresh"

    private let store: AppStore
    private var tracker = AgentActivityTracker()
    private var pollTask: Task<Void, Never>?
    private var connections: [UUID: SSHConnection] = [:]

    init(store: AppStore) {
        self.store = store
    }

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.agentNotifyKey)
    }

    func startPolling() {
        guard enabled, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        for connection in connections.values {
            Task { await connection.disconnect() }
        }
        connections = [:]
    }

    func pollOnce() async {
        var samples: [AgentActivityTracker.Sample] = []
        var snapshots: [SessionSnapshot.Window] = []
        for host in store.hosts {
            guard let session = host.tmuxSession else { continue }
            guard let connection = await connection(for: host) else { continue }
            let windowsOutput = (try? await connection.exec(Tmux.listWindowsCommand(session: session))) ?? ""
            let capturesOutput = (try? await connection.exec(Tmux.capturePanesCommand(session: session, lines: 8))) ?? ""
            let captures = Tmux.parsePaneCaptures(capturesOutput)
            for window in Tmux.parseWindows(windowsOutput) {
                let text = captures[window.index] ?? ""
                let status = AgentStatus.classify(text)
                samples.append(.init(
                    key: "\(host.id):\(window.index)",
                    title: "\(host.name) \(session):\(window.index) \(window.name)",
                    status: status
                ))
                snapshots.append(.init(
                    host: host.name,
                    name: "\(window.index): \(window.name)",
                    status: status.label,
                    lastLine: text.split(separator: "\n").last.map(String.init) ?? ""
                ))
            }
        }
        let transitions = tracker.update(samples)
        SnapshotStore.save(SessionSnapshot(windows: snapshots, updatedAt: Date()))
        for transition in transitions {
            notify(transition)
        }
    }

    private func connection(for host: HostConfig) async -> SSHConnection? {
        if let existing = connections[host.id], await existing.isConnected {
            return existing
        }
        guard let key = try? store.key(for: host) else { return nil }
        let connection = SSHConnection(host: host, key: key, knownHosts: store.knownHosts)
        do {
            try await connection.connect()
        } catch {
            return nil
        }
        connections[host.id] = connection
        return connection
    }

    private func notify(_ transition: AgentActivityTracker.Transition) {
        let content = UNMutableNotificationContent()
        content.title = transition.status == .waiting ? "Agent needs input" : "Agent finished"
        content.body = transition.title
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "agent-\(transition.key)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        Self.scheduleBackgroundRefresh()
        let work = Task { [weak self] in
            await self?.pollOnce()
            self?.stopPolling()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}

extension AgentStatus {
    var label: String {
        switch self {
        case .busy: "busy"
        case .waiting: "needs input"
        case .idle: "idle"
        }
    }
}
