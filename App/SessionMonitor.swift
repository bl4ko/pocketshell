import BackgroundTasks
import Foundation
import HerdrKit
import KeyKit
import Models
import MonitorKit
import SSHKit
import TmuxKit
import UserNotifications
import WidgetKit

struct SessionTarget: Equatable, Decodable {
    var hostID: UUID
    var session: String?
    var windowIndex: Int?
    var backend: String?
    var workspaceID: String?
    var paneID: String?
}

@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()
    @Published var pending: SessionTarget?
}

final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ForegroundNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let idString = info["hostID"] as? String, let hostID = UUID(uuidString: idString) {
            let target = SessionTarget(
                hostID: hostID,
                session: info["session"] as? String,
                windowIndex: info["windowIndex"] as? Int,
                backend: info["backend"] as? String,
                workspaceID: info["workspaceID"] as? String,
                paneID: info["paneID"] as? String
            )
            if let choice = AgentApproval.Choice(rawValue: response.actionIdentifier) {
                Task { @MainActor in
                    await ApprovalService.shared.respond(to: target, choice: choice)
                }
            } else {
                Task { @MainActor in
                    NotificationRouter.shared.pending = target
                }
            }
        }
        completionHandler()
    }
}

protocol MonitorConnection: Sendable {
    var isConnected: Bool { get async }
    func exec(_ command: String) async throws -> String
    func disconnect() async
}

extension SSHConnection: MonitorConnection {}

@MainActor
final class SessionMonitor: ObservableObject {
    typealias Connector = @MainActor (HostConfig) async -> (any MonitorConnection)?

    static let refreshTaskID = "com.bl4ko.pocketshell.refresh"

    @Published private(set) var snapshot: SessionSnapshot?
    private(set) var unseenFinished: Set<String> = [] {
        willSet { if newValue != unseenFinished { objectWillChange.send() } }
    }
    var visibleWindowKey: String?

    private let store: AppStore
    private var tracker = AgentActivityTracker()
    private var pollTask: Task<Void, Never>?
    private var connections: [UUID: any MonitorConnection] = [:]
    private let connector: Connector
    private var notifiedAt: [String: Date] = [:]
    private var backoff = HostBackoff<UUID>()
    private var lastHerdrStatus: [String: HerdrAgentStatus] = [:]
    private var backgroundRefreshTask: BGAppRefreshTask?
    private var backgroundRefreshWork: Task<Void, Never>?

