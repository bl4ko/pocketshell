#if os(macOS)
    import AVFoundation
    import Foundation
    import Speech
    import Testing
    import VoiceKit

    @Test func streamedMicrophoneBuffersBecomePhrasesAndCommands() async throws {
        guard #available(macOS 26, *) else { return }
        guard await SpeechTranscriber.installedLocales.contains(where: { $0.language.languageCode == .english }) else {
            return
        }
        let url = try #require(
            Bundle.module.url(forResource: "dictation", withExtension: "m4a", subdirectory: "Fixtures"))
        let file = try AVAudioFile(forReading: url)
        let stream = try await SpeechStream.make(contextualStrings: VoiceCommand.vocabulary)
        let collected = Task {
            var phrases: [String] = []
            var partials = 0
            for try await event in stream.events {
                switch event {
                case .phrase(let text): phrases.append(text)
                case .partial: partials += 1
                }
            }
            return (phrases, partials)
        }
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
            try file.read(into: buffer)
            stream.append(buffer)
        }
        await stream.finish()
        let (phrases, partials) = try await collected.value
        #expect(partials > 0)
        var draft = ""
        let actions = phrases.compactMap { VoiceCommand.apply($0, to: &draft) }
        guard case .submit(let message) = try #require(actions.last) else {
            Issue.record("no submit in \(phrases)")
            return
        }
        #expect(message.lowercased().contains("login bug"))
        #expect(message.lowercased().contains("run the tests"))
    }
#endif
