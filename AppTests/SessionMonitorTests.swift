import Combine
import Foundation
import Models
import Testing

@testable import pocketshell

final class FakeConnection: MonitorConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [String] = []
    private var _disconnects = 0
    private let handler: @Sendable (String) throws -> String

    init(handler: @escaping @Sendable (String) throws -> String) {
        self.handler = handler
    }

    var commands: [String] { lock.withLock { _commands } }
    var disconnects: Int { lock.withLock { _disconnects } }
    var isConnected: Bool { true }

    func exec(_ command: String) async throws -> String {
        lock.withLock { _commands.append(command) }
        return try handler(command)
    }

    func disconnect() async {
        lock.withLock { _disconnects += 1 }
    }
}

struct ExecFailure: Error {}

actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var _capture = "$ idle"
    private var _failWindows = false
    private var _failCaptures = false
    private var _herdr: String?
    private var _failSnapshot = false

    var capture: String {
        get { lock.withLock { _capture } }
        set { lock.withLock { _capture = newValue } }
    }
    var failWindows: Bool {
        get { lock.withLock { _failWindows } }
        set { lock.withLock { _failWindows = newValue } }
    }
    var failCaptures: Bool {
        get { lock.withLock { _failCaptures } }
        set { lock.withLock { _failCaptures = newValue } }
    }
    var herdr: String? {
        get { lock.withLock { _herdr } }
        set { lock.withLock { _herdr = newValue } }
    }

    var failSnapshot: Bool {
        get { lock.withLock { _failSnapshot } }
        set { lock.withLock { _failSnapshot = newValue } }
    }

    func reply(_ command: String) throws -> String {
        if command.contains("capture-pane") {
            if failCaptures { throw ExecFailure() }
            return "@@pane:0@@\n\(capture)\n"
        }
        if command.contains("list-windows") {
            if failWindows { throw ExecFailure() }
            return "0|@1|1|work\n"
        }
        if command.contains("list-sessions") { return "main|1|0|\n" }
        if command.contains("session list --json") {
            return herdr == nil ? "" : #"{"sessions":[{"default":false,"name":"work","running":true}]}"#
        }
        if command.contains("api snapshot") {
            guard let status = herdr, !failSnapshot else { throw ExecFailure() }
            return
                #"{"result":{"snapshot":{"version":"1","protocol":1,"workspaces":[{"workspace_id":"w1","number":1,"label":"L","agent_status":"\#(status)","focused":true}],"agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"t","agent":"codex","agent_status":"\#(status)","focused":true}]}}}"#
        }
        return ""
    }
}

let busyCapture = "doing work\nesc to interrupt"

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
struct SessionMonitorTests {
    func makeHost(_ name: String = "h", tmux: String? = "main") -> HostConfig {
        HostConfig(name: name, hostname: name, username: "u", keyTag: "k", tmuxSession: tmux)
    }

    func makeMonitor(
        hosts: [HostConfig],
        connector: @escaping SessionMonitor.Connector
    ) -> SessionMonitor {
        let store = AppStore()
        store.savedTabs = [:]
        store.hosts = hosts
        return SessionMonitor(store: store, connector: connector)
    }

    func makeMonitor(host: HostConfig, script: Script) -> (SessionMonitor, FakeConnection) {
        let connection = FakeConnection { try script.reply($0) }
        return (makeMonitor(hosts: [host]) { _ in connection }, connection)
    }

    func key(_ host: HostConfig) -> String {
        SessionMonitor.windowKey(hostID: host.id, session: "main", windowIndex: 0)
    }

    @Test func unseenFinishedNotifiesOnlyOnRealChange() async {
        let (monitor, _) = makeMonitor(host: makeHost(), script: Script())
        var fired = 0
        let cancellable = monitor.objectWillChange.sink { fired += 1 }
        let id = UUID()

        monitor.markSeen(hostID: id, session: "s", windowIndex: 1)
        #expect(fired == 0)
        monitor.markFinished(hostID: id, session: "s", windowIndex: 1)
        #expect(fired == 1)
        monitor.markFinished(hostID: id, session: "s", windowIndex: 1)
        #expect(fired == 1)
        monitor.markSeen(hostID: id, session: "s", windowIndex: 1)
        #expect(fired == 2)
        cancellable.cancel()
    }

    @Test func busyThenIdleMarksFinished() async {
        let host = makeHost()
        let script = Script()
        let (monitor, _) = makeMonitor(host: host, script: script)
        script.capture = busyCapture
        await monitor.pollOnce()
        await monitor.pollOnce()
        script.capture = "$ idle"
        await monitor.pollOnce()
        await monitor.pollOnce()
        #expect(monitor.unseenFinished.contains(key(host)))
    }

