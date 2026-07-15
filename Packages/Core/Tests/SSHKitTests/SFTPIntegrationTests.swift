#if os(macOS)
    import Foundation
    import Models
    import SFTPKit
    import Testing
    @testable import SSHKit

    @Suite(.serialized) struct SFTPIntegrationTests {
        @Test func listsDirectoryAndDownloadsFile() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }

            let payload = Data((0..<70_000).map { UInt8($0 % 251) })
            let fileURL = sshd.dir.appendingPathComponent("blob.bin")
            try payload.write(to: fileURL)

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kh-\(UUID().uuidString).json")
            let connection = SSHConnection(
                host: sshd.hostConfig(),
                key: sshd.clientKeyMaterial,
                knownHosts: KnownHostsStore(fileURL: file)
            )
            try await connection.connect()
            let sftp = try await connection.openSFTP()

            let home = try await sftp.realPath(".")
            #expect(home.hasPrefix("/"))

            let entries = try await sftp.listDirectory(sshd.dir.path)
            #expect(entries.contains { $0.filename == "blob.bin" && !$0.attributes.isDirectory })
            #expect(entries.first { $0.filename == "blob.bin" }?.attributes.size == UInt64(payload.count))

            let downloaded = try await sftp.download(fileURL.path)
            #expect(downloaded == payload)

            await sftp.close()
            await connection.disconnect()
        }
    }
#endif
