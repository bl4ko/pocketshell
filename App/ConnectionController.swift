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
    }

    @Published var phase: Phase = .idle
    let bridge = TerminalBridge()

    private let host: HostConfig
    private let key: DeviceKeyMaterial
    private let knownHosts: KnownHostsStore
    private var connection: SSHConnection?
    private var shell: ShellStream?
    private var machine = ReconnectMachine()
    private var monitor: NWPathMonitor?
    private var retryTask: Task<Void, Never>?
    private var attachCommand: String?
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
        attachCommand = Tmux.attachCommand(session: session, windowIndex: window?.index)
        await openShellAndPump()
    }

    func openPlainShell() async {
        attachCommand = host.onConnectCommand
        await openShellAndPump()
    }

    func sendText(_ text: String) {
        bridge.processOutgoing(Data(text.utf8))
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
            handleConnectFailure("\(error)")
            return
        } catch {
            handleConnectFailure(error.localizedDescription)
            return
        }

        if initial, let session = host.tmuxSession {
            await listTmuxWindows(connection: connection, session: session)
        } else {
            await openShellAndPump()
        }
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
        do {
            let shell = try await connection.openShell(
                command: attachCommand,
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
            _ = machine.handle(.established)
            phase = .attached
            Task { [weak self] in
                for await chunk in shell.output {
                    self?.bridge.feed(chunk)
                }
                await self?.handleStreamEnded()
            }
        } catch {
            handleConnectFailure("\(error)")
        }
    }

    private func handleStreamEnded() async {
        guard !stopped else { return }
        applyAction(machine.handle(.connectionLost))
    }

    private func handleConnectFailure(_ message: String) {
        guard !stopped else { return }
        applyAction(machine.handle(.connectFailed), message: message)
    }

    private func applyAction(_ action: ReconnectMachine.Action, message: String = "connection lost") {
        switch action {
        case .scheduleRetry(let delay):
            let seconds = Double(delay.components.seconds)
            phase = .reconnecting("\(message) — retrying in \(Int(seconds))s")
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
        phase = .reconnecting("reconnecting…")
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
