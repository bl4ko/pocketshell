import Testing

@testable import VoiceKit

private func voice(_ id: String, _ language: String, _ quality: VoiceChoice.Quality) -> VoiceChoice {
    VoiceChoice(id: id, name: id, language: language, quality: quality)
}

@Test func bestEnglishVoicePrefersPremiumThenEnhancedThenDefault() {
    let voices = [
        voice("Samantha", "en-US", .standard), voice("Ava", "en-US", .enhanced), voice("Anna", "de-DE", .premium),
        voice("Serena", "en-GB", .premium), voice("Zoe", "en-US", .premium),
    ]
    #expect(SpeechVoices.ranked(voices).map(\.id) == ["Zoe", "Serena", "Ava", "Samantha"])
    #expect(SpeechVoices.choose(nil, from: voices)?.id == "Zoe")
    #expect(SpeechVoices.choose("Ava", from: voices)?.id == "Ava")
    #expect(SpeechVoices.choose("Anna", from: voices)?.id == "Zoe")
    #expect(SpeechVoices.choose("gone", from: [voice("Samantha", "en-US", .standard)])?.id == "Samantha")
}

@MainActor
@Test func textEarsDeliverPartialThenPhraseOnlyWhileRunningAndUnmuted() async throws {
    let ears = TextEars()
    var events: [EarsEvent] = []
    ears.onEvent = { events.append($0) }
    ears.submit("ignored")
    try await ears.start()
    ears.submit("hello")
    ears.muted = true
    ears.submit("muted")
    #expect(events == [.partial("hello"), .phrase("hello")])
}

@MainActor
@Test func timedMouthReportsStartAndIdleOncePerBurst() async throws {
    let mouth = TimedMouth(secondsPerCharacter: 0.001)
    var events: [MouthEvent] = []
    mouth.onEvent = { events.append($0) }
    mouth.speak("one")
    mouth.speak("two")
    while mouth.isSpeaking { try await Task.sleep(for: .milliseconds(5)) }
    #expect(
        events == [
            .started, .upcoming("one "), .heard("one ", reply: nil), .upcoming("two "), .heard("two ", reply: nil),
            .idle,
        ])
    mouth.speak("three")
    mouth.stop()
    #expect(events.filter { $0 == .started || $0 == .idle } == [.started, .idle, .started, .idle])
    #expect(mouth.spoken == ["one", "two", "three"])
}

@MainActor
@Test func timedMouthSpeaksAStreamedReplySentenceBySentenceWithItsReplyID() async throws {
    let mouth = TimedMouth(secondsPerCharacter: 0.001)
    var events: [MouthEvent] = []
    mouth.onEvent = { events.append($0) }
    mouth.stream("Claude is **bu", reply: 5)
    #expect(mouth.spoken.isEmpty)
    mouth.stream("sy**. Codex is", reply: 5)
    #expect(mouth.spoken == ["Claude is busy."])
    mouth.finish()
    #expect(mouth.spoken == ["Claude is busy.", "Codex is"])
    while mouth.isSpeaking { try await Task.sleep(for: .milliseconds(5)) }
    #expect(events.contains(.heard("Claude is busy. ", reply: 5)))
    #expect(events.contains(.heard("Codex is ", reply: 5)))
    mouth.stream("Dropped at stop", reply: 6)
    mouth.stop()
    mouth.finish()
    #expect(mouth.spoken.count == 2)
}

#if os(iOS)
    @Test func mouthStateIsIdleOnlyWhenEveryUtteranceAndBufferIsDone() {
        let state = MouthState()
        let generation = state.beginUtterance()
        state.addBuffer()
        #expect(!state.finishUtterance(generation))
        #expect(state.bufferPlayed(generation))
        #expect(state.isIdle(generation))
        let next = state.beginUtterance()
        state.reset()
        #expect(!state.isCurrent(next))
        #expect(!state.bufferPlayed(next))
    }

    @Test func mouthStateAnnouncesASentenceWhenItsFirstBufferStartsToPlay() {
        let state = MouthState()
        let fired = LockedFlag()
        let generation = state.beginUtterance()
        state.addBuffer(started: { fired.on = true })
        #expect(fired.on)
        fired.on = false
        state.addBuffer()
        _ = state.beginUtterance()
        state.addBuffer(started: { fired.on = true })
        #expect(!fired.on)
        _ = state.bufferPlayed(generation)
        #expect(!fired.on)
        _ = state.bufferPlayed(generation)
        #expect(fired.on)
    }
#endif
