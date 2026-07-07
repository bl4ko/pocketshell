#if os(macOS)
import Crypto
import Foundation
import KeyKit
import Models
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

    init(key: DeviceKeyMaterial = .software(P256.Signing.PrivateKey())) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketshell-sshd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        port = Int.random(in: 20000...29999)
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
        """
        let configURL = dir.appendingPathComponent("sshd_config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-f", configURL.path]
        try process.run()
        Thread.sleep(forTimeInterval: 0.5)
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
    let file = knownHostsFile ?? FileManager.default.temporaryDirectory
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