    @Test(arguments: [true, false])
    func failedExecRoundKeepsTrackerStateAcrossTheGap(failWindows: Bool) async {
        let host = makeHost()
        let script = Script()
        let (monitor, _) = makeMonitor(host: host, script: script)
        script.capture = busyCapture
        await monitor.pollOnce()
        await monitor.pollOnce()

        script.failWindows = failWindows
        script.failCaptures = !failWindows
        script.capture = ""
        await monitor.pollOnce()
        await monitor.pollOnce()
        #expect(monitor.unseenFinished.isEmpty)

        script.failWindows = false
        script.failCaptures = false
        script.capture = "$ idle"
        await monitor.pollOnce()
        await monitor.pollOnce()
        #expect(monitor.unseenFinished.contains(key(host)))
    }

    @Test func unreachableHostIsBackedOffAndDoesNotBlockOthers() async {
        let bad = makeHost("bad")
        let good = makeHost("good")
        let script = Script()
        let goodConnection = FakeConnection { try script.reply($0) }
        let calls = CallCounter()
        let monitor = makeMonitor(hosts: [bad, good]) { host in
            calls.record(host.id)
            return host.id == good.id ? goodConnection : nil
        }

        await monitor.pollOnce()
        #expect(calls.count(bad.id) == 1)
        #expect(monitor.snapshot?.windows.contains { $0.host == "good" } == true)

        await monitor.pollOnce()
        #expect(calls.count(bad.id) == 1)
        await monitor.pollOnce()
        #expect(calls.count(bad.id) == 2)
    }

    @Test func hostsArePolledConcurrently() async {
        let slow = makeHost("slow")
        let fast = makeHost("fast")
        let gate = Gate()
        let script = Script()
        let fastConnection = FakeConnection { try script.reply($0) }
        let slowConnection = FakeConnection { try script.reply($0) }
        let monitor = makeMonitor(hosts: [slow, fast]) { host in
            if host.id == slow.id {
                await gate.wait()
                return slowConnection
            }
            return fastConnection
        }

        let poll = Task { await monitor.pollOnce() }
        let reachedFast = await waitUntil { !fastConnection.commands.isEmpty }
        await gate.open()
        await poll.value
        #expect(reachedFast)
        #expect(!slowConnection.commands.isEmpty)
    }

    @Test func cancelledRoundPublishesNothing() async {
        let host = makeHost()
        let script = Script()
        let (monitor, _) = makeMonitor(host: host, script: script)
        await monitor.pollOnce()
        let published = monitor.snapshot
        #expect(published?.windows.isEmpty == false)

        script.capture = busyCapture
        let poll = Task { await monitor.pollOnce() }
        poll.cancel()
        await poll.value
        #expect(monitor.snapshot == published)
    }

    @Test func connectionFinishingAfterCancellationIsDisconnectedNotStored() async {
        let host = makeHost()
        let gate = Gate()
        let connection = FakeConnection { _ in "" }
        let calls = CallCounter()
        let monitor = makeMonitor(hosts: [host]) { host in
            calls.record(host.id)
            if calls.count(host.id) == 1 { await gate.wait() }
            return connection
        }

        let attempt = Task { await monitor.connection(for: host) }
        let entered = await waitUntil { calls.count(host.id) == 1 }
        attempt.cancel()
        await gate.open()
        let result = await attempt.value

        #expect(entered)
        #expect(result == nil)
        #expect(connection.disconnects == 1)
        _ = await monitor.connection(for: host)
        #expect(calls.count(host.id) == 2)
    }

    @Test func stopPollingMidRoundPublishesNothing() async {
        let host = makeHost()
        let gate = Gate()
        let script = Script()
        let connection = FakeConnection { try script.reply($0) }
        let calls = CallCounter()
        let monitor = makeMonitor(hosts: [host]) { host in
            calls.record(host.id)
            if calls.count(host.id) == 2 { await gate.wait() }
            return connection
        }
        await monitor.pollOnce()
        let published = monitor.snapshot
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppSettings.agentNotifyKey)
        defaults.set(true, forKey: AppSettings.agentNotifyKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppSettings.agentNotifyKey)
            } else {
                defaults.removeObject(forKey: AppSettings.agentNotifyKey)
            }
        }
        monitor.stopPolling()
        script.capture = busyCapture

        monitor.startPolling()
        let entered = await waitUntil { calls.count(host.id) == 2 }
        monitor.stopPolling()
        await gate.open()
        _ = await waitUntil { connection.disconnects >= 2 }

        #expect(entered)
        #expect(monitor.snapshot == published)
    }

    @Test func failedHerdrSnapshotKeepsStatusSoNextDoneStillMarksFinished() async {
        let host = makeHost(tmux: nil)
        let script = Script()
        let (monitor, _) = makeMonitor(host: host, script: script)
        let agentKey = SessionMonitor.herdrAgentKey(hostID: host.id, session: "work", paneID: "w1:p1")

        script.herdr = "working"
        await monitor.pollOnce()
        script.failSnapshot = true
        await monitor.pollOnce()
        script.failSnapshot = false
        script.herdr = "done"
        await monitor.pollOnce()

        #expect(monitor.unseenFinished.contains(agentKey))
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UUID: Int] = [:]

    func record(_ id: UUID) { lock.withLock { counts[id, default: 0] += 1 } }
    func count(_ id: UUID) -> Int { lock.withLock { counts[id] ?? 0 } }
}
