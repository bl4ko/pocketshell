import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public struct PortForwardHandle: Sendable {
    public let localPort: Int
    private let serverChannel: Channel

    init(localPort: Int, serverChannel: Channel) {
        self.localPort = localPort
        self.serverChannel = serverChannel
    }

    public func stop() async {
        try? await serverChannel.close()
    }
}

extension SSHConnection {
    public func forwardPort(localPort: Int, remoteHost: String, remotePort: Int) async throws -> PortForwardHandle {
        guard let sshChannel = activeChannel else { throw SSHError.notConnected }

        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { local in
                let promise = local.eventLoop.makePromise(of: Channel.self)
                sshChannel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
                    switch result {
                    case .success(let handler):
                        let originator = try? SocketAddress(ipAddress: "127.0.0.1", port: 0)
                        let channelType = SSHChannelType.directTCPIP(.init(
                            targetHost: remoteHost,
                            targetPort: remotePort,
                            originatorAddress: originator ?? local.remoteAddress!
                        ))
                        handler.createChannel(promise, channelType: channelType) { ssh, _ in
                            ssh.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                                ssh.pipeline.addHandler(SSHToLocalGlue(peer: local))
                            }
                        }
                    case .failure(let error):
                        promise.fail(error)
                    }
                }
                return promise.futureResult.flatMap { ssh in
                    local.pipeline.addHandler(LocalToSSHGlue(peer: ssh)).map {
                        local.read()
                    }
                }.flatMapError { _ in
                    local.close()
                }
            }

        let server = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
        let boundPort = server.localAddress?.port ?? localPort
        return PortForwardHandle(localPort: boundPort, serverChannel: server)
    }
}

final class LocalToSSHGlue: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        peer.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
        context.read()
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil)
        context.close(promise: nil)
    }
}

final class SSHToLocalGlue: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let peer: Channel

    init(peer: Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        peer.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer.close(promise: nil)
        context.close(promise: nil)
    }
}
