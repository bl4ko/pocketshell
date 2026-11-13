import Testing

@testable import BrainKit

@Test func fullTurnGoesFromListeningThroughThinkingAndSpeakingBack() {
    var machine = TurnTaking(now: 0)
    #expect(machine.phase == .listening)
    #expect(machine.handle(.userPartial("tell claude"), at: 1).isEmpty)
    #expect(machine.phase == .userSpeaking)
    #expect(machine.handle(.userPhrase("tell claude to run tests"), at: 2) == [.respond("tell claude to run tests")])
    #expect(machine.phase == .thinking)
    #expect(machine.handle(.mouthStarted, at: 2.4).isEmpty)
    #expect(machine.phase == .speaking)
    #expect(machine.handle(.brainDone, at: 2.5).isEmpty)
    #expect(machine.phase == .speaking)
    #expect(machine.handle(.mouthIdle, at: 3).isEmpty)
    #expect(machine.phase == .listening)
}

@Test func userSpeechWhileSpeakingBargesIn() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPhrase("what is codex doing"), at: 1)
    _ = machine.handle(.mouthStarted, at: 1.5)
    #expect(machine.handle(.userPartial("wait"), at: 2) == [.stopMouth, .cancelBrain])
    #expect(machine.phase == .userSpeaking)
    #expect(machine.handle(.mouthIdle, at: 2.01).isEmpty)
    #expect(machine.phase == .userSpeaking)
    #expect(
        machine.handle(.userPhrase("wait, tell me about claude"), at: 3) == [.respond("wait, tell me about claude")])
    #expect(machine.phase == .thinking)
}

@Test func emptyPartialReturnsToListening() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPartial("uh"), at: 1)
    _ = machine.handle(.userPartial(""), at: 1.5)
    #expect(machine.phase == .listening)
}

@Test func fillerPlaysOnceWhenNoAudioStartsWithinTwoSeconds() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPhrase("check the agents"), at: 10)
    #expect(machine.handle(.tick, at: 11.9).isEmpty)
    #expect(machine.handle(.tick, at: 12.0) == [.playFiller])
    #expect(machine.handle(.tick, at: 12.5).isEmpty)
    _ = machine.handle(.mouthStarted, at: 12.1)
    _ = machine.handle(.mouthIdle, at: 12.6)
    #expect(machine.phase == .thinking)
    #expect(machine.handle(.tick, at: 15).isEmpty)
}

@Test func noFillerWhenTheBrainAnswersQuickly() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPhrase("hi"), at: 10)
    _ = machine.handle(.mouthStarted, at: 11.6)
    #expect(machine.handle(.tick, at: 12.2).isEmpty)
}

@Test func proactiveEventsWaitForSilence() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPartial("so"), at: 1)
    #expect(machine.handle(.eventQueued, at: 1.2).isEmpty)
    _ = machine.handle(.userPartial(""), at: 1.4)
    #expect(machine.handle(.tick, at: 2.5).isEmpty)
    #expect(machine.handle(.tick, at: 3.0) == [.announce])
    #expect(machine.handle(.tick, at: 5).isEmpty)
}

@Test func proactiveEventsWaitUntilTheMouthIsDone() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPhrase("hi"), at: 1)
    _ = machine.handle(.mouthStarted, at: 1.2)
    _ = machine.handle(.brainDone, at: 1.3)
    #expect(machine.handle(.eventQueued, at: 2).isEmpty)
    #expect(machine.handle(.tick, at: 9).isEmpty)
    _ = machine.handle(.mouthIdle, at: 10)
    #expect(machine.handle(.tick, at: 11).isEmpty)
    #expect(machine.handle(.tick, at: 11.5) == [.announce])
    _ = machine.handle(.mouthStarted, at: 11.6)
    #expect(machine.phase == .speaking)
    _ = machine.handle(.mouthIdle, at: 12)
    #expect(machine.phase == .listening)
}

@Test func mutedEarsIgnoreSpeech() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.muted(true), at: 0.5)
    #expect(machine.handle(.userPhrase("hello"), at: 1).isEmpty)
    #expect(machine.phase == .listening)
    _ = machine.handle(.muted(false), at: 2)
    #expect(machine.handle(.userPhrase("hello"), at: 3) == [.respond("hello")])
}

