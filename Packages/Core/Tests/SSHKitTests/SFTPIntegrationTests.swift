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

        @Test func pipelinedDownloadMatchesBytesForVariousSizes() async throws {
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
            let sftp = try await connection.openSFTP()
            for size in [0, 1, 100, 32768, 32769, 32768 * 16, 3_000_001] {
                let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
                let url = sshd.dir.appendingPathComponent("size-\(size).bin")
                try payload.write(to: url)
                let downloaded = try await sftp.download(url.path)
                #expect(downloaded == payload, "size \(size)")
            }
            await sftp.close()
            await connection.disconnect()
        }
    }
#endif