    init(store: AppStore, connector: Connector? = nil) {
        self.store = store
        self.connector =
            connector ?? { [store] host in
                guard let key = try? store.key(for: host) else { return nil }
                let connection = SSHConnection(
                    host: host, key: key, knownHosts: store.knownHosts, hops: store.hops(for: host))
                do {
                    try await connection.connect()
                } catch {
                    return nil
                }
                return connection
            }
        snapshot = SnapshotStore.shared.load()
    }

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.agentNotifyKey)
    }

    static func windowKey(hostID: UUID, session: String, windowIndex: Int) -> String {
        "\(hostID):\(session):\(windowIndex)"
    }

    static func herdrAgentKey(hostID: UUID, session: String, paneID: String) -> String {
        "\(hostID):herdr:\(session):\(paneID)"
    }

    static func herdrWorkspaceKey(hostID: UUID, session: String, workspaceID: String) -> String {
        "\(hostID):herdr:\(session):\(workspaceID)"
    }

    func markFinished(hostID: UUID, session: String, windowIndex: Int) {
        unseenFinished.insert(Self.windowKey(hostID: hostID, session: session, windowIndex: windowIndex))
    }

    func markSeen(hostID: UUID, session: String, windowIndex: Int) {
        unseenFinished.remove(Self.windowKey(hostID: hostID, session: session, windowIndex: windowIndex))
    }

    func markHerdrSeen(hostID: UUID, session: String, paneIDs: [String]) {
        for paneID in paneIDs {
            unseenFinished.remove(Self.herdrAgentKey(hostID: hostID, session: session, paneID: paneID))
        }
    }

    func shouldNotify(key: String) -> Bool {
        let now = Date()
        if let last = notifiedAt[key], now.timeIntervalSince(last) < 60 { return false }
        notifiedAt[key] = now
        return true
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
        let hosts = store.hosts
        let tasks = hosts.map { host in Task { await self.pollHost(host) } }
        let results = await withTaskCancellationHandler {
            var polls: [HostPoll?] = []
            for task in tasks { polls.append(await task.value) }
            return polls
        } onCancel: {
            for task in tasks { task.cancel() }
        }
        guard !Task.isCancelled else { return }
        var samples: [AgentActivityTracker.Sample] = []
        var snapshots: [SessionSnapshot.Window] = []
        var targets: [String: WindowTarget] = [:]
        var herdrKeys: Set<String> = []
        var unobservedPrefixes: [String] = []
        var complete = true
        for poll in results.compactMap({ $0 }) {
            samples += poll.samples
            snapshots += poll.snapshots
            targets.merge(poll.targets) { $1 }
            herdrKeys.formUnion(poll.herdrKeys)
            unobservedPrefixes += poll.unobservedPrefixes
            complete = complete && poll.complete
        }
        lastHerdrStatus = StatusCarryOver.pruned(
            lastHerdrStatus, observed: herdrKeys, unobservedPrefixes: unobservedPrefixes)
        // An empty capture classifies as idle, so a failed exec would fake busy -> idle.
        let transitions = complete ? tracker.update(samples) : []
        for transition in transitions where transition.status == .idle {
            unseenFinished.insert(transition.key)
        }
        let snapshot = SessionSnapshot(windows: snapshots, updatedAt: Date())
        self.snapshot = snapshot
        SnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: "pocketshell-sessions")
        WatchRelay.shared.push(snapshot)
        for transition in transitions {
            notify(transition, userInfo: targets[transition.key]?.userInfo)
        }
    }

    private struct WindowTarget: Sendable {
        let hostID: String
        let session: String
        let windowIndex: Int

        var userInfo: [String: Any] { ["hostID": hostID, "session": session, "windowIndex": windowIndex] }
    }

    private struct HostPoll: Sendable {
        var samples: [AgentActivityTracker.Sample] = []
        var snapshots: [SessionSnapshot.Window] = []
        var targets: [String: WindowTarget] = [:]
        var herdrKeys: Set<String> = []
        var unobservedPrefixes: [String]
        var complete = true
    }

    private func pollHost(_ host: HostConfig) async -> HostPoll? {
        let herdrPrefix = "\(host.id):herdr:"
        var result = HostPoll(unobservedPrefixes: [herdrPrefix])
        let requestedSessions = store.tmuxSessions(for: host)
        guard backoff.shouldAttempt(host.id) else { return result }
        let connected = await connection(for: host)
        if Task.isCancelled { return nil }
        guard let connection = connected else {
            backoff.recordFailure(host.id)
            return result
        }
        backoff.recordSuccess(host.id)
        result.unobservedPrefixes = []
        if !requestedSessions.isEmpty {
            let sessionsOutput = (try? await connection.exec(Tmux.listSessionsCommand())) ?? ""
            canonicalizeSavedTabs(
                for: host,
                using: Tmux.canonicalSessionMap(sessionsOutput, requested: requestedSessions)
            )
            let sessions = Tmux.canonicalSessionNames(sessionsOutput, requested: requestedSessions)
            let records = store.savedTabs[host.id.uuidString] ?? []
            for session in sessions {
                if Task.isCancelled { return nil }
                guard let windowsOutput = try? await connection.exec(Tmux.listWindowsCommand(session: session)),
                    let capturesOutput = try? await connection.exec(Tmux.capturePanesCommand(session: session))
                else {
                    result.complete = false
                    continue
                }
                let captures = Tmux.parsePaneCaptures(capturesOutput)
                for window in Tmux.parseWindows(windowsOutput) {
                    let text = captures[window.index] ?? ""
                    let status = AgentStatus.classify(text)
                    let key = "\(host.id):\(session):\(window.index)"
                    let displayName = Tmux.windowDisplayName(window: window, session: session, records: records)
                    if status == .busy { unseenFinished.remove(key) }
                    result.targets[key] = WindowTarget(
                        hostID: host.id.uuidString, session: session, windowIndex: window.index)
                    result.samples.append(
                        .init(
                            key: key,
                            title: "\(host.name) \(session):\(window.index) \(displayName)",
                            status: status
                        ))
                    result.snapshots.append(
                        .init(
                            host: host.name,
                            session: session,
                            index: window.index,
                            name: "\(window.index): \(displayName)",
                            status: status.label,
                            lastLine: Tmux.previewLines(text, count: 12)
                        ))
                }
            }
        }
        let herdrOutput = try? await connection.exec(Herdr.listSessionsCommand())
        if Task.isCancelled { return nil }
        let herdrSessions = herdrOutput.map { Herdr.parseSessions($0).filter(\.running) } ?? []
        if herdrOutput == nil { result.unobservedPrefixes = [herdrPrefix] }
        if !requestedSessions.isEmpty || !herdrSessions.isEmpty {
            await syncWorkspace(for: host, using: connection)
        }
        for session in herdrSessions {
            guard let output = try? await connection.exec(Herdr.snapshotCommand(session: session.name)),
                let snapshot = Herdr.parseSnapshot(output)
            else {
                result.unobservedPrefixes.append("\(herdrPrefix)\(session.name):")
                continue
            }
            if Task.isCancelled { return nil }
            let workspaces = Dictionary(uniqueKeysWithValues: snapshot.workspaces.map { ($0.id, $0) })
            for agent in snapshot.agents {
                let key = Self.herdrAgentKey(hostID: host.id, session: session.name, paneID: agent.paneID)
                result.herdrKeys.insert(key)
                let workspace = workspaces[agent.workspaceID]
                let title = agent.displayAgent ?? agent.agent ?? "agent"
                let workspaceLabel = workspace?.label ?? agent.workspaceID
                let previous = lastHerdrStatus[key]
                if agent.status == .working || agent.status == .idle { unseenFinished.remove(key) }
                if previous != nil, previous != .done, agent.status == .done { unseenFinished.insert(key) }
                if let previous, previous != agent.status, agent.status == .blocked || agent.status == .done {
                    notifyHerdr(
                        host: host,
                        session: session.name,
                        workspaceID: agent.workspaceID,
                        paneID: agent.paneID,
                        title: "\(host.name) · \(workspaceLabel) · \(title)",
                        status: agent.status
                    )
                }
                lastHerdrStatus[key] = agent.status
                result.snapshots.append(
                    .init(
                        host: host.name,
                        session: session.name,
                        index: workspace?.number ?? 0,
                        name: "\(workspaceLabel) · \(title)",
                        status: agent.status.pocketShellLabel,
                        lastLine: agent.title ?? agent.status.pocketShellLabel,
                        backend: "herdr",
                        workspaceID: agent.workspaceID,
                        paneID: agent.paneID
                    ))
            }
        }
        return result
    }

    func syncWorkspaceNow(for host: HostConfig) async {
        guard let connection = await connection(for: host) else { return }
        await syncWorkspace(for: host, using: connection)
    }

    func herdrSessions(for host: HostConfig) async -> [HerdrSession] {
        if let fixture = ProcessInfo.processInfo.environment["PS_UI_TEST_HERDR_SESSIONS"] {
            return Herdr.parseSessions(fixture)
        }
        guard let connection = await connection(for: host),
            let output = try? await connection.exec(Herdr.listSessionsCommand())
        else { return [] }
        return Herdr.parseSessions(output)
    }

    private func syncWorkspace(for host: HostConfig, using connection: any MonitorConnection) async {
        // The e2e sshd points at a real user home: a test app syncing its
        // throwaway tabs into ~/.config/pocketshell/workspace.json pollutes
        // every device attached to that host.
        guard ProcessInfo.processInfo.environment["PS_UI_TEST"] != "1" else { return }
        let hostID = host.id.uuidString
        let output = (try? await connection.exec(WorkspaceSync.readCommand)) ?? ""
        let remote = WorkspaceSync.decode(output)
        switch WorkspaceSync.action(
            localUpdatedAt: store.workspaceUpdatedAt(hostID: hostID),
            remote: remote
        ) {
        case .push:
            if let command = WorkspaceSync.writeCommand(store.localWorkspace(hostID: hostID), replacing: remote) {
                _ = try? await connection.exec(command)
            }
        case .apply(let remote):
            store.applyRemoteWorkspace(hostID: hostID, remote)
        case .none:
            break
        }
    }

    private func canonicalizeSavedTabs(for host: HostConfig, using sessions: [String: String]) {
        let key = host.id.uuidString
        guard var tabs = store.savedTabs[key] else { return }
        for index in tabs.indices {
            if let session = tabs[index].tmuxSession, let canonical = sessions[session] {
                tabs[index].tmuxSession = canonical
                if tabs[index].tabGroup.map(Tmux.baseSessionName) == canonical {
                    tabs[index].tabGroup = canonical
                }
            }
        }
        if tabs != store.savedTabs[key] {
            store.savedTabs[key] = tabs
        }
        if let session = host.tmuxSession, let canonical = sessions[session], canonical != session,
            let index = store.hosts.firstIndex(where: { $0.id == host.id })
        {
            store.hosts[index].tmuxSession = canonical
        }
    }

    func connection(for host: HostConfig) async -> (any MonitorConnection)? {
        if let existing = connections[host.id], await existing.isConnected {
            return existing
        }
        guard let connection = await connector(host) else { return nil }
        if Task.isCancelled {
            await connection.disconnect()
            return nil
        }
        connections[host.id] = connection
        return connection
    }

    private func notify(_ transition: AgentActivityTracker.Transition, userInfo: [String: Any]?) {
        if transition.key == visibleWindowKey { return }
        if transition.status == .waiting, !shouldNotify(key: transition.key) { return }
        let content = UNMutableNotificationContent()
        content.title = transition.status == .waiting ? "Agent needs input" : "Agent finished"
        content.body = transition.title
        content.sound = .default
        if transition.status == .waiting {
            content.categoryIdentifier = ApprovalService.category
        }
        if let userInfo {
            content.userInfo = userInfo
        }
        let request = UNNotificationRequest(
            identifier: "agent-\(transition.key)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyHerdr(
        host: HostConfig,
        session: String,
        workspaceID: String,
        paneID: String,
        title: String,
        status: HerdrAgentStatus
    ) {
        guard !PushRelayClient.shared.hasInstalledPlugin(hostID: host.id) else { return }
        let workspaceKey = Self.herdrWorkspaceKey(hostID: host.id, session: session, workspaceID: workspaceID)
        let agentKey = Self.herdrAgentKey(hostID: host.id, session: session, paneID: paneID)
        guard visibleWindowKey != workspaceKey, shouldNotify(key: agentKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = status == .blocked ? "Agent needs input" : "Agent finished"
        content.body = title
        content.sound = .default
        if status == .blocked {
            content.categoryIdentifier = ApprovalService.category
        }
        content.userInfo = [
            "hostID": host.id.uuidString,
            "backend": "herdr",
            "session": session,
            "workspaceID": workspaceID,
            "paneID": paneID,
        ]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "herdr-\(agentKey)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            ))
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
        finishBackgroundRefresh(backgroundRefreshTask, success: false)
        backgroundRefreshTask = task
        let work = Task { [weak self, weak task] in
            guard let self, let task else { return }
            await self.pollOnce()
            self.stopPolling()
            self.finishBackgroundRefresh(task, success: !Task.isCancelled)
        }
        backgroundRefreshWork = work
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor [weak self, weak task] in
                guard let self, let task else { return }
                self.backgroundRefreshWork?.cancel()
                self.finishBackgroundRefresh(task, success: false)
            }
        }
    }

    private func finishBackgroundRefresh(_ task: BGAppRefreshTask?, success: Bool) {
        guard let task, backgroundRefreshTask === task else { return }
        backgroundRefreshTask = nil
        backgroundRefreshWork = nil
        task.setTaskCompleted(success: success)
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

extension HerdrAgentStatus {
    var pocketShellLabel: String {
        switch self {
        case .working: "busy"
        case .blocked: "needs input"
        case .done: "done"
        case .idle: "idle"
        case .unknown: "unknown"
        }
    }

    var tabStatus: AgentStatus? {
        switch self {
        case .working: .busy
        case .blocked: .waiting
        case .done, .idle: .idle
        case .unknown: nil
        }
    }
}
