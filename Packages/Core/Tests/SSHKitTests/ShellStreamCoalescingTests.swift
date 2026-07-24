#if os(macOS)
    import Foundation
    import SSHKit
    import Testing

    @Suite(.serialized) struct ShellStreamCoalescingTests {
        @Test func coalescesBulkOutputIntoLargeChunks() async throws {
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

            let shell = try await connection.openShell(
                command: "dd if=/dev/zero bs=1048576 count=8 2>/dev/null | base64",
                cols: 80,
                rows: 24
            )
            var total = 0
            var chunks = 0
            for await chunk in shell.output {
                total += chunk.count
                chunks += 1
            }
            #expect(total > 8_000_000)
            #expect(total / chunks > 4096, "avg chunk \(total / chunks)B across \(chunks) chunks")
            await connection.disconnect()
        }
    }
#endif
