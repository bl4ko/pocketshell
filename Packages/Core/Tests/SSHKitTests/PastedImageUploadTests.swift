import Foundation
import SSHKit
import Testing

@MainActor
private final class UploadProbe {
    var current = true
    var staleAfterCommand: Int?
    var failAtCommand: Int?
    var commands: [String] = []
    var pasted: [String] = []
    var failures: [String] = []

    func upload(_ data: Data = Data([0xFF, 0xD8, 0xFF, 0xE0])) async {
        await PastedImageUpload.run(
            data,
            exec: { command in
                self.commands.append(command)
                if self.commands.count == self.staleAfterCommand { self.current = false }
                if self.commands.count == self.failAtCommand { throw SSHError.connectionClosed }
            },
            isCurrent: { self.current },
            paste: { self.pasted.append($0) },
            fail: { self.failures.append("\($0)") }
        )
    }
}

@MainActor
@Test func currentShellReceivesUploadedImagePath() async throws {
    let probe = UploadProbe()
    await probe.upload()
    let path = try #require(probe.pasted.first)
    #expect(probe.pasted.count == 1)
    #expect(path.hasPrefix("/tmp/psh-") && path.hasSuffix(".jpg"))
    #expect(probe.commands.count == 2)
    #expect(probe.commands.first?.contains(Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()) == true)
    #expect(probe.commands.last == "base64 -d < '\(path).b64' > '\(path)' && rm '\(path).b64'")
    #expect(probe.failures.isEmpty)
}

@MainActor
@Test func currentShellReportsUploadFailure() async {
    let probe = UploadProbe()
    probe.failAtCommand = 1
    await probe.upload()
    #expect(probe.commands.count == 1)
    #expect(probe.failures.count == 1)
    #expect(probe.pasted.isEmpty)
}

@MainActor
@Test func uploadStartingAfterShellReplacementDoesNothing() async {
    let probe = UploadProbe()
    probe.current = false
    await probe.upload()
    #expect(probe.commands.isEmpty)
    #expect(probe.pasted.isEmpty)
    #expect(probe.failures.isEmpty)
}

@MainActor
@Test(arguments: [1, 2])
func shellReplacedDuringUploadDropsPath(staleAfterCommand: Int) async {
    let probe = UploadProbe()
    probe.staleAfterCommand = staleAfterCommand
    await probe.upload()
    #expect(probe.pasted.isEmpty)
    #expect(probe.failures.isEmpty)
}

@MainActor
@Test(arguments: [1, 2])
func shellReplacedBeforeFailureDropsError(failingCommand: Int) async {
    let probe = UploadProbe()
    probe.staleAfterCommand = failingCommand
    probe.failAtCommand = failingCommand
    await probe.upload()
    #expect(probe.failures.isEmpty)
    #expect(probe.pasted.isEmpty)
}
