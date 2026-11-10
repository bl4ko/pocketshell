import Foundation
import Testing

@testable import pocketshell

@MainActor
struct VoiceBrainSessionTests {
    @Test func brainExecGivesUpOnAConnectionThatNeverAnswers() async {
        let hung = VoiceBrainSession.bounded(
            { _ in
                try? await Task.sleep(for: .seconds(30))
                return "late"
            }, seconds: 0.2)
        let started = ContinuousClock.now
        #expect(await hung("tmux list-panes") == nil)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func brainExecPassesAnswersAndFailuresThrough() async {
        let exec = VoiceBrainSession.bounded({ $0 == "ok" ? "output" : nil }, seconds: 5)
        #expect(await exec("ok") == "output")
        #expect(await exec("fails") == nil)
    }
}
