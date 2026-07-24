#if os(macOS)
    import CryptoKit
    import Foundation
    import SSHKit
    import Testing

    @Suite(.serialized) struct RemoteFileUploadIntegrationTests {
        @Test func uploadsRealisticImagePayload() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeUploadConnection(sshd)
            try await connection.connect()

            var payload = Data(count: 900_000)
            payload.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 900_000, $0.baseAddress!) }
            let path = "/tmp/psh-repro-\(UUID().uuidString.prefix(8)).jpg"
            for (i, command) in RemoteFileUpload.commands(base64: payload.base64EncodedString(), remotePath: path)
                .enumerated()
            {
                do {
                    _ = try await connection.exec(command)
                } catch {
                    Issue.record("command \(i) (len \(command.count)) failed: \(error)")
                    await connection.disconnect()
                    return
                }
            }
            let remoteHash = try await connection.exec("shasum -a 256 '\(path)' | cut -d' ' -f1")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try? await connection.exec("rm -f '\(path)'")
            let localHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            #expect(remoteHash == localHash)
            await connection.disconnect()
        }
    }

    private func makeUploadConnection(_ sshd: TestSSHD) -> SSHConnection {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kh-\(UUID().uuidString).json")
        return SSHConnection(
            host: sshd.hostConfig(),
            key: sshd.clientKeyMaterial,
            knownHosts: KnownHostsStore(fileURL: file)
        )
    }
#endif
