#if os(macOS)
    import Crypto
    import Foundation
    import Testing
    @testable import KeyKit

    private func keygen(type: String, passphrase: String = "") throws -> (privateKey: String, publicLine: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketshell-keygen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var args = ["-t", type, "-N", passphrase, "-C", "import@test", "-f", path.path, "-q"]
        if type == "ecdsa" { args += ["-b", "256"] }
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        let privateKey = try String(contentsOf: path, encoding: .utf8)
        let publicLine = try String(contentsOf: path.appendingPathExtension("pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (privateKey, publicLine)
    }

    private func keyAndBlob(_ line: String) -> String {
        line.split(separator: " ").prefix(2).joined(separator: " ")
    }

    @Test func parsesUnencryptedEd25519Key() throws {
        let fixture = try keygen(type: "ed25519")
        let material = try OpenSSHPrivateKey.parse(fixture.privateKey)
        let line = material.openSSHPublicKeyLine(comment: "import@test")
        #expect(keyAndBlob(line) == keyAndBlob(fixture.publicLine))
        guard case .ed25519 = material else {
            Issue.record("expected ed25519 material")
            return
        }
    }

    @Test func parsesUnencryptedP256Key() throws {
        let fixture = try keygen(type: "ecdsa")
        let material = try OpenSSHPrivateKey.parse(fixture.privateKey)
        let line = material.openSSHPublicKeyLine(comment: "import@test")
        #expect(keyAndBlob(line) == keyAndBlob(fixture.publicLine))
        guard case .software = material else {
            Issue.record("expected software P256 material")
            return
        }
    }

    @Test func rejectsEncryptedKey() throws {
        let fixture = try keygen(type: "ed25519", passphrase: "secret123")
        #expect(throws: OpenSSHPrivateKey.ParseError.encrypted) {
            _ = try OpenSSHPrivateKey.parse(fixture.privateKey)
        }
    }

    @Test func decryptsEd25519KeyWithPassphrase() throws {
        let fixture = try keygen(type: "ed25519", passphrase: "secret123")
        let material = try OpenSSHPrivateKey.parse(fixture.privateKey, passphrase: "secret123")
        let line = material.openSSHPublicKeyLine(comment: "import@test")
        #expect(keyAndBlob(line) == keyAndBlob(fixture.publicLine))
    }

    @Test func decryptsP256KeyWithPassphrase() throws {
        let fixture = try keygen(type: "ecdsa", passphrase: "hunter2hunter2")
        let material = try OpenSSHPrivateKey.parse(fixture.privateKey, passphrase: "hunter2hunter2")
        let line = material.openSSHPublicKeyLine(comment: "import@test")
        #expect(keyAndBlob(line) == keyAndBlob(fixture.publicLine))
    }

    @Test func wrongPassphraseFails() throws {
        let fixture = try keygen(type: "ed25519", passphrase: "secret123")
        #expect(throws: OpenSSHPrivateKey.ParseError.wrongPassphrase) {
            _ = try OpenSSHPrivateKey.parse(fixture.privateKey, passphrase: "nope")
        }
    }

    @Test func rejectsRSAKeyAsUnsupported() throws {
        let fixture = try keygen(type: "rsa")
        #expect(throws: OpenSSHPrivateKey.ParseError.unsupportedKeyType("ssh-rsa")) {
            _ = try OpenSSHPrivateKey.parse(fixture.privateKey)
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: OpenSSHPrivateKey.ParseError.notOpenSSHKey) {
            _ = try OpenSSHPrivateKey.parse("-----BEGIN EC PRIVATE KEY-----\nabc\n-----END EC PRIVATE KEY-----")
        }
        #expect(throws: OpenSSHPrivateKey.ParseError.notOpenSSHKey) {
            _ = try OpenSSHPrivateKey.parse("hello world")
        }
    }
#endif
