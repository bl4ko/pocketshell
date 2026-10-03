#if os(macOS)
    import CryptoKit
    import Foundation
    import SSHKit
    import Testing

    @Suite(.serialized) struct RemoteFileUploadIntegrationTests {
        @Test func uploadsFilesWithoutChangingBytesOrNames() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeUploadConnection(sshd)
            try await connection.connect()
            let payload = Data((0..<150_013).map { UInt8($0 % 256) })
            for data in [payload, Data()] {
                let file = sshd.dir.appendingPathComponent("report draft's.bin")
                try data.write(to: file)
                let path = try await connection.uploadFile(at: file)
                let quote = RemoteFileUpload.quotedPath(path)
                let remoteHash = try await connection.exec("shasum -a 256 \(quote) | cut -d' ' -f1")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let localHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                #expect(remoteHash == localHash)
                #expect(URL(fileURLWithPath: path).lastPathComponent == file.lastPathComponent)
                let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
                #expect(permissions == 0o600)
                let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
                let directoryPermissions =
                    try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
                #expect(directoryPermissions == 0o700)
                #expect(!FileManager.default.fileExists(atPath: path + ".b64"))
                try FileManager.default.removeItem(at: directory)
            }
            do {
                _ = try await connection.uploadFile(at: sshd.dir)
                Issue.record("A directory must not be attached as a file")
            } catch is CocoaError {
                // The picker can return only a readable file.
            }
            await connection.disconnect()
        }

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
