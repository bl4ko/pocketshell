import Foundation
import Models
import Testing

@testable import BrainKit

private func state(
    _ mode: VoiceBrain.Mode = .conversing, _ phase: TurnTaking.Phase = .listening, muted: Bool = false,
    interrupted: Bool = false, caption: VoiceBrain.Caption? = nil
) -> VoiceActivityState? {
    VoiceActivityFeed.state(mode: mode, phase: phase, muted: muted, interrupted: interrupted, caption: caption)
}

@Test func activityStatusFollowsModePhaseMuteAndInterruption() {
    #expect(state(.off) == nil)
    #expect(state(.starting)?.status == .starting)
    #expect(state(.conversing, .listening)?.status == .listening)
    #expect(state(.conversing, .userSpeaking)?.status == .hearing)
    #expect(state(.conversing, .thinking)?.status == .thinking)
    #expect(state(.conversing, .speaking)?.status == .speaking)
    #expect(state(.conversing, .speaking, muted: true)?.status == .muted)
    #expect(state(.conversing, .speaking, muted: true)?.muted == true)
    #expect(state(.conversing, .listening, muted: true, interrupted: true)?.status == .paused)
    #expect(state(.dictation("No brain"), .listening)?.status == .dictating)
    #expect(state(.dictation("No brain"), .listening, muted: true)?.status == .muted)
}

@Test func activityCaptionIsTheFlattenedTailOfTheLiveCaption() throws {
    #expect(state()?.caption == "")
    #expect(state(caption: .init(.user, "run the\n tests"))?.caption == "run the tests")
    let long = (1...60).map { "word\($0)" }.joined(separator: " ")
    let caption = try #require(state(caption: .init(.brain, long))?.caption)
    #expect(caption.hasPrefix("…word"))
    #expect(caption.hasSuffix("word60"))
    #expect(caption.count <= VoiceActivityState.captionLimit + 1)
}

@Test func activityStartsUpdatesStatusAtOnceAndEnds() {
    var feed = VoiceActivityFeed()
    #expect(feed.step(nil, at: 0) == .none)
    let starting = VoiceActivityState(status: .starting)
    #expect(feed.step(starting, at: 0) == .start(starting))
    #expect(feed.step(starting, at: 5) == .none)
    let listening = VoiceActivityState(status: .listening)
    #expect(feed.step(listening, at: 5.01) == .update(listening))
    let muted = VoiceActivityState(status: .muted, muted: true)
    #expect(feed.step(muted, at: 5.02) == .update(muted))
    #expect(feed.step(nil, at: 5.03) == .end)
    #expect(feed.step(nil, at: 6) == .none)
    #expect(feed.step(listening, at: 7) == .start(listening))
}

@Test func activityCaptionUpdatesAtMostOncePerSecondAndTheLastOneLands() {
    var feed = VoiceActivityFeed()
    _ = feed.step(VoiceActivityState(status: .speaking), at: 10)
    #expect(feed.step(VoiceActivityState(status: .speaking, caption: "All"), at: 10.2) == .none)
    #expect(feed.step(VoiceActivityState(status: .speaking, caption: "All quiet"), at: 10.6) == .none)
    let third = VoiceActivityState(status: .speaking, caption: "All quiet on")
    #expect(feed.step(third, at: 11) == .update(third))
    let last = VoiceActivityState(status: .speaking, caption: "All quiet on devbox.")
    #expect(feed.step(last, at: 11.5) == .none)
    #expect(feed.step(last, at: 12) == .update(last))
    #expect(feed.step(last, at: 13) == .none)
}

@Test func activityStatusChangeCarriesTheCaptionAndRestartsTheCaptionClock() {
    var feed = VoiceActivityFeed()
    _ = feed.step(VoiceActivityState(status: .thinking), at: 10)
    let speaking = VoiceActivityState(status: .speaking, caption: "All")
    #expect(feed.step(speaking, at: 10.1) == .update(speaking))
    #expect(feed.step(VoiceActivityState(status: .speaking, caption: "All quiet"), at: 10.9) == .none)
}
