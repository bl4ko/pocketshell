import Crypto
import Foundation
import KeyKit
import Models
import NIOCore
import NIOPosix
import NIOSSH

public enum SSHError: Error, Equatable, Sendable {
    case notConnected
    case connectionClosed
    case hostKeyMismatch(stored: String, presented: String)
    case authenticationFailed
    case commandFailed(exitStatus: Int)
}

public struct ShellStream: Sendable {
    public let output: AsyncStream<Data>
    public let write: @Sendable (Data) async throws -> Void
    public let resize: @Sendable (_ cols: Int, _ rows: Int) async throws -> Void
    public let close: @Sendable () async -> Void
}

public actor SSHConnection {
    private let host: HostConfig
    private let key: DeviceKeyMaterial
    private let knownHosts: KnownHostsStore
    private var channel: Channel?

    public init(host: HostConfig, key: DeviceKeyMaterial, knownHosts: KnownHostsStore) {
        self.host = host
        self.key = key
        self.knownHosts = knownHosts
    }

    public var isConnected: Bool {
        channel?.isActive ?? false
    }

    public func connect() async throws {
        let userAuth = KeyAuthDelegate(username: host.username, key: key)
        let serverAuth = TOFUServerAuthDelegate(host: host.hostname, port: host.port, store: knownHosts)
        let handshake = HandshakeWaiter()

        let bootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                let config = SSHClientConfiguration(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)
                let sshHandler = NIOSSHHandler(
                    role: .client(config),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandler(sshHandler).flatMap {
                    channel.pipeline.addHandler(handshake)
                }
            }

        let channel = try await bootstrap.connect(host: host.hostname, port: host.port).get()
        do {
            try await handshake.waitForAuth()
        } catch {
            try? await channel.close()
            throw error
        }
        self.channel = channel
    }

    public func disconnect() async {
        guard let channel else { return }
        self.channel = nil
        try? await channel.close()
    }

    public func waitUntilClosed() async {
        guard let channel else { return }
        try? await channel.closeFuture.get()
    }

    public func exec(_ command: String) async throws -> String {
        let collector = ExecCollector()
        let childChannel = try await createChildChannel { child in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.pipeline.addHandler(collector)
            }
        }

        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        try await childChannel.triggerUserOutboundEvent(exec)
        return try await collector.result()
    }

    public func openShell(command: String? = nil, cols: Int, rows: Int) async throws -> ShellStream {
        var continuation: AsyncStream<Data>.Continuation!
        let output = AsyncStream<Data> { continuation = $0 }
        let dataHandler = ShellDataHandler(continuation: continuation)

        let childChannel = try await createChildChannel { child in
            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                child.pipeline.addHandler(dataHandler)
            }
        }

        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await childChannel.triggerUserOutboundEvent(pty)
        if let command {
            try await childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            )
        } else {
            try await childChannel.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true))
        }

        return ShellStream(
            output: output,
            write: { data in
                var buffer = childChannel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                try await childChannel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
            },
            resize: { cols, rows in
                let change = SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0
                )
                try await childChannel.triggerUserOutboundEvent(change)
            },
            close: {
                try? await childChannel.close()
            }
        )
    }

    private func createChildChannel(
        _ initializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        guard let channel, channel.isActive else { throw SSHError.notConnected }
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                switch result {
                case .success(let handler):
                    handler.createChannel(promise) { child, _ in initializer(child) }
                case .failure(let error):
                    promise.fail(error)
                }
            }
        }
        return try await promise.futureResult.get()
    }
}

final class TOFUServerAuthDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let store: KnownHostsStore

    init(host: String, port: Int, store: KnownHostsStore) {
        self.host = host
        self.port = port
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        switch store.check(host: host, port: port, publicKeyLine: line) {
        case .match:
            validationCompletePromise.succeed(())
        case .firstUse:
            do {
                try store.trust(host: host, port: port, publicKeyLine: line)
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        case .mismatch(let stored, let presented):
            validationCompletePromise.fail(SSHError.hostKeyMismatch(stored: stored, presented: presented))
        }
    }
}

final class KeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let key: DeviceKeyMaterial
    private var offered = false

    init(username: String, key: DeviceKeyMaterial) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHError.authenticationFailed)
            return
        }
        offered = true
        let privateKey: NIOSSHPrivateKey = switch key {
        case .enclave(let key): NIOSSHPrivateKey(secureEnclaveP256Key: key)
        case .software(let key): NIOSSHPrivateKey(p256Key: key)
        case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        ))
    }
}

final class HandshakeWaiter: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private var promise: EventLoopPromise<Void>?
    private var result: Result<Void, Error>?
    private let lock = NSLock()

    func waitForAuth() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            let promise = pendingLoop!.makePromise(of: Void.self)
            self.promise = promise
            lock.unlock()
            promise.futureResult.whenComplete { continuation.resume(with: $0) }
        }
    }

    private var pendingLoop: EventLoop?

    func handlerAdded(context: ChannelHandlerContext) {
        lock.lock()
        pendingLoop = context.eventLoop
        lock.unlock()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.failure(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.failure(SSHError.connectionClosed))
        context.fireChannelInactive()
    }

    private func complete(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let promise = self.promise
        lock.unlock()
        switch value {
        case .success: promise?.succeed(())
        case .failure(let error): promise?.fail(error)
        }
    }
}

final class ShellDataHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        continuation.yield(Data(buffer.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }
}

final class ExecCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let lock = NSLock()
    private var output = Data()
    private var exitStatus: Int?
    private var loop: EventLoop?
    private var promise: EventLoopPromise<String>?
    private var finished: Result<String, Error>?

    func result() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            lock.lock()
            if let finished {
                lock.unlock()
                continuation.resume(with: finished)
                return
            }
            let promise = loop!.makePromise(of: String.self)
            self.promise = promise
            lock.unlock()
            promise.futureResult.whenComplete { continuation.resume(with: $0) }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        lock.lock()
        loop = context.eventLoop
        lock.unlock()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        lock.lock()
        output.append(Data(buffer.readableBytesView))
        lock.unlock()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            lock.lock()
            exitStatus = status.exitStatus
            lock.unlock()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        let value: Result<String, Error>
        if let exitStatus, exitStatus != 0 {
            value = .failure(SSHError.commandFailed(exitStatus: exitStatus))
        } else {
            value = .success(String(data: output, encoding: .utf8) ?? "")
        }
        finished = value
        let promise = self.promise
        lock.unlock()
        switch value {
        case .success(let text): promise?.succeed(text)
        case .failure(let error): promise?.fail(error)
        }
        context.fireChannelInactive()
    }
}
