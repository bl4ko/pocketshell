#if os(macOS)
    import Crypto
    import Foundation
    import KeyKit
    import Models
    import NIOCore
    import Testing
    @testable import SSHKit

    final class TestSSHD {
        let port: Int
        let dir: URL
        let clientKeyMaterial: DeviceKeyMaterial
        private let process: Process

        var clientKey: P256.Signing.PrivateKey {
            guard case .software(let key) = clientKeyMaterial else { fatalError("not a software key") }
            return key
        }

        init(
            key: DeviceKeyMaterial = .software(P256.Signing.PrivateKey()),
            sftpServer: String = "/usr/libexec/sftp-server"
        ) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pocketshell-sshd-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            port = Self.freePort()
            clientKeyMaterial = key

            let hostKey = dir.appendingPathComponent("host_ed25519")
            let keygen = Process()
            keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            keygen.arguments = ["-t", "ed25519", "-N", "", "-f", hostKey.path, "-q"]
            try keygen.run()
            keygen.waitUntilExit()

            let authorizedKeys = dir.appendingPathComponent("authorized_keys")
            let pubLine = clientKeyMaterial.openSSHPublicKeyLine(comment: "test")
            try (pubLine + "\n").write(to: authorizedKeys, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedKeys.path)

            let config = """
                Port \(port)
                ListenAddress 127.0.0.1
                HostKey \(hostKey.path)
                PidFile \(dir.appendingPathComponent("sshd.pid").path)
                AuthorizedKeysFile \(authorizedKeys.path)
                StrictModes no
                UsePAM no
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                LogLevel QUIET
                AcceptEnv LANG LC_*
                Subsystem sftp \(sftpServer)
                """
            let configURL = dir.appendingPathComponent("sshd_config")
            try config.write(to: configURL, atomically: true, encoding: .utf8)

            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            process.arguments = ["-D", "-f", configURL.path]
            try process.run()
            Thread.sleep(forTimeInterval: 0.5)
        }

        private static func freePort() -> Int {
            for _ in 0..<50 {
                let candidate = Int.random(in: 20000...29999)
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                defer { close(fd) }
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(candidate).bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if rc == 0 { return candidate }
            }
            return Int.random(in: 20000...29999)
        }

        var username: String { NSUserName() }

        func hostConfig(keyTag: String = "test") -> HostConfig {
            HostConfig(name: "test", hostname: "127.0.0.1", port: port, username: username, keyTag: keyTag)
        }

        func stop() {
            process.terminate()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private actor OutcomeBox {
        private var value: String?
        func set(_ v: String) { value = v }
        func get() -> String? { value }
    }

    private func makeConnection(_ sshd: TestSSHD, knownHostsFile: URL? = nil) -> SSHConnection {
        let file =
            knownHostsFile
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kh-\(UUID().uuidString).json")
        return SSHConnection(
            host: sshd.hostConfig(),
            key: sshd.clientKeyMaterial,
            knownHosts: KnownHostsStore(fileURL: file)
        )
    }

    @Suite(.serialized) struct SSHConnectionIntegrationTests {
        @Test func connectsAndExecsCommand() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            let output = try await connection.exec("echo hello")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
            await connection.disconnect()
        }

        @Test func fallsBackToAlternateHostname() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            var host = sshd.hostConfig()
            host.hostname = "127.0.0.2"
            host.alternateHostnames = ["127.0.0.1"]
            let connection = SSHConnection(
                host: host,
                key: sshd.clientKeyMaterial,
                knownHosts: KnownHostsStore(
                    fileURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("kh-\(UUID().uuidString).json"))
            )

            try await connection.connect()
            let output = try await connection.exec("echo fallback")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "fallback")
            await connection.disconnect()
        }

        @Test func connectsThroughJumpHost() async throws {
            let bastion = try TestSSHD()
            defer { bastion.stop() }
            let target = try TestSSHD()
            defer { target.stop() }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kh-\(UUID().uuidString).json")
            let connection = SSHConnection(
                host: target.hostConfig(),
                key: target.clientKeyMaterial,
                knownHosts: KnownHostsStore(fileURL: file),
                hops: [SSHHop(host: bastion.hostConfig(), key: bastion.clientKeyMaterial)]
            )
            try await connection.connect()
            let output = try await connection.exec("echo jumped")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "jumped")
            await connection.disconnect()
        }

        @Test func jumpHostRecordsBothHostKeys() async throws {
            let bastion = try TestSSHD()
            defer { bastion.stop() }
            let target = try TestSSHD()
            defer { target.stop() }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kh-\(UUID().uuidString).json")
            let store = KnownHostsStore(fileURL: file)
            let connection = SSHConnection(
                host: target.hostConfig(),
                key: target.clientKeyMaterial,
                knownHosts: store,
                hops: [SSHHop(host: bastion.hostConfig(), key: bastion.clientKeyMaterial)]
            )
            try await connection.connect()
            await connection.disconnect()
            #expect(try store.entries().count == 2)
        }

        @Test func shellChannelEchoesInput() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            let shell = try await connection.openShell(cols: 80, rows: 24)

            try await shell.write(Data("echo pocketshell-$((20+3))\n".utf8))

            var collected = Data()
            let deadline = Date().addingTimeInterval(5)
            for await chunk in shell.output {
                collected.append(chunk)
                if String(data: collected, encoding: .utf8)?.contains("pocketshell-23") == true { break }
                if Date() > deadline { break }
            }
            #expect(String(data: collected, encoding: .utf8)?.contains("pocketshell-23") == true)
            await connection.disconnect()
        }

        @Test func recordsHostKeyOnFirstUseAndMatchesOnSecondConnect() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kh-\(UUID().uuidString).json")

            let first = makeConnection(sshd, knownHostsFile: file)
            try await first.connect()
            await first.disconnect()

            let store = KnownHostsStore(fileURL: file)
            let entries = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
            #expect(entries.count == 1)
            #expect(entries.values.first?.hasPrefix("SHA256:") == true)

            let second = SSHConnection(host: sshd.hostConfig(), key: sshd.clientKeyMaterial, knownHosts: store)
            try await second.connect()
            let output = try await second.exec("true; echo ok")
            #expect(output.contains("ok"))
            await second.disconnect()
        }

        @Test func mismatchedHostKeyFailsConnection() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kh-\(UUID().uuidString).json")
            let store = KnownHostsStore(fileURL: file)
            try store.trust(
                host: "127.0.0.1",
                port: sshd.port,
                publicKeyLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKq7fXeQdOTBjLKk9Yyoo3XU4dWnCT6r7cM+RJ9dLbAe"
            )

            let connection = SSHConnection(host: sshd.hostConfig(), key: .software(sshd.clientKey), knownHosts: store)
            await #expect(throws: (any Error).self) {
                try await connection.connect()
            }
        }

        @Test func wrongKeyFailsAuthenticationQuickly() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kh-\(UUID().uuidString).json")
            let connection = SSHConnection(
                host: sshd.hostConfig(),
                key: .software(P256.Signing.PrivateKey()),
                knownHosts: KnownHostsStore(fileURL: file)
            )
            let box = OutcomeBox()
            Task {
                do {
                    try await connection.connect()
                    await box.set("connected")
                } catch SSHError.authenticationFailed {
                    await box.set("authFailed")
                } catch {
                    await box.set("error: \(error)")
                }
            }
            var outcome = "hung"
            for _ in 0..<80 {
                if let value = await box.get() {
                    outcome = value
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(outcome == "authFailed")
        }

        @Test func failedChannelSetupClosesChildChannel() async throws {
            struct SetupFailure: Error {}
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            for _ in 0..<15 {
                let child = try await connection.createChildChannel { $0.eventLoop.makeSucceededFuture(()) }
                await #expect(throws: SetupFailure.self) {
                    try await connection.closingOnFailure(child) { throw SetupFailure() }
                }
                #expect(!child.isActive)
            }
            let output = try await connection.exec("echo still-works")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "still-works")
            await connection.disconnect()
        }

        private final class ChannelLog: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [Channel] = []
            func add(_ channel: Channel) {
                lock.lock()
                items.append(channel)
                lock.unlock()
            }
            var all: [Channel] {
                lock.lock()
                defer { lock.unlock() }
                return items
            }
        }

        private func expectCallSiteClosesChannel(
            _ call: @escaping @Sendable (SSHConnection) async throws -> Void
        ) async throws {
            struct SetupFailure: Error {}
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            let log = ChannelLog()
            await connection.setSetupFault { channel in
                log.add(channel)
                throw SetupFailure()
            }
            for _ in 0..<12 {
                await #expect(throws: SetupFailure.self) { try await call(connection) }
            }
            #expect(log.all.count == 12)
            #expect(log.all.allSatisfy { !$0.isActive })
            await connection.setSetupFault(nil)
            let output = try await connection.exec("echo still-works")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "still-works")
            await connection.disconnect()
        }

        @Test func execClosesChildChannelWhenSetupFails() async throws {
            try await expectCallSiteClosesChannel { _ = try await $0.exec("true") }
        }

        @Test func openShellClosesChildChannelWhenSetupFails() async throws {
            try await expectCallSiteClosesChannel { _ = try await $0.openShell(cols: 80, rows: 24) }
        }

        @Test func openSFTPClosesChildChannelWhenSetupFails() async throws {
            try await expectCallSiteClosesChannel { _ = try await $0.openSFTP() }
        }

        @Test func execWorksWhileShellChannelOpen() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            let shell = try await connection.openShell(cols: 80, rows: 24)
            let pump = Task {
                for await _ in shell.output {}
            }

            let box = OutcomeBox()
            Task {
                do {
                    let output = try await connection.exec("echo side-channel-ok")
                    await box.set(output.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    await box.set("error: \(error)")
                }
            }
            var outcome = "hung"
            for _ in 0..<50 {
                if let value = await box.get() {
                    outcome = value
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(outcome == "side-channel-ok")
            await shell.close()
            pump.cancel()
            await connection.disconnect()
        }

        @Test func importedEd25519KeyAuthenticates() async throws {
            let sshd = try TestSSHD(key: .ed25519(Curve25519.Signing.PrivateKey()))
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            let output = try await connection.exec("echo ed-ok")
            #expect(output.contains("ed-ok"))
            await connection.disconnect()
        }

        @Test func execChannelGetsUTF8Locale() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            let output = try await connection.exec("printenv LANG")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "en_US.UTF-8")
            await connection.disconnect()
        }

        @Test func shellChannelGetsUTF8Locale() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            let shell = try await connection.openShell(cols: 80, rows: 24)
            try await shell.write(Data("printenv LANG\n".utf8))
            var collected = Data()
            let deadline = Date().addingTimeInterval(5)
            for await chunk in shell.output {
                collected.append(chunk)
                if String(data: collected, encoding: .utf8)?.contains("en_US.UTF-8") == true { break }
                if Date() > deadline { break }
            }
            #expect(String(data: collected, encoding: .utf8)?.contains("en_US.UTF-8") == true)
            await connection.disconnect()
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["PS_REAL_HOST"] != nil))
        func wrongKeyAgainstRealHostFailsQuickly() async throws {
            let env = ProcessInfo.processInfo.environment
            let host = HostConfig(
                name: "real",
                hostname: env["PS_REAL_HOST"]!,
                port: Int(env["PS_REAL_PORT"] ?? "22")!,
                username: env["PS_REAL_USER"] ?? "nobody",
                keyTag: "test"
            )
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kh-\(UUID().uuidString).json")
            let connection = SSHConnection(
                host: host,
                key: .software(P256.Signing.PrivateKey()),
                knownHosts: KnownHostsStore(fileURL: file)
            )
            let outcome = await withTaskGroup(of: String.self) { group in
                group.addTask {
                    do {
                        try await connection.connect()
                        return "connected"
                    } catch SSHError.authenticationFailed {
                        return "authFailed"
                    } catch {
                        return "error: \(error)"
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(15))
                    return "hung"
                }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
            #expect(outcome == "authFailed")
        }

        @Test func runBoundedReturnsValueAndDisconnects() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            let value = try await connection.runBounded(timeout: 10) { conn in
                let connected = await conn.isConnected
                let out = try await conn.exec("echo bounded")
                return "\(connected):\(out.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            #expect(value == "true:bounded")
            #expect(await !connection.isConnected)
        }

        @Test func runBoundedRethrowsBodyErrorAndDisconnects() async throws {
            struct Boom: Error {}
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            await #expect(throws: Boom.self) {
                try await connection.runBounded(timeout: 10) { _ -> Int in throw Boom() }
            }
            #expect(await !connection.isConnected)
        }

        @Test func runBoundedTimesOutHangingBodyAndDisconnects() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            let clock = ContinuousClock()
            let start = clock.now
            await #expect(throws: DeadlineExceeded.self) {
                try await connection.runBounded(timeout: 0.5) { _ -> Int in
                    await Task.detached { try? await Task.sleep(for: .seconds(5)) }.value
                    return 1
                }
            }
            #expect(clock.now - start < .seconds(4))
            #expect(await !connection.isConnected)
        }

        @Test func runBoundedPropagatesConnectFailure() async throws {
            let sshd = try TestSSHD()
            let host = sshd.hostConfig()
            sshd.stop()
            try await Task.sleep(for: .milliseconds(300))
            let connection = SSHConnection(
                host: host,
                key: sshd.clientKeyMaterial,
                knownHosts: KnownHostsStore(
                    fileURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("kh-\(UUID().uuidString).json"))
            )
            let ran = OutcomeBox()
            let clock = ContinuousClock()
            let start = clock.now
            await #expect(throws: (any Error).self) {
                try await connection.runBounded(timeout: 8) { _ -> Int in
                    await ran.set("ran")
                    return 1
                }
            }
            #expect(await ran.get() == nil)
            #expect(clock.now - start < .seconds(6))
            #expect(await !connection.isConnected)
        }

        @Test func corruptKnownHostsFailsHandshakeAndLeavesFileUntouched() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kh-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let garbage = Data("{ not json".utf8)
            try garbage.write(to: file)
            let connection = makeConnection(sshd, knownHostsFile: file)
            await #expect(throws: (any Error).self) {
                try await connection.connect()
            }
            #expect(await !connection.isConnected)
            #expect(try Data(contentsOf: file) == garbage)
        }

        @Test func openSFTPThrowsWhenSubsystemExitsAndConnectionStaysUsable() async throws {
            let sshd = try TestSSHD(sftpServer: "/usr/bin/false")
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            for _ in 0..<15 {
                await #expect(throws: (any Error).self) {
                    _ = try await connection.openSFTP()
                }
            }
            let output = try await connection.exec("echo still-works")
            #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "still-works")
            await connection.disconnect()
        }

        @Test func execReturnsExitStatusFailure() async throws {
            let sshd = try TestSSHD()
            defer { sshd.stop() }
            let connection = makeConnection(sshd)
            try await connection.connect()
            await #expect(throws: (any Error).self) {
                _ = try await connection.exec("exit 3")
            }
            await connection.disconnect()
        }
    }
#endif
