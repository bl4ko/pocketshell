import Foundation
import HerdrKit
import KeyKit
import Models
import Network
import ReconnectKit
import SSHKit
import TerminalUI
import TmuxKit

@MainActor
final class ConnectionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case pickingSession(tmuxWindows: [TmuxWindow], herdrSessions: [HerdrSession])
        case attached
        case reconnecting(String)
        case failed(String)
        case exited
    }

    @Published var phase: Phase = .idle
    @Published var findVisible = false
    let bridge = TerminalBridge()
    var onExit: (() -> Void)?

    private let host: HostConfig
    private let key: DeviceKeyMaterial
    private let knownHosts: KnownHostsStore
    private let hops: [SSHHop]
    private var connection: SSHConnection?
    private var shell: ShellStream?
    private var machine = ReconnectMachine(baseDelay: .seconds(3))
    private var lastErrorMessage: String?
    private var monitor: NWPathMonitor?
    private enum PendingShell {
        case tmux(session: String, windowIndex: Int?, windowID: String?)
        case herdr(session: String, workspaceID: String?)
        case plain(String?)
    }

    private var retryTask: Task<Void, Never>?
    private var pendingShell: PendingShell?
    private var cloneTag: String?
    private var shellGeneration = 0
    private var stopped = false
    private var writeAttempts = 0
    private var writeSuccesses = 0
    private var writeFailures = 0
    private var lastWriteAt: Date?

    init(host: HostConfig, key: DeviceKeyMaterial, knownHosts: KnownHostsStore, hops: [SSHHop] = []) {
        self.host = host
        self.key = key
        self.knownHosts = knownHosts
        self.hops = hops
    }

    func start() async {
        stopped = false
        _ = machine.handle(.userConnect)
        startPathMonitor()
        await establish(initial: true)
    }

    func stop() async {
        stopped = true
        retryTask?.cancel()
        monitor?.cancel()
        monitor = nil
        _ = machine.handle(.userDisconnect)
        await shell?.close()
        await connection?.disconnect()
        connection = nil
        shell = nil
        phase = .idle
    }

    func selectWindow(_ window: TmuxWindow?) async {
        guard let session = host.tmuxSession else { return }
        pendingShell = .tmux(session: session, windowIndex: window?.index, windowID: window?.windowID)
        phase = .connecting
        await openShellAndPump()
    }

    func selectHerdrSession(_ session: HerdrSession) async {
        pendingShell = .herdr(session: session.name, workspaceID: nil)
        phase = .connecting
        await openShellAndPump()
    }

    func openPlainShell() async {
        pendingShell = .plain(host.onConnectCommand)
        phase = .connecting
        await openShellAndPump()
    }

    func sendText(_ text: String) {
        bridge.processOutgoing(Data(text.utf8))
    }

    // Focus-in counts as client activity for tmux window-size latest without
    // reaching the pane, so the focused device wins the sizing battle.
    func nudgeTmuxSizing() {
        guard phase == .attached, isTmuxAttached else { return }
        bridge.sendToHost?(Data("\u{1b}[I".utf8))
    }

    var isTmuxAttached: Bool {
        if case .tmux = pendingShell { return true }
        return false
    }

    var isHerdrAttached: Bool {
        if case .herdr = pendingShell { return true }
        return false
    }

    var isMultiplexerAttached: Bool { isTmuxAttached || isHerdrAttached }

    var tmuxTarget: (session: String, windowIndex: Int?, windowID: String?)? {
        if case .tmux(let session, let windowIndex, let windowID) = pendingShell {
            return (session, windowIndex, windowID)
        }
        return nil
    }

    var herdrTarget: (session: String, workspaceID: String?)? {
        if case .herdr(let session, let workspaceID) = pendingShell {
            return (session, workspaceID)
        }
        return nil
    }

    var diagnosticSummary: String {
        let phaseName: String
        switch phase {
        case .idle: phaseName = "idle"
        case .connecting: phaseName = "connecting"
        case .pickingSession(let windows, let sessions):
            phaseName = "picking-session(tmux=\(windows.count),herdr=\(sessions.count))"
        case .attached: phaseName = "attached"
        case .reconnecting: phaseName = "reconnecting"
        case .failed: phaseName = "failed"
        case .exited: phaseName = "exited"
        }
        let lastInput = bridge.lastInputAt?.timeIntervalSince1970.description ?? "-"
        let lastWrite = lastWriteAt?.timeIntervalSince1970.description ?? "-"
        return
            "phase=\(phaseName) ssh=\(connection != nil) shell=\(shell != nil) outbound=\(bridge.sendToHost != nil) focus=\(bridge.isTerminalFocused) clone=\(cloneTag ?? "-") generation=\(shellGeneration) stopped=\(stopped) input=\(bridge.inputEvents)/\(bridge.inputBytes) lastInput=\(lastInput) writes=\(writeAttempts)/\(writeSuccesses)/\(writeFailures) lastWrite=\(lastWrite)"
    }

    func tmuxDiagnostics() async -> String {
        guard let connection else { return "unavailable: no SSH connection" }
        do {
            return try await connection.exec(Tmux.diagnosticsCommand())
        } catch {
            return "unavailable: tmux diagnostics failed"
        }
    }

    func preset(session: String, windowIndex: Int?, windowID: String? = nil) {
        pendingShell = .tmux(session: session, windowIndex: windowIndex, windowID: windowID)
    }

    func presetPlain() {
        pendingShell = .plain(host.onConnectCommand)
    }

    func presetHerdr(session: String, workspaceID: String? = nil) {
        pendingShell = .herdr(session: session, workspaceID: workspaceID)
    }

    func jump(toSession session: String, windowIndex: Int? = nil, windowID: String? = nil) async {
        pendingShell = .tmux(session: session, windowIndex: windowIndex, windowID: windowID)
        phase = .connecting
        shellGeneration += 1
        let old = shell
        shell = nil
        await old?.close()
        await openShellAndPump()
    }

    func createTmuxSession(named name: String) async -> Bool {
        guard let connection else { return false }
        return (try? await connection.exec(Tmux.newSessionCommand(name: name))) != nil
    }

    func createTmuxWindow(in session: String) async {
        guard let connection else { return }
        _ = try? await connection.exec(Tmux.newWindowCommand(session: session))
    }

    func renameTmuxWindow(session: String, windowIndex: Int, name: String) async {
        guard let connection else { return }
        _ = try? await connection.exec(Tmux.renameWindowCommand(session: session, windowIndex: windowIndex, name: name))
    }

    func renameTmuxSession(from oldName: String, to newName: String) async -> Bool {
        guard let connection else { return false }
        guard (try? await connection.exec(Tmux.renameSessionCommand(from: oldName, to: newName))) != nil else {
            return false
        }
        sessionRenamed(from: oldName, to: newName)
        return true
    }

    func sessionRenamed(from oldName: String, to newName: String) {
        if case .tmux(let session, let windowIndex, let windowID) = pendingShell, session == oldName {
            pendingShell = .tmux(session: newName, windowIndex: windowIndex, windowID: windowID)
        }
    }

    func reorderTmuxWindows(session: String, indexes: [Int], fromOffset: Int, toOffset: Int) async {
        guard let connection,
            let command = Tmux.reorderWindowsCommand(
                session: session, indexes: indexes, fromOffset: fromOffset, toOffset: toOffset)
        else { return }
        _ = try? await connection.exec(command)
    }

    func killTmuxWindow(session: String, windowIndex: Int) async {
        guard let connection else { return }
        _ = try? await connection.exec(Tmux.killWindowCommand(session: session, windowIndex: windowIndex))
    }

    func killTmuxSession(named name: String) async {
        guard let connection else { return }
        _ = try? await connection.exec(Tmux.killSessionCommand(name: name))
    }

    func tmuxSessions() async -> [TmuxSession] {
        guard let connection else { return [] }
        let output = (try? await connection.exec(Tmux.listSessionsCommand())) ?? ""
        return Tmux.consolidateGroups(Tmux.parseSessions(output))
    }

    func herdrSessions() async -> [HerdrSession] {
        guard let connection else { return [] }
        let output = (try? await connection.exec(Herdr.listSessionsCommand())) ?? ""
        return Herdr.parseSessions(output).filter(\.running)
    }

    func tmuxWindows(session: String) async -> [TmuxWindow] {
        guard let connection else { return [] }
        let output = (try? await connection.exec(Tmux.listWindowsCommand(session: session))) ?? ""
        return Tmux.parseWindows(output)
    }

    func openSFTP() async throws -> SFTPSession {
        guard let connection else { throw SSHError.notConnected }
        return try await connection.openSFTP()
    }

    func forwardPort(remoteHost: String, remotePort: Int) async throws -> PortForwardHandle {
        guard let connection else { throw SSHError.notConnected }
        return try await connection.forwardPort(localPort: 0, remoteHost: remoteHost, remotePort: remotePort)
    }

    func currentTmuxWindowIndex() async -> Int? {
        guard let connection, let cloneTag,
            case .tmux(let session, _, _) = pendingShell
        else { return nil }
        let clone = Tmux.cloneName(session: session, clientTag: cloneTag)
        let output = (try? await connection.exec(Tmux.currentWindowCommand(clone: clone))) ?? ""
        return Tmux.parseCurrentWindow(output)
    }

    func currentTmuxPaneSnapshot() async -> TmuxPaneSnapshot? {
        guard let connection, let cloneTag,
            case .tmux(let session, _, let windowID) = pendingShell
        else { return nil }
        guard
            let output = try? await connection.exec(
                Tmux.capturePaneSnapshotCommand(target: Tmux.cloneName(session: session, clientTag: cloneTag)))
        else { return nil }
        guard let snapshot = Tmux.parsePaneSnapshot(output) else { return nil }
        pendingShell = .tmux(
            session: session, windowIndex: snapshot.windowIndex, windowID: snapshot.windowID ?? windowID)
        return snapshot
    }

    func dashboardItems(session: String) async -> [WindowDashboardItem] {
        guard let connection else { return [] }
        let windowsOutput = (try? await connection.exec(Tmux.listWindowsCommand(session: session))) ?? ""
        let capturesOutput = (try? await connection.exec(Tmux.capturePanesCommand(session: session))) ?? ""
        let captures = Tmux.parsePaneCaptures(capturesOutput)
        var windows = Tmux.parseWindows(windowsOutput)
        if tmuxTarget?.session == session, let viewed = await currentTmuxWindowIndex() {
            windows = windows.map { window in
                var window = window
                window.active = window.index == viewed
                return window
            }
        }
        return windows.map { window in
            let text = captures[window.index] ?? ""
            let preview = Tmux.previewLines(text, count: 3)
            return WindowDashboardItem(
                window: window,
                preview: preview,
                status: AgentStatus.classify(text)
            )
        }
    }

    func appForegrounded() {
        if machine.handle(.appForegrounded) == .connect {
            retryTask?.cancel()
            Task { await reconnect() }
        }
    }

    private func establish(initial: Bool) async {
        phase = initial ? .connecting : phase
        let connection = SSHConnection(host: host, key: key, knownHosts: knownHosts, hops: hops)
        self.connection = connection
        do {
            try await connection.connect()
        } catch let error as SSHError {
            if case .hostKeyMismatch(let stored, let presented) = error {
                phase = .failed(
                    "HOST KEY CHANGED\nstored: \(stored)\npresented: \(presented)\nRemove host trust only if this is expected."
                )
                _ = machine.handle(.userDisconnect)
                return
            }
            handleConnectFailure(humanize(error))
            return
        } catch {
            handleConnectFailure(humanize(error))
            return
        }

        if host.tmuxSession != nil {
            Task { _ = try? await connection.exec(Tmux.cleanupClonesCommand()) }
        }

        if pendingShell == nil {
            await listInitialSessions(connection: connection)
        } else {
            await openShellAndPump()
        }
    }

    private func humanize(_ error: Error) -> String {
        if let ssh = error as? SSHError {
            switch ssh {
            case .authenticationFailed:
                return "auth failed — selected SSH key authorized on host? (Keys screen)"
            case .connectionClosed:
                return "connection closed during handshake"
            case .notConnected:
                return "not connected"
            case .commandFailed(let status):
                return "command failed (exit \(status))"
            case .hostKeyMismatch:
                return "host key mismatch"
            }
        }
        let text = "\(error)"
        if text.localizedCaseInsensitiveContains("timeout") || text.localizedCaseInsensitiveContains("timed out") {
            return "timeout — host unreachable (VPN/VLAN? Local Network permission in iOS Settings > Privacy?)"
        }
        if text.localizedCaseInsensitiveContains("refused") {
            return "connection refused — sshd running on port \(host.port)?"
        }
        if text.localizedCaseInsensitiveContains("unreachable") || text.localizedCaseInsensitiveContains("route") {
            return "host unreachable — check network/VPN and Local Network permission"
        }
        return text
    }

    private func listInitialSessions(connection: SSHConnection) async {
        let herdrOutput = (try? await connection.exec(Herdr.listSessionsCommand())) ?? ""
        let herdrSessions = Herdr.parseSessions(herdrOutput).filter(\.running)
        var tmuxWindows: [TmuxWindow] = []
        if let session = host.tmuxSession,
            let output = try? await connection.exec(Tmux.listWindowsCommand(session: session))
        {
            tmuxWindows = Tmux.parseWindows(output)
        }
        if tmuxWindows.isEmpty, herdrSessions.isEmpty {
            await openPlainShell()
        } else {
            phase = .pickingSession(tmuxWindows: tmuxWindows, herdrSessions: herdrSessions)
        }
    }

    private func openShellAndPump() async {
        guard let connection else { return }
        let size = bridge.currentSize
        let command: String?
        switch pendingShell {
        case .tmux(let session, let windowIndex, let windowID):
            let tag = String(UUID().uuidString.prefix(8)).lowercased()
            cloneTag = tag
            command = Tmux.attachCommand(
                session: session, windowIndex: windowIndex, windowID: windowID, clientTag: tag)
        case .herdr(let session, let workspaceID):
            cloneTag = nil
            if let workspaceID {
                _ = try? await connection.exec(Herdr.focusWorkspaceCommand(session: session, workspaceID: workspaceID))
            }
            command = Herdr.attachCommand(session: session)
        case .plain(let plain):
            cloneTag = nil
            command = plain
        case nil:
            cloneTag = nil
            command = nil
        }
        do {
            let shell = try await connection.openShell(
                command: command,
                cols: size.cols,
                rows: size.rows
            )
            self.shell = shell
            shellGeneration += 1
            let generation = shellGeneration
            bridge.sendToHost = { [weak self] data in
                self?.write(data, to: shell, generation: generation)
            }
            bridge.resizeHost = { cols, rows in
                Task { try? await shell.resize(cols, rows) }
            }
            bridge.imagePaste = { [weak self] data in
                Task { await self?.uploadPastedImage(data) }
            }
            bridge.userInteracted = { [weak self] in
                self?.nudgeTmuxSizing()
            }
            _ = machine.handle(.established)
            lastErrorMessage = nil
            phase = .attached
            Task { [weak self] in
                for await chunk in shell.output {
                    self?.bridge.feed(chunk)
                }
                await self?.handleStreamEnded(generation: generation)
            }
        } catch {
            handleConnectFailure("\(error)")
        }
    }

    private func write(_ data: Data, to shell: ShellStream, generation: Int) {
        writeAttempts += 1
        lastWriteAt = Date()
        Task { [weak self] in
            do {
                try await shell.write(data)
                guard let self, generation == self.shellGeneration else { return }
                self.writeSuccesses += 1
            } catch {
                guard let self, generation == self.shellGeneration, !self.stopped else { return }
                self.writeFailures += 1
                self.bridge.sendToHost = nil
                self.applyAction(self.machine.handle(.connectionLost), message: "terminal write failed")
            }
        }
    }

    private func uploadPastedImage(_ data: Data) async {
        guard let connection else { return }
        let path = RemoteFileUpload.remotePath()
        for command in RemoteFileUpload.commands(base64: data.base64EncodedString(), remotePath: path) {
            do {
                _ = try await connection.exec(command)
            } catch {
                bridge.feed(Data("\r\n[image paste failed: \(error)]\r\n".utf8))
                return
            }
        }
        bridge.sendPasted(path)
        bridge.sendToHost?(Data(" ".utf8))
    }

    private func handleStreamEnded(generation: Int) async {
        guard !stopped, generation == shellGeneration else { return }
        if let connection, await connection.isConnected {
            if isMultiplexerAttached {
                applyAction(machine.handle(.connectionLost), message: "persistent session ended")
                return
            }
            phase = .exited
            onExit?()
            return
        }
        applyAction(machine.handle(.connectionLost))
    }

    private func handleConnectFailure(_ message: String) {
        guard !stopped else { return }
        applyAction(machine.handle(.connectFailed), message: message)
    }

    private func applyAction(_ action: ReconnectMachine.Action, message: String = "connection lost") {
        switch action {
        case .scheduleRetry(let delay):
            lastErrorMessage = message
            let seconds = Int(delay.components.seconds)
            phase = .reconnecting("\(message)\nretrying in \(seconds)s")
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.retryNow()
            }
        case .connect:
            Task { await reconnect() }
        case .disconnect, .cancelRetry, .none:
            break
        }
    }

    private func retryNow() async {
        guard !stopped else { return }
        if machine.handle(.retryTimerFired) == .connect {
            await reconnect()
        }
    }

    private func reconnect() async {
        guard !stopped else { return }
        if let lastErrorMessage {
            phase = .reconnecting("reconnecting…\nlast error: \(lastErrorMessage)")
        } else {
            phase = .reconnecting("reconnecting…")
        }
        await connection?.disconnect()
        await establish(initial: false)
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                if self.machine.handle(.pathChanged) == .connect {
                    self.retryTask?.cancel()
                    await self.reconnect()
                }
            }
        }
        monitor.start(queue: .main)
    }
}
