import Foundation
import KeyKit
import Models
import SSHKit
import Testing

@testable import pocketshell

@MainActor
struct ComposerDraftTests {
    private let host = HostConfig(name: "draft", hostname: "draft", username: "u", keyTag: "k")

    private func controller() -> ConnectionController {
        ConnectionController(
            host: host, key: .software(.init()),
            knownHosts: KnownHostsStore(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")))
    }

    private func clear() {
        let key = "pocketshell.composerDraft.\(host.id.uuidString)"
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key + ".replacesBox")
    }

    @Test func closingTheComposerDiscardsADictatedDraft() {
        defer { clear() }
        let first = controller()
        first.composerVisible = true
        first.composerDraft = "I'm still getting asked to confirm pasting.  Speech text is"
        first.composerVisible = false
        #expect(first.composerDraft.isEmpty)

        let relaunched = controller()
        #expect(relaunched.composerDraft.isEmpty)
        #expect(!relaunched.composerVisible)
    }

    @Test func anOpenDraftSurvivesTheScreenBeingRebuilt() {
        defer { clear() }
        let first = controller()
        first.composerVisible = true
        first.composerDraft = "half written"

        let rebuilt = controller()
        #expect(rebuilt.composerDraft == "half written")
        #expect(rebuilt.composerVisible)
    }
}