@Test func aNewPhraseWhileThinkingCancelsTheOldTurn() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPhrase("one"), at: 1)
    #expect(machine.handle(.userPhrase("two"), at: 1.2) == [.stopMouth, .cancelBrain, .respond("two")])
}

@Test func audioInterruptionCancelsTheReplyAndHoldsAnnouncementsUntilItEnds() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPhrase("what is codex doing"), at: 1)
    _ = machine.handle(.mouthStarted, at: 1.5)
    #expect(machine.handle(.interrupted(true), at: 2) == [.stopMouth, .cancelBrain])
    #expect(machine.phase == .listening)
    #expect(machine.handle(.eventQueued, at: 3).isEmpty)
    #expect(machine.handle(.tick, at: 60).isEmpty)
    #expect(machine.handle(.userPhrase("late words"), at: 61).isEmpty)
    #expect(machine.handle(.userPartial("late"), at: 61).isEmpty)
    #expect(machine.phase == .listening)
    #expect(machine.handle(.interrupted(false), at: 100).isEmpty)
    #expect(machine.handle(.tick, at: 101).isEmpty)
    #expect(machine.handle(.tick, at: 101.5) == [.announce])
}

@Test func audioInterruptionWhileListeningCancelsNothing() {
    var machine = TurnTaking(now: 0)
    #expect(machine.handle(.interrupted(true), at: 1).isEmpty)
    #expect(machine.handle(.interrupted(false), at: 2).isEmpty)
    #expect(machine.handle(.userPhrase("hello"), at: 3) == [.respond("hello")])
}

@Test func aWaitingPromptStopsTheReplyAndIsAskedAtOnce() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPhrase("tell me everything"), at: 1)
    _ = machine.handle(.mouthStarted, at: 1.5)
    #expect(machine.handle(.promptQueued, at: 2) == [.stopMouth, .cancelBrain, .announcePrompt])
    #expect(machine.phase == .listening)
    _ = machine.handle(.mouthStarted, at: 2.01)
    #expect(machine.promptSpeaking)
    #expect(machine.handle(.promptQueued, at: 2.5).isEmpty)
    #expect(machine.handle(.tick, at: 3).isEmpty)
    _ = machine.handle(.mouthIdle, at: 4)
    #expect(machine.phase == .listening)
    #expect(machine.handle(.tick, at: 4.6).isEmpty)
    #expect(machine.handle(.tick, at: 5.5) == [.announcePrompt])
}

@Test func aWaitingPromptWhileThinkingCancelsTheTurn() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPhrase("what is codex doing"), at: 1)
    #expect(machine.handle(.promptQueued, at: 1.2) == [.stopMouth, .cancelBrain, .announcePrompt])
    _ = machine.handle(.mouthStarted, at: 1.3)
    #expect(machine.handle(.tick, at: 3.5).isEmpty)
}

@Test func aWaitingPromptNeverInterruptsTheUserAndWaitsForTheirTurnToBeAnswered() {
    var machine = TurnTaking(now: 0)
    _ = machine.handle(.userPartial("so what"), at: 1)
    #expect(machine.handle(.promptQueued, at: 1.2).isEmpty)
    #expect(machine.handle(.tick, at: 3).isEmpty)
    #expect(machine.handle(.userPhrase("so what about codex"), at: 4) == [.respond("so what about codex")])
    _ = machine.handle(.mouthStarted, at: 4.5)
    #expect(machine.handle(.tick, at: 5).isEmpty)
    _ = machine.handle(.brainDone, at: 5.1)
    _ = machine.handle(.mouthIdle, at: 6)
    #expect(machine.handle(.tick, at: 6.3).isEmpty)
    #expect(machine.handle(.tick, at: 6.5) == [.announcePrompt])
}

@Test func anOpenPromptHoldsOtherAnnouncementsUntilTheUserAnswersOrItCloses() {
    var machine = TurnTaking(now: 0)
    #expect(machine.handle(.promptQueued, at: 1) == [.announcePrompt])
    _ = machine.handle(.mouthStarted, at: 1.1)
    _ = machine.handle(.mouthIdle, at: 3)
    #expect(machine.handle(.eventQueued, at: 3.1).isEmpty)
    #expect(machine.handle(.tick, at: 30).isEmpty)
    _ = machine.handle(.promptClosed, at: 31)
    #expect(machine.handle(.tick, at: 31.1) == [.announce])
}
