#if os(macOS)
    import Foundation
    import Models
    import NIOCore
    import NIOPosix
    import Testing
    @testable import SSHKit

    private final class BannerCollector: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        let promise: EventLoopPromise<String>

        init(promise: EventLoopPromise<String>) {
            self.promise = promise
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            let text = buffer.readString(length: buffer.readableBytes) ?? ""
            promise.succeed(text)
            context.close(promise: nil)
        }
    }

    @Suite(.serialized) struct PortForwardIntegrationTests {
        @Test func forwardsLocalPortToRemoteService() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kh-\(UUID().uuidString).json")
            let connection = SSHConnection(
                host: sshd.hostConfig(),
                key: sshd.clientKeyMaterial,
                knownHosts: KnownHostsStore(fileURL: file)
            )
            try await connection.connect()

            let forward = try await connection.forwardPort(
                localPort: 0,
                remoteHost: "127.0.0.1",
                remotePort: sshd.port
            )
            #expect(forward.localPort > 0)

            let group = MultiThreadedEventLoopGroup.singleton
            let promise = group.next().makePromise(of: String.self)
            let client = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(BannerCollector(promise: promise))
                }
                .connect(host: "127.0.0.1", port: forward.localPort)
                .get()
            let banner = try await promise.futureResult.get()
            #expect(banner.hasPrefix("SSH-2.0"))
            try? await client.close()

            await forward.stop()
            await connection.disconnect()
        }
    }
#endif
