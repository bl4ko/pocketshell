import Testing
import VoiceKit

@Test func micModesHaveDistinctLabelsAndGlyphs() {
    #expect(MicMode.allCases.map(\.label) == ["Standard", "Wide Spectrum", "Voice Isolation"])
    #expect(Set(MicMode.allCases.map(\.symbol)).count == MicMode.allCases.count)
}

@Test func voiceIsolationHintShowsOnlyWhileVoiceModeIsOnWithoutIsolationAndUntilDismissed() {
    #expect(MicMode.showsHint(active: .standard, voiceOn: true, dismissed: false))
    #expect(MicMode.showsHint(active: .wideSpectrum, voiceOn: true, dismissed: false))
    #expect(!MicMode.showsHint(active: .voiceIsolation, voiceOn: true, dismissed: false))
    #expect(!MicMode.showsHint(active: .standard, voiceOn: false, dismissed: false))
    #expect(!MicMode.showsHint(active: .standard, voiceOn: true, dismissed: true))
}
