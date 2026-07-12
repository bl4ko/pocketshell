import Foundation
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
        case pickingWindow([TmuxWindow])
        case attached
        case reconnecting(String)
        case failed(String)
        case exited
    }

    @Published var phase: Phase = .idle
    let bridge = TerminalBridge()
    var onExit: (() -> Void)?

    private let host: HostConfig
    private let key: DeviceKeyMaterial
    private let knownHosts: KnownHostsStore
    private var connection: SSHConnection?
    private var shell: ShellStream?
    private var machine = ReconnectMachine(baseDelay: .seconds(3))
    private var lastErrorMessage: String?
    private var monitor: NWPathMonitor?
    private enum PendingShell {
        case tmux(session: String, windowIndex: Int?)
        case plain(String?)
    }

    private var retryTask: Task<Void, Never>?
    private var pendingShell: PendingShell?
    private var cloneTag: String?
    private var shellGeneration = 0
    private var stopped = false

    init(host: HostConfig, key: DeviceKeyMaterial, knownHosts: KnownHostsStore) {
        self.host = host
        self.key = key
        self.knownHosts = knownHosts
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
        pendingShell = .tmux(session: session, windowIndex: window?.index)
        await openShellAndPump()
    }

    func openPlainShell() async {
        pendingShell = .plain(host.onConnectCommand)
        await openShellAndPump()
    }

    func sendText(_ text: String) {
        bridge.processOutgoing(Data(text.utf8))
    }

    var isTmuxAttached: Bool {
        if case .tmux = pendingShell { return true }
        return false
    }

    var tmuxTarget: (session: String, windowIndex: Int?)? {
        if case .tmux(let session, let windowIndex) = pendingShell {
            return (session, windowIndex)
        }
        return nil
    }

    func preset(session: String, windowIndex: Int?) {
        pendingShell = .tmux(session: session, windowIndex: windowIndex)
    }

    func presetPlain() {
        pendingShell = .plain(host.onConnectCommand)
    }

    func jump(toSession session: String, windowIndex: Int? = nil) async {
        pendingShell = .tmux(session: session, windowIndex: windowIndex)
        shellGeneration += 1
        let old = shell
        shell = nil
        await old?.close()
        await openShellAndPump()
    }

    func createTmuxSession(named name: String) async {
        guard let connection else { return }
        _ = try? await connection.exec(Tmux.newSessionCommand(name: name))
        await jump(toSession: name)
    }

    func renameTmuxWindow(session: String, windowIndex: Int, name: String) async {
        guard let connection else { return }
        _ = try? await connection.exec(Tmux.renameWindowCommand(session: session, windowIndex: windowIndex, name: name))
    }

    func renameTmuxSession(from oldName: String, to newName: String) async {
        guard let connection else { return }
        _ = try? await connection.exec(Tmux.renameSessionCommand(from: oldName, to: newName))
        if case .tmux(let session, let windowIndex) = pendingShell, session == oldName {
            pendingShell = .tmux(session: newName, windowIndex: windowIndex)
        }
    }

    func reorderTmuxWindows(session: String, indexes: [Int], fromOffset: Int, toOffset: Int) async {
        guard let connection,
              let command = Tmux.reorderWindowsCommand(session: session, indexes: indexes, fromOffset: fromOffset, toOffset: toOffset)
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
              case .tmux(let session, _) = pendingShell else { return nil }
        let clone = Tmux.cloneName(session: session, clientTag: cloneTag)
        let output = (try? await connection.exec(Tmux.currentWindowCommand(clone: clone))) ?? ""
        return Tmux.parseCurrentWindow(output)
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
        let connection = SSHConnection(host: host, key: key, knownHosts: knownHosts)
        self.connection = connection
        do {
            try await connection.connect()
        } catch let error as SSHError {
            if case .hostKeyMismatch(let stored, let presented) = error {
                phase = .failed("HOST KEY CHANGED\nstored: \(stored)\npresented: \(presented)\nRemove host trust only if this is expected.")
                _ = machine.handle(.userDisconnect)
                return
            }
            handleConnectFailure(humanize(error))
            return
        } catch {
            handleConnectFailure(humanize(error))
            return
        }

        if let session = host.tmuxSession, pendingShell == nil {
            await listTmuxWindows(connection: connection, session: session)
        } else {
            await openShellAndPump()
        }
    }

    private func humanize(_ error: Error) -> String {
        if let ssh = error as? SSHError {
            switch ssh {
            case .authenticationFailed:
                return "auth failed — device key installed on host? (Keys screen)"
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

    private func listTmuxWindows(connection: SSHConnection, session: String) async {
        do {
            let output = try await connection.exec(Tmux.listWindowsCommand(session: session))
            let windows = Tmux.parseWindows(output)
            if windows.isEmpty {
                await openPlainShell()
            } else {
                phase = .pickingWindow(windows)
            }
        } catch {
            await openPlainShell()
        }
    }

    private func openShellAndPump() async {
        guard let connection else { return }
        let size = bridge.currentSize
        let command: String?
        switch pendingShell {
        case .tmux(let session, let windowIndex):
            let tag = String(UUID().uuidString.prefix(8)).lowercased()
            cloneTag = tag
            command = Tmux.attachCommand(session: session, windowIndex: windowIndex, clientTag: tag)
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
            bridge.sendToHost = { data in
                Task { try? await shell.write(data) }
            }
            bridge.resizeHost = { cols, rows in
                Task { try? await shell.resize(cols, rows) }
            }
            bridge.imagePaste = { [weak self] data in
                Task { await self?.uploadPastedImage(data) }
            }
            _ = machine.handle(.established)
            lastErrorMessage = nil
            phase = .attached
            shellGeneration += 1
            let generation = shellGeneration
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

    private func uploadPastedImage(_ data: Data) async {
        guard let connection else { return }
        let path = RemoteFileUpload.remotePath()
        for command in RemoteFileUpload.commands(base64: data.base64EncodedString(), remotePath: path) {
            guard (try? await connection.exec(command)) != nil else { return }
        }
        bridge.sendToHost?(Data("\(path) ".utf8))
    }

    private func handleStreamEnded(generation: Int) async {
        guard !stopped, generation == shellGeneration else { return }
        if let connection, await connection.isConnected {
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
