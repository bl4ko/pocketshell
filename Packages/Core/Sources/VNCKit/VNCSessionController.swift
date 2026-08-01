import CoreGraphics
import Foundation
import ReconnectKit
@preconcurrency import RoyalVNCKit

public final class VNCSessionController: NSObject, ObservableObject, @unchecked Sendable {
    public enum Phase: Equatable {
        case idle
        case connecting
        case authenticating
        case connected
        case failed(String)
        case disconnected
        case reconnecting(attempt: Int)

        public var isBusy: Bool {
            switch self {
            case .connecting, .authenticating, .reconnecting: true
            case .idle, .connected, .failed, .disconnected: false
            }
        }

        public var overlayLabel: String {
            switch self {
            case .idle: "starting…"
            case .connecting: "connecting…"
            case .authenticating: "authenticating…"
            case .connected: "waiting for first frame…"
            case .reconnecting(let attempt): "reconnecting… (attempt \(attempt))"
            case .failed(let message): message
            case .disconnected: "disconnected"
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var image: CGImage?
    @Published public private(set) var framebufferSize: CGSize = .zero

    private let hostname: String
    private let port: UInt16
    private let username: String
    private let password: String

    private var connection: VNCConnection?
    private var machine = ReconnectMachine()
    private var retryTask: Task<Void, Never>?
    private let renderLock = NSLock()
    private var renderScheduled = false

    public init(hostname: String, port: Int, username: String, password: String) {
        self.hostname = hostname
        self.port = UInt16(clamping: port)
        self.username = username
        self.password = password
    }

    public func connect() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            perform(machine.handle(machine.state == .idle ? .userConnect : .retryTimerFired))
        }
    }

    public func disconnect() {
        send(.userDisconnect)
    }

    public func appBecameActive() {
        send(.appForegrounded)
    }

    private func send(_ event: ReconnectMachine.Event) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            perform(machine.handle(event))
        }
    }

    private func perform(_ action: ReconnectMachine.Action) {
        switch action {
        case .connect:
            retryTask?.cancel()
            retryTask = nil
            openConnection()
        case .scheduleRetry(let delay):
            guard case .waitingToReconnect(let failures, _) = machine.state else { return }
            phase = .reconnecting(attempt: failures)
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.send(.retryTimerFired)
            }
        case .disconnect:
            retryTask?.cancel()
            retryTask = nil
            teardownConnection()
            phase = .disconnected
        case .cancelRetry:
            retryTask?.cancel()
            retryTask = nil
            teardownConnection()
        case .none:
            break
        }
    }

    private func openConnection() {
        teardownConnection()
        image = nil
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: hostname,
            port: port,
            isShared: true,
            isScalingEnabled: false,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        self.connection = connection
        phase = .connecting
        connection.connect()
    }

    private func teardownConnection() {
        guard let connection else { return }
        connection.delegate = nil
        connection.disconnect()
        self.connection = nil
    }

    public func pointerMove(to point: CGPoint) {
        let pixel = VNCPointerMath.clampedPixel(point, imageSize: framebufferSize)
        connection?.mouseMove(x: pixel.x, y: pixel.y)
    }

    public func click(_ button: VNCMouseButton, at point: CGPoint) {
        let pixel = VNCPointerMath.clampedPixel(point, imageSize: framebufferSize)
        connection?.mouseMove(x: pixel.x, y: pixel.y)
        connection?.mouseButtonDown(button, x: pixel.x, y: pixel.y)
        connection?.mouseButtonUp(button, x: pixel.x, y: pixel.y)
    }

    public func doubleClick(at point: CGPoint) {
        click(.left, at: point)
        click(.left, at: point)
    }

    public func scroll(_ wheel: VNCMouseWheel, at point: CGPoint, steps: Int) {
        let pixel = VNCPointerMath.clampedPixel(point, imageSize: framebufferSize)
        connection?.mouseWheel(wheel, x: pixel.x, y: pixel.y, steps: UInt32(max(steps, 1)))
    }

    public func sendText(_ text: String) {
        for key in VNCKeyCode.keyCodesFrom(characters: text) {
            connection?.keyDown(key)
            connection?.keyUp(key)
        }
    }

    public func sendKey(_ key: VNCKeyCode) {
        connection?.keyDown(key)
        connection?.keyUp(key)
    }

    public func sendKey(_ key: VNCKeyCode, modifiers: [VNCKeyCode]) {
        for modifier in modifiers {
            connection?.keyDown(modifier)
        }
        connection?.keyDown(key)
        connection?.keyUp(key)
        for modifier in modifiers.reversed() {
            connection?.keyUp(modifier)
        }
    }

    private func publish(_ apply: @escaping @Sendable (VNCSessionController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            apply(self)
        }
    }

    private func scheduleRender(_ framebuffer: VNCFramebuffer) {
        renderLock.lock()
        let alreadyScheduled = renderScheduled
        renderScheduled = true
        renderLock.unlock()
        guard !alreadyScheduled else { return }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.033) { [weak self] in
            guard let self else { return }
            self.renderLock.lock()
            self.renderScheduled = false
            self.renderLock.unlock()
            let rendered = framebuffer.cgImage
            self.publish { $0.image = rendered }
        }
    }
}

extension VNCSessionController: VNCConnectionDelegate {
    public func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        let status = connectionState.status
        let message = connectionState.error.map { error in
            (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        publish { controller in
            guard connection === controller.connection else { return }
            switch status {
            case .connecting:
                controller.phase = .connecting
            case .connected:
                controller.phase = .connected
                controller.perform(controller.machine.handle(.established))
            case .disconnecting:
                break
            case .disconnected:
                let lost = controller.machine.state == .connected
                if let message {
                    controller.phase = .failed(message)
                } else if controller.phase != .idle {
                    controller.phase = .disconnected
                }
                controller.perform(controller.machine.handle(lost ? .connectionLost : .connectFailed))
            }
        }
    }

    public func connection(
        _ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCCredential?) -> Void
    ) {
        publish { $0.phase = .authenticating }
        if authenticationType.requiresUsername {
            completion(VNCUsernamePasswordCredential(username: username, password: password))
        } else {
            completion(VNCPasswordCredential(password: password))
        }
    }

    public func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        publish { $0.framebufferSize = size }
    }

    public func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        publish { $0.framebufferSize = size }
    }

    public func connection(
        _ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer, x: UInt16, y: UInt16,
        width: UInt16, height: UInt16
    ) {
        scheduleRender(framebuffer)
    }

    public func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}
