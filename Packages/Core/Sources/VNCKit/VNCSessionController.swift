import CoreGraphics
import Foundation
@preconcurrency import RoyalVNCKit

public final class VNCSessionController: NSObject, ObservableObject, @unchecked Sendable {
    public enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case disconnected
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var image: CGImage?
    @Published public private(set) var framebufferSize: CGSize = .zero

    private let hostname: String
    private let port: UInt16
    private let username: String
    private let password: String

    private var connection: VNCConnection?
    private let renderLock = NSLock()
    private var renderScheduled = false

    public init(hostname: String, port: Int, username: String, password: String) {
        self.hostname = hostname
        self.port = UInt16(clamping: port)
        self.username = username
        self.password = password
    }

    public func connect() {
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
        publish { $0.phase = .connecting }
        connection.connect()
    }

    public func disconnect() {
        connection?.disconnect()
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
            switch status {
            case .connecting:
                controller.phase = .connecting
            case .connected:
                controller.phase = .connected
            case .disconnecting:
                break
            case .disconnected:
                if let message {
                    controller.phase = .failed(message)
                } else if controller.phase != .idle {
                    controller.phase = .disconnected
                }
            }
        }
    }

    public func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType, completion: @escaping (VNCCredential?) -> Void) {
        if authenticationType.requiresUsername {
            completion(VNCUsernamePasswordCredential(username: username, password: password))
        } else {
            completion(VNCPasswordCredential(password: password))
        }
    }

    public func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        publish { $0.framebufferSize = size }
        scheduleRender(framebuffer)
    }

    public func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        let size = framebuffer.cgSize
        publish { $0.framebufferSize = size }
        scheduleRender(framebuffer)
    }

    public func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        scheduleRender(framebuffer)
    }

    public func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
}
