import Testing
import VoiceKit

@Test func endingAPhraseWithSendSubmitsTheTextBeforeIt() {
    #expect(VoiceCommand.parse("Fix the login bug send") == .send("Fix the login bug"))
    #expect(VoiceCommand.parse("Fix the login bug, send.") == .send("Fix the login bug"))
    #expect(VoiceCommand.parse("Send") == .send(""))
    #expect(VoiceCommand.parse("Send the report to Bob") == .text("Send the report to Bob"))
    #expect(VoiceCommand.parse("please resend") == .text("please resend"))
}

@Test func keysAreReadOnlyWhenSpokenAlone() {
    #expect(VoiceCommand.parse("Escape") == .escape)
    #expect(VoiceCommand.parse("enter.") == .enter)
    #expect(VoiceCommand.parse("Two") == .digit(2))
    #expect(VoiceCommand.parse("2") == .digit(2))
    #expect(VoiceCommand.parse("too") == .digit(2))
    #expect(VoiceCommand.parse("press escape to stop") == .text("press escape to stop"))
    #expect(VoiceCommand.parse("pick option two") == .text("pick option two"))
}

@Test func scrollAndCloseKeyboardAreReadOnlyWhenSpokenAlone() {
    #expect(VoiceCommand.parse("Scroll up.") == .scroll(up: true))
    #expect(VoiceCommand.parse("scroll down") == .scroll(up: false))
    #expect(VoiceCommand.parse("Scroll down.") == .scroll(up: false))
    #expect(VoiceCommand.parse("Close keyboard.") == .closeKeyboard)
    #expect(VoiceCommand.parse("scroll up to the error") == .text("scroll up to the error"))
    #expect(VoiceCommand.parse("then scroll down") == .text("then scroll down"))
    #expect(VoiceCommand.parse("Close keyboard shortcuts") == .text("Close keyboard shortcuts"))
    #expect(VoiceCommand.parse("please close keyboard") == .text("please close keyboard"))
    #expect(VoiceCommand.parse("scroll") == .text("scroll"))
}

@Test func endingAPhraseWithClearDropsTheDraft() {
    #expect(VoiceCommand.parse("no wait, clear.") == .clear)
}

@Test func goToJumpsToTheNamedTab() {
    #expect(VoiceCommand.parse("Go to home assistant.") == .jump("home assistant"))
    #expect(VoiceCommand.parse("go to") == .text("go to"))
}

@Test func nextAgentIsReadOnlyWhenSpokenAlone() {
    #expect(VoiceCommand.parse("Next agent.") == .nextAgent)
    #expect(VoiceCommand.parse("next agent") == .nextAgent)
    #expect(VoiceCommand.parse("ask the next agent to review it") == .text("ask the next agent to review it"))
    #expect(VoiceCommand.parse("next agent please") == .text("next agent please"))
}

@Test func silenceIsNoCommand() {
    #expect(VoiceCommand.parse("  ") == nil)
}

@Test func phrasesJoinTheDraftWithOneSpace() {
    #expect(VoiceCommand.join("", "Fix it") == "Fix it")
    #expect(VoiceCommand.join("Fix it", "and test") == "Fix it and test")
    #expect(VoiceCommand.join("Fix it", "") == "Fix it")
}

@Test func applyingPhrasesBuildsTheDraftAndSubmitsIt() {
    var draft = ""
    #expect(VoiceCommand.apply("Fix the login bug", to: &draft) == nil)
    #expect(draft == "Fix the login bug")
    #expect(VoiceCommand.apply("and run the tests send", to: &draft) == .submit("Fix the login bug and run the tests"))
    #expect(draft == "")
    #expect(VoiceCommand.apply("send", to: &draft) == nil)
}

@Test func applyingKeysAndJumpsKeepsTheDraft() {
    var draft = "half a thought"
    #expect(VoiceCommand.apply("Escape", to: &draft) == .keys("\u{1b}"))
    #expect(VoiceCommand.apply("enter", to: &draft) == .keys("\r"))
    #expect(VoiceCommand.apply("three", to: &draft) == .keys("3"))
    #expect(VoiceCommand.apply("go to security", to: &draft) == .jump("security"))
    #expect(VoiceCommand.apply("Next agent.", to: &draft) == .nextAgent)
    #expect(VoiceCommand.apply("Scroll up.", to: &draft) == .scroll(up: true))
    #expect(VoiceCommand.apply("Scroll down.", to: &draft) == .scroll(up: false))
    #expect(VoiceCommand.apply("Close keyboard.", to: &draft) == .closeKeyboard)
    #expect(draft == "half a thought")
    #expect(VoiceCommand.apply("then scroll down", to: &draft) == nil)
    #expect(draft == "half a thought then scroll down")
    #expect(VoiceCommand.apply("clear", to: &draft) == nil)
    #expect(draft == "")
}

@Test func brokenOnDeviceRecognitionFallsBackToServerBeforeReporting() {
    var fallback = SpeechFallback(onDeviceAvailable: true)
    let broken = SpeechFailure(domain: "kLSRErrorDomain", code: 300, message: "Failed to initialize recognizer")

    #expect(fallback.onDevice)
    #expect(fallback.phraseEnded(heardSpeech: false, failure: broken) == nil)
    #expect(!fallback.onDevice)
    #expect(fallback.phraseEnded(heardSpeech: false, failure: broken) == "Failed to initialize recognizer")
}

@Test func silenceAndSpeechAreNotReported() {
    var fallback = SpeechFallback(onDeviceAvailable: true)
    let silence = SpeechFailure(domain: "kAFAssistantErrorDomain", code: 1110, message: "No speech detected")
    let broken = SpeechFailure(domain: "kLSRErrorDomain", code: 300, message: "Failed to initialize recognizer")

    #expect(fallback.phraseEnded(heardSpeech: false, failure: silence) == nil)
    #expect(fallback.phraseEnded(heardSpeech: true, failure: broken) == nil)
    #expect(fallback.phraseEnded(heardSpeech: false, failure: nil) == nil)
    #expect(fallback.onDevice)
}
