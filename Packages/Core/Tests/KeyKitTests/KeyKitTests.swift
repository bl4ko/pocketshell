import Crypto
import Foundation
import Testing

@testable import KeyKit

private let fixedKey = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))

@Test func openSSHPublicKeyHasCorrectPrefixAndComment() {
    let line = OpenSSHPublicKey.line(for: fixedKey.publicKey, comment: "pocketshell@iphone")
    #expect(line.hasPrefix("ecdsa-sha2-nistp256 "))
    #expect(line.hasSuffix(" pocketshell@iphone"))
}

@Test func openSSHPublicKeyWireFormatIsValid() throws {
    let line = OpenSSHPublicKey.line(for: fixedKey.publicKey, comment: "c")
    let base64 = line.split(separator: " ")[1]
    var blob = try #require(Data(base64Encoded: String(base64)))

    func readString() -> Data {
        let len = blob.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
        blob.removeFirst(4)
        let value = blob.prefix(Int(len))
        blob.removeFirst(Int(len))
        return Data(value)
    }

    #expect(String(data: readString(), encoding: .utf8) == "ecdsa-sha2-nistp256")
    #expect(String(data: readString(), encoding: .utf8) == "nistp256")
    let point = readString()
    #expect(point == fixedKey.publicKey.x963Representation)
    #expect(point.first == 0x04)
    #expect(point.count == 65)
    #expect(blob.isEmpty)
}

#if os(macOS)
    @Test func sshKeygenAcceptsGeneratedPublicKey() throws {
        let line = OpenSSHPublicKey.line(for: fixedKey.publicKey, comment: "pocketshell@test")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketshell-\(UUID().uuidString).pub")
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-l", "-f", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        #expect(process.terminationStatus == 0)
        #expect(output.contains("ECDSA"))
        #expect(output.contains("pocketshell@test"))
    }
#endif
