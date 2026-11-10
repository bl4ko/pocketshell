@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import VoiceKit

@Test func sonioxTranscriptTurnsTokensIntoPartialsPhrasesAndErrors() throws {
    var transcript = SonioxTranscript()
    let events = try fixtureLines("soniox-stt", "jsonl").flatMap { transcript.handle(.text($0)) }
    #expect(
        events == [
            .partial("What"),
            .partial("What are my"),
            .phrase("What are my agents doing?", startMs: 420, endMs: 1520),
            .partial("Stop"),
            .phrase("Stop", startMs: 3400, endMs: 3640),
            .failed(
                SonioxError(
                    .server, code: 503, type: "service_unavailable",
                    message: "Cannot continue request (code N). Please restart the request.")),
        ])
}

@Test func sonioxTranscriptParsesACapturedRealtimeSession() throws {
    var transcript = SonioxTranscript()
    let events = try fixtureLines("soniox-stt-capture", "jsonl").flatMap { transcript.handle(.text($0)) }
    #expect(events.last == .phrase("What are my agents doing right now?", startMs: 60, endMs: 1680))
    #expect(events.dropLast().allSatisfy { if case .partial = $0 { true } else { false } })
    #expect(events.contains(.partial("What are my agents doing")))
}

@Test func sonioxTranscriptReportsAnEmptyEndpointAsAClearedCaptionAndAuthErrors() {
    var transcript = SonioxTranscript()
    #expect(transcript.handle(.text(#"{"tokens":[{"text":"<end>","is_final":true}]}"#)) == [.partial("")])
    #expect(transcript.handle(.text(#"{"tokens":[],"finished":true}"#)) == [.finished])
    let denied = transcript.handle(
        .text(#"{"error_code":401,"error_type":"unauthenticated","error_message":"Invalid API key."}"#))
    #expect(denied.count == 1)
    guard case .failed(let error) = denied.first else { return }
    #expect(error.kind == .auth)
}

@Test func sonioxStartRequestAsksForEnglishPCMWithEndpointDetectionAndAgentText() {
    let config = json(.text(SonioxSTT.start(terms: ["Claude", "Herdr"])))
    #expect(config["model"] as? String == "stt-rt-v6")
    #expect(config["audio_format"] as? String == "pcm_s16le")
    #expect(config["sample_rate"] as? Int == 16000)
    #expect(config["num_channels"] as? Int == 1)
    #expect(config["language_hints"] as? [String] == ["en"])
    #expect(config["enable_endpoint_detection"] as? Bool == true)
    #expect(config["enable_agent_text_input"] as? Bool == true)
    #expect((config["context"] as? [String: Any])?["terms"] as? [String] == ["Claude", "Herdr"])
    #expect(config["api_key"] == nil)
    let text = json(.text(SonioxSTT.agentText("two near", end: false)))
    #expect(text["type"] as? String == "agent_text")
    #expect(text["text"] as? String == "two near")
    #expect(text["end_of_segment"] as? Bool == false)
    #expect(json(.text(SonioxSTT.agentText("", end: true)))["end_of_segment"] as? Bool == true)
}

@Test func turnEndKnobSetsTheSonioxEndpointParameters() {
    func endpoint(_ turnEnd: TurnEnd) -> [Double] {
        let config = json(.text(SonioxSTT.start(terms: [], turnEnd: turnEnd)))
        return ["endpoint_latency_adjustment_level", "endpoint_sensitivity", "max_endpoint_delay_ms"].map {
            config[$0] as? Double ?? -1
        }
    }
    #expect(endpoint(.relaxed) == [0, 0, 2000])
    #expect(endpoint(.balanced) == [2, 0.3, 500])
    #expect(endpoint(.fast) == [3, 0.8, 500])
    #expect(json(.text(SonioxSTT.start(terms: [])))["max_endpoint_delay_ms"] as? Int == 500)
    #expect(TurnEnd.allCases.map(\.label) == ["Relaxed", "Balanced", "Fast"])
    #expect(TurnEnd.allCases.map(\.quiet) == [nil, nil, 0.5])
}

@Test func sonioxTTSRequestsAskForPCMWithTimestampsAndStreamText() {
    let start = json(.text(SonioxTTS.start(stream: "s1", voice: "Hazel")))
    #expect(start["stream_id"] as? String == "s1")
    #expect(start["model"] as? String == "tts-rt-v2")
    #expect(start["language"] as? String == "en")
    #expect(start["voice"] as? String == "Hazel")
    #expect(start["audio_format"] as? String == "pcm_s16le")
    #expect(start["sample_rate"] as? Int == 24000)
    #expect(start["return_timestamps"] as? Bool == true)
    #expect(start["api_key"] == nil)
    let text = json(.text(SonioxTTS.text(stream: "s1", "Hello ", end: false)))
    #expect(text["text"] as? String == "Hello ")
    #expect(text["text_end"] as? Bool == false)
    #expect(json(.text(SonioxTTS.text(stream: "s1", "", end: true)))["text_end"] as? Bool == true)
    let cancel = json(.text(SonioxTTS.cancel(stream: "s1")))
    #expect(cancel["cancel"] as? Bool == true)
    #expect(cancel["stream_id"] as? String == "s1")
}

@Test func sonioxTTSRepliesDecodeAudioTimestampsEndTerminationAndErrors() {
    let audio = pcm(samples: 4)
    #expect(
        SonioxTTS.parse(.text(audioReply("s1", audio))) == .audio(stream: "s1", pcm: audio, end: false, marks: []))
    #expect(
        SonioxTTS.parse(.text(audioReply("s1", audio, end: true)))
            == .audio(stream: "s1", pcm: audio, end: true, marks: []))
    let timed = SonioxTTS.parse(
        .text(
            #"{"stream_id":"s1","audio":"\#(audio.base64EncodedString())","timestamps":{"characters":["H","i"],"#
                + #""character_start_times_seconds":[0,0.1],"character_end_times_seconds":[0.1,0.25]}}"#))
    #expect(timed == .audio(stream: "s1", pcm: audio, end: false, marks: [.init("H", 0), .init("i", 0.1)]))
    #expect(SonioxTTS.parse(.text(#"{"terminated":true,"stream_id":"s1"}"#)) == .terminated("s1"))
    let failed = SonioxTTS.parse(
        .text(#"{"stream_id":"s2","error_code":408,"error_type":"request_timeout","error_message":"Timeout"}"#))
    #expect(
        failed == .failed(stream: "s2", SonioxError(.server, code: 408, type: "request_timeout", message: "Timeout")))
    #expect(SonioxTTS.parse(.text("not json")) == .ignored)
}

@Test func playheadFollowsBufferCompletionsAndTheClockInsideABuffer() {
    var playhead = Playhead()
    #expect(playhead.position(at: 5) == 0)
    playhead.schedule(0.5, at: 10)
    playhead.schedule(0.25, at: 10.01)
    #expect(playhead.scheduled == 0.75)
    #expect(abs(playhead.position(at: 10.2) - 0.2) < 0.0001)
    #expect(playhead.position(at: 11) == 0.5)
    playhead.finish(at: 10.52)
    #expect(abs(playhead.position(at: 10.62) - 0.6) < 0.0001)
    playhead.finish(at: 10.77)
    #expect(playhead.position(at: 12) == 0.75)
    playhead.schedule(1, at: 20)
    #expect(abs(playhead.position(at: 20.4) - 1.15) < 0.0001)
}

@Test func sonioxVoicesComeFromTheModelListWithCuratedVoicesFirst() throws {
    let voices = SonioxTTS.voices(fromModels: try fixtureData("soniox-tts-models", "json"))
    #expect(voices == ["Daniel", "Zed", "Hazel", "Grace"])
    #expect(SonioxTTS.ordered(voices) == ["Hazel", "Grace", "Daniel", "Zed"])
    #expect(SonioxTTS.ordered([]) == SonioxTTS.voices)
}

@Test func playbackQueueKeepsSentenceOrderWhenLaterAudioArrivesFirst() {
    var queue = SonioxPlaybackQueue()
    queue.open("s1")
    queue.open("s2")
    queue.open("s3")
    let a = Data([1, 0]), b = Data([2, 0]), c = Data([3, 0]), d = Data([4, 0])
    #expect(queue.audio("s2", b).isEmpty)
    #expect(queue.audio("s3", d).isEmpty)
    #expect(queue.end("s3").isEmpty)
    #expect(queue.audio("s1", a) == [.init("s1", a)])
    #expect(queue.end("s2").isEmpty)
    #expect(queue.audio("s1", c) == [.init("s1", c)])
    #expect(queue.end("s1") == [.init("s2", b), .init("s3", d)])
    #expect(queue.isEmpty)
    queue.open("s4")
    queue.reset()
    #expect(queue.audio("s4", a).isEmpty)
}

@Test func speechSelectionDefaultsMouthToSonioxOnlyWithAKey() {
    #expect(SpeechSelection.resolve(ears: nil, mouth: nil, hasSonioxKey: true) == .init(ears: .iphone, mouth: .soniox))
    #expect(SpeechSelection.resolve(ears: nil, mouth: nil, hasSonioxKey: false) == .init(ears: .iphone, mouth: .iphone))
    #expect(
        SpeechSelection.resolve(ears: "soniox", mouth: "iphone", hasSonioxKey: true)
            == .init(ears: .soniox, mouth: .iphone))
    let missing = SpeechSelection.resolve(ears: "soniox", mouth: "", hasSonioxKey: false)
    #expect(missing.ears == .iphone)
    #expect(missing.mouth == .iphone)
    #expect(missing.notice != nil)
}

@Test func resamplerTurnsMicrophoneFloatsInto16kHzSignedPCM() throws {
    let resampler = PCM16Resampler()
    let data = try #require(resampler.convert(sine(seconds: 0.5)))
    let samples = data.count / 2
    #expect(abs(samples - 8000) < 400)
    let peak = data.withUnsafeBytes { raw in
        (0..<samples).map { abs(Int(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) }.max() ?? 0
    }
    #expect(peak > 12000)
    let buffer = try #require(PCM.floatBuffer(s16le: pcm(samples: 10, value: 16384), sampleRate: 24000))
    #expect(buffer.frameLength == 10)
    #expect(abs(buffer.floatChannelData![0][0] - 0.5) < 0.001)
}

@Test func wavHeaderDescribes16kMonoPCM() {
    let wav = PCM.wav(s16le: pcm(samples: 160), sampleRate: 16000)
    #expect(wav.count == 44 + 320)
    #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
    #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
    let rate = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }
    let channels = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: UInt16.self) }
    #expect(rate == 16000)
    #expect(channels == 1)
}

@Test func archiveSavesTheUserSpanAsWavWithAManifest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = TurnAudioArchive(directory: directory, keepSeconds: 10, padding: 0)
    archive.append(pcm(samples: 16000, value: 1), at: 101)
    archive.append(pcm(samples: 16000, value: 2), at: 102)
    let clip = archive.clip(from: 101, to: 102)
    #expect(clip.count == 32000)
    #expect(clip.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int16.self) } == 2)
    let entry = try #require(
        try archive.save(
            turn: 3, text: "what are my agents doing", speechStart: 101, speechEnd: 102, ears: "soniox:stt-rt-v6",
            mouth: "iphone", model: "gpt-test", date: Date(timeIntervalSince1970: 0)))
    #expect(entry.file == "turn-19700101-000000-3.wav")
    #expect(entry.durationMs == 1000)
    let wav = try Data(contentsOf: directory.appendingPathComponent(entry.file))
    #expect(wav.count == 44 + 32000)
    #expect(archive.entries == [entry])
    let manifest = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: archive.manifestURL)) as? [[String: Any]])
    #expect(manifest.first?["ears"] as? String == "soniox:stt-rt-v6")
    #expect(manifest.first?["sample_rate"] as? Int == 16000)
    #expect(manifest.first?["text"] as? String == "what are my agents doing")
    #expect(try archive.save(turn: 4, text: "", speechStart: 50, speechEnd: 60, ears: "", mouth: "", model: "") == nil)
}

@MainActor
@Test func sonioxMouthStreamsReplyTokensIntoOneStreamAndClosesItWhenTheReplyEnds() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let mouth = SonioxMouth(apiKey: "test-key", voice: "Hazel", line: { line }, connect: factory.connect)
    let log = MouthLog(mouth)
    let tokens = [
        "Claude in **the API** pro", "ject is still running the test ", "suite, and Codex in web is", " idle.",
    ]
    for token in tokens { mouth.stream(token, reply: 4) }
    let socket = try #require(factory.last)
    #expect(socket.url == SonioxTTS.url)
    #expect(socket.key == "test-key")
    #expect(await eventually { socket.sent.count == 5 })
    var sent = socket.sentJSON
    #expect(sent[0]["return_timestamps"] as? Bool == true)
    #expect(sent.allSatisfy { $0["stream_id"] as? String == "s1" })
    #expect(sent.dropFirst().allSatisfy { $0["text_end"] as? Bool == false })
    #expect(sent[1]["text"] as? String == "Claude in the API ")
    mouth.finish()
    #expect(await eventually { socket.sent.count == 6 })
    sent = socket.sentJSON
    #expect(sent[5]["text"] as? String == "idle.")
    #expect(sent[5]["text_end"] as? Bool == true)
    #expect(
        sent.dropFirst().compactMap { $0["text"] as? String }.joined()
            == "Claude in the API project is still running the test suite, and Codex in web is idle.")
    #expect(log.events == [.started])

    socket.push(audioReply("s1", pcm(samples: 2400), end: true, marks: marks("Claude in the API")))
    socket.push(#"{"terminated":true,"stream_id":"s1"}"#)
    #expect(await eventually { line.scheduled.count == 1 })
    #expect(mouth.isSpeaking)
    line.playAll()
    #expect(await eventually { !mouth.isSpeaking })
    #expect(log.heard(4) == "Claude in the API")
    #expect(log.events.last == .idle)
    mouth.shutdown()
    #expect(socket.closed)
}

@MainActor
@Test func sonioxMouthSendsAShortFirstSentenceAtOnceAndStreamsTheRest() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let mouth = SonioxMouth(apiKey: "test-key", line: { line }, connect: factory.connect)
    let log = MouthLog(mouth)
    mouth.stream("Hmm, let me check. Claude is ", reply: 1)
    mouth.stream("busy. Codex ", reply: 1)
    let socket = try #require(factory.last)
    #expect(await eventually { socket.sent.count == 5 })
    let sent = socket.sentJSON
    #expect(sent.map { $0["stream_id"] as? String } == ["s1", "s1", "s2", "s2", "s2"])
    #expect(sent[1]["text"] as? String == "Hmm, let me check.")
    #expect(sent[1]["text_end"] as? Bool == true)
    #expect(sent[3]["text"] as? String == "Claude is ")
    #expect(sent[4]["text"] as? String == "busy. Codex ")
    #expect(sent[4]["text_end"] as? Bool == false)
    mouth.finish()
    #expect(await eventually { socket.sentJSON.last?["text_end"] as? Bool == true })

    socket.push(audioReply("s2", pcm(samples: 240), end: true, marks: marks("Claude is busy. Codex")))
    socket.push(#"{"terminated":true,"stream_id":"s2"}"#)
    socket.push(audioReply("s1", pcm(samples: 480), end: true, marks: marks("Hmm, let me check.")))
    socket.push(#"{"terminated":true,"stream_id":"s1"}"#)
    #expect(await eventually { line.scheduled.count == 2 })
    #expect(line.scheduled.map(\.frameLength) == [480, 240])
    line.playAll()
    #expect(await eventually { !mouth.isSpeaking })
    #expect(log.heard(1) == "Hmm, let me check. Claude is busy. Codex")
    #expect(log.upcoming == "Hmm, let me check. Claude is busy. Codex")
    mouth.shutdown()
}

@MainActor
@Test func sonioxMouthReportsHeardWordsAndUpcomingTextFromTimestampsAndPlayback() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let clock = LockedClock(100)
    let mouth = SonioxMouth(apiKey: "test-key", line: { line }, connect: factory.connect, clock: { clock.value })
    let log = MouthLog(mouth)
    mouth.speak("Hello there world.")
    let socket = try #require(factory.last)
    socket.push(audioReply("s1", pcm(samples: 24000), marks: marks("Hello there world.", step: 0.06)))
    #expect(await eventually { log.events.count == 3 })
    #expect(log.events == [.started, .upcoming("Hello there "), .heard("Hello", reply: nil)])
    clock.value = 100.5
    #expect(await eventually { log.events.count == 5 })
    #expect(log.events.suffix(2) == [.upcoming("world."), .heard(" there", reply: nil)])
    socket.push(audioReply("s1", Data(), end: true))
    socket.push(#"{"terminated":true,"stream_id":"s1"}"#)
    try await Task.sleep(for: .milliseconds(120))
    #expect(log.events.count == 5)
    clock.value = 101
    line.playAll()
    #expect(await eventually { !mouth.isSpeaking })
    #expect(log.events.suffix(2) == [.heard(" world.", reply: nil), .idle])
    mouth.shutdown()
}

@MainActor
@Test func sonioxMouthEndsAStalledStreamBeforeTheServerTimesItOut() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let clock = LockedClock(50)
    let mouth = SonioxMouth(
        apiKey: "test-key", line: { line }, connect: factory.connect, stallTimeout: 2, clock: { clock.value })
    mouth.stream("Claude in the API project is still wai", reply: 2)
    let socket = try #require(factory.last)
    #expect(await eventually { socket.sent.count == 2 })
    clock.value = 51.9
    try await Task.sleep(for: .milliseconds(120))
    #expect(socket.sent.count == 2)
    clock.value = 52.1
    #expect(await eventually { socket.sent.count == 3 })
    #expect(socket.sentJSON[2]["text"] as? String == "")
    #expect(socket.sentJSON[2]["text_end"] as? Bool == true)
    mouth.stream("ting for you.", reply: 2)
    mouth.finish()
    #expect(await eventually { socket.sent.count == 6 })
    let rest = socket.sentJSON.dropFirst(3)
    #expect(rest.allSatisfy { $0["stream_id"] as? String == "s2" })
    #expect(rest.compactMap { $0["text"] as? String }.joined() == "waiting for you.")
    #expect(rest.last?["text_end"] as? Bool == true)
    mouth.shutdown()
}

@MainActor
@Test func sonioxMouthKeepsAtMostThreeStreamsOpen() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let mouth = SonioxMouth(apiKey: "test-key", line: { line }, connect: factory.connect)
    for text in ["One.", "Two.", "Three.", "Four."] { mouth.speak(text) }
    let socket = try #require(factory.last)
    #expect(await eventually { socket.sent.count == 6 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(socket.sent.count == 6)
    socket.push(audioReply("s1", pcm(samples: 240), end: true))
    socket.push(#"{"terminated":true,"stream_id":"s1"}"#)
    #expect(await eventually { socket.sent.count == 8 })
    #expect(socket.sentJSON[7]["text"] as? String == "Four.")
    mouth.shutdown()
}

@MainActor
@Test func sonioxMouthStopCancelsStreamsAndIgnoresLateAudio() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let mouth = SonioxMouth(apiKey: "test-key", line: { line }, connect: factory.connect)
    let log = MouthLog(mouth)
    mouth.stream("Long reply that the user interrupts. ", reply: 1)
    let socket = try #require(factory.last)
    socket.push(audioReply("s1", pcm(samples: 480), marks: marks("Long reply", step: 1)))
    #expect(await eventually { line.scheduled.count == 1 })
    mouth.stop()
    #expect(!mouth.isSpeaking)
    #expect(line.stopCount == 1)
    #expect(await eventually { socket.sentJSON.contains { $0["cancel"] as? Bool == true } })
    socket.push(audioReply("s1", pcm(samples: 480), marks: marks(" that")))
    try await Task.sleep(for: .milliseconds(50))
    #expect(line.scheduled.count == 1)
    #expect(log.events == [.started, .upcoming("Long"), .heard("Long", reply: 1), .idle])
    mouth.speak("Next turn.")
    #expect(await eventually { socket.sentJSON.last?["stream_id"] as? String == "s2" })
    #expect(factory.sockets.count == 1)
    mouth.shutdown()
}

@MainActor
@Test func sonioxMouthReportsUnspokenTextOnAuthErrorAndTimeout() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let mouth = SonioxMouth(apiKey: "bad", line: { line }, connect: factory.connect)
    var failures: [(SonioxError, [Utterance], Int?)] = []
    mouth.onFailure = { failures.append(($0, $1, $2)) }
    mouth.speak("One.")
    mouth.stream("Two is still ", reply: 9)
    let socket = try #require(factory.last)
    socket.push(#"{"error_code":401,"error_type":"unauthenticated","error_message":"Invalid API key."}"#)
    #expect(await eventually { failures.count == 1 })
    #expect(failures[0].0.kind == .auth)
    #expect(failures[0].1 == [Utterance("One."), Utterance("Two is still", reply: 9)])
    #expect(failures[0].2 == 9)
    #expect(!mouth.isSpeaking)
    #expect(socket.closed)

    let clock = LockedClock(10)
    let slow = SonioxMouth(
        apiKey: "key", line: { line }, connect: factory.connect, firstAudioTimeout: 4, clock: { clock.value })
    slow.onFailure = { failures.append(($0, $1, $2)) }
    slow.stream("Hello", reply: 3)
    slow.stream(" there", reply: 3)
    clock.value = 11.5
    slow.finish()
    clock.value = 15.4
    try await Task.sleep(for: .milliseconds(120))
    #expect(failures.count == 1)
    clock.value = 15.6
    #expect(await eventually { failures.count == 2 })
    #expect(failures[1].0.kind == .timeout)
    #expect(failures[1].1 == [Utterance("Hello there", reply: 3)])
    #expect(failures[1].2 == nil)
    #expect(!slow.isSpeaking)

    let keyless = SonioxMouth(apiKey: "", line: { line }, connect: factory.connect)
    keyless.onFailure = { failures.append(($0, $1, $2)) }
    keyless.speak("No key.")
    #expect(failures.count == 3)
    #expect(failures[2].1 == [Utterance("No key.")])
}

@MainActor
final class ScriptedMouth: ProviderMouth {
    var onEvent: ((MouthEvent) -> Void)?
    var onFailure: ((SonioxError, [Utterance], Int?) -> Void)?
    private(set) var isSpeaking = false
    private(set) var spoken: [String] = []

    func speak(_ text: String) {
        spoken.append(text)
        if !isSpeaking {
            isSpeaking = true
            onEvent?(.started)
        }
    }

    func stream(_ delta: String, reply: Int) {
        speak(delta)
    }

    func finish() {}

    func stop() {
        guard isSpeaking else { return }
        isSpeaking = false
        onEvent?(.idle)
    }

    func fail(_ kind: SonioxError.Kind) {
        onFailure?(SonioxError(kind, message: "x"), spoken.map { Utterance($0) }, nil)
        stop()
    }
}

@MainActor
@Test func fallbackMouthSpeaksTheRestOfTheTurnOnTheIPhoneVoice() async throws {
    let time = LockedClock(0)
    let primary = ScriptedMouth()
    let fallback = TimedMouth(secondsPerCharacter: 0.0001)
    let mouth = FallbackMouth(primary: primary, fallback: fallback, cooldown: 20, clock: { time.value })
    var events: [MouthEvent] = []
    var notices: [String] = []
    mouth.onEvent = { events.append($0) }
    mouth.onNotice = { notices.append($0) }
    mouth.speak("One.")
    primary.fail(.network)
    #expect(fallback.spoken == ["One."])
    #expect(notices.count == 1)
    mouth.speak("Two.")
    #expect(fallback.spoken == ["One.", "Two."])
    #expect(await eventually { !mouth.isSpeaking })
    #expect(events.filter { $0 == .started || $0 == .idle } == [.started, .idle])
    mouth.speak("Three.")
    #expect(fallback.spoken.last == "Three.")
    mouth.stop()
    time.value = 25
    mouth.speak("Four.")
    #expect(primary.spoken.last == "Four.")
    primary.fail(.auth)
    time.value = 100
    mouth.stop()
    mouth.speak("Five.")
    #expect(mouth.disabled)
    #expect(fallback.spoken.last == "Five.")
    mouth.stop()
}

@MainActor
@Test func fallbackMouthContinuesAReplyOnTheIPhoneVoiceFromWhereSonioxAudioStopped() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let primary = SonioxMouth(apiKey: "test-key", line: { line }, connect: factory.connect)
    let fallback = TimedMouth(secondsPerCharacter: 0.0001)
    let mouth = FallbackMouth(primary: primary, fallback: fallback)
    let log = MouthLog(mouth)
    var notices: [String] = []
    mouth.onNotice = { notices.append($0) }
    mouth.stream("Claude in the API project is still running the test suite and Codex in web fin", reply: 3)
    let socket = try #require(factory.last)
    socket.push(audioReply("s1", pcm(samples: 2400), marks: marks("Claude in the API pro")))
    #expect(await eventually { line.scheduled.count == 1 })
    socket.drop()
    #expect(await eventually { notices.count == 1 })
    #expect(mouth.usingFallback)
    mouth.stream("ished two minutes ago. All good", reply: 3)
    mouth.finish()
    #expect(
        fallback.spoken == [
            "is still running the test suite and Codex in web finished two minutes ago.", "All good",
        ])
    line.playAll()
    #expect(await eventually { !mouth.isSpeaking })
    #expect(
        log.heard(3)
            == "Claude in the API pro" + "is still running the test suite and Codex in web finished two minutes ago. "
            + "All good ")
    #expect(log.events.filter { $0 == .started || $0 == .idle } == [.started, .idle])
}

@MainActor
final class ScriptedEars: VoiceEars {
    var onEvent: ((EarsEvent) -> Void)?
    var muted = false
    var startError: Error?
    private(set) var running = false

    func start() async throws {
        if let startError { throw startError }
        running = true
    }

    func stop() {
        running = false
    }
}

@MainActor
@Test func fallbackEarsSwitchToTheIPhoneWhenSonioxFails() async throws {
    let primary = ScriptedEars()
    let fallback = ScriptedEars()
    let ears = FallbackEars(primary: primary, fallback: { fallback })
    var events: [EarsEvent] = []
    var notices: [String] = []
    ears.onEvent = { events.append($0) }
    ears.onNotice = { notices.append($0) }
    try await ears.start()
    primary.onEvent?(.partial("hello"))
    primary.onEvent?(.failed("Soniox is not reachable"))
    #expect(await eventually { fallback.running })
    #expect(!primary.running)
    #expect(notices.count == 1)
    fallback.onEvent?(.phrase("still here"))
    #expect(events == [.partial("hello"), .phrase("still here")])
    ears.muted = true
    #expect(fallback.muted)
    ears.stop()
    #expect(!fallback.running)

    let broken = ScriptedEars()
    broken.startError = SonioxError(.auth, message: "No Soniox API key")
    let other = ScriptedEars()
    let second = FallbackEars(primary: broken, fallback: { other })
    try await second.start()
    #expect(other.running)
    #expect(second.usingFallback)
}

@MainActor
@Test func sonioxEarsStreamPCMAndTurnRepliesIntoEarsEvents() async throws {
    let factory = SocketFactory()
    let microphone = FakeMicrophone()
    let clock = LockedClock(500)
    let ears = SonioxEars(
        apiKey: "test-key", microphone: microphone, connect: factory.connect, clock: { clock.value })
    var events: [EarsEvent] = []
    ears.onEvent = { events.append($0) }
    try await ears.start()
    let socket = try #require(factory.last)
    #expect(socket.url == SonioxSTT.url)
    let sink = try #require(microphone.sink)
    for _ in 0..<4 { sink(sine(seconds: 0.5)) }
    #expect(await eventually { socket.sent.count >= 3 })
    #expect(json(socket.sent[0])["model"] as? String == "stt-rt-v6")
    guard case .data(let audio) = socket.sent[1] else {
        Issue.record("expected binary audio")
        return
    }
    #expect(audio.count >= 3200)

    for line in try fixtureLines("soniox-stt", "jsonl").prefix(3) { socket.push(line) }
    #expect(await eventually { events.contains(.phrase("What are my agents doing?")) })
    let spoken = events.compactMap { event -> ClosedRange<TimeInterval>? in
        if case .spoken(let start, let end) = event { return start...end }
        return nil
    }
    let span = try #require(spoken.first)
    #expect(abs(span.lowerBound - (500 - 2 + 0.42)) < 0.05)
    #expect(abs(span.upperBound - (500 - 2 + 1.52)) < 0.05)

    ears.agentSaid("Claude is ", end: false)
    ears.agentSaid("", end: true)
    #expect(await eventually { socket.sentJSON.filter { $0["type"] as? String == "agent_text" }.count == 2 })
    let said = socket.sentJSON.filter { $0["type"] as? String == "agent_text" }
    #expect(said.map { $0["text"] as? String } == ["Claude is ", ""])
    #expect(said.map { $0["end_of_segment"] as? Bool } == [false, true])
    try await Task.sleep(for: .milliseconds(700))
    #expect(!socket.sentJSON.contains { $0["type"] as? String == "finalize" })

    ears.muted = true
    #expect(await eventually { socket.sentJSON.contains { $0["type"] as? String == "finalize" } })
    let count = socket.sent.count
    sink(sine(seconds: 0.5))
    try await Task.sleep(for: .milliseconds(30))
    #expect(socket.sent.count == count)

    socket.push(#"{"error_code":401,"error_type":"unauthenticated","error_message":"Invalid API key."}"#)
    #expect(await eventually { events.contains { if case .failed = $0 { true } else { false } } })
    #expect(ears.lastError?.kind == .auth)
    #expect(socket.closed)
    #expect(microphone.sink == nil)
}

@MainActor
@Test func fastTurnEndFinalizesAfterHalfASecondWithoutNewWords() async throws {
    let factory = SocketFactory()
    let clock = LockedClock(500)
    let ears = SonioxEars(
        apiKey: "test-key", microphone: FakeMicrophone(), turnEnd: .fast, connect: factory.connect,
        clock: { clock.value })
    var events: [EarsEvent] = []
    ears.onEvent = { events.append($0) }
    try await ears.start()
    let socket = try #require(factory.last)
    func finalizes() -> Int { socket.sentJSON.filter { $0["type"] as? String == "finalize" }.count }
    #expect(await eventually { socket.sentJSON.first?["endpoint_latency_adjustment_level"] as? Int == 3 })
    socket.push(#"{"tokens":[{"text":"What","is_final":false}]}"#)
    try await Task.sleep(for: .milliseconds(250))
    socket.push(#"{"tokens":[{"text":"What","is_final":false},{"text":" now","is_final":false}]}"#)
    try await Task.sleep(for: .milliseconds(350))
    #expect(finalizes() == 0)
    socket.push(#"{"tokens":[{"text":"What","is_final":false},{"text":" now","is_final":false}]}"#)
    #expect(await eventually { finalizes() == 1 })
    socket.push(
        #"{"tokens":[{"text":"What","is_final":true},{"text":" now","is_final":true},{"text":"<fin>","is_final":true}]}"#
    )
    #expect(await eventually { events.contains(.phrase("What now")) })
    socket.push(#"{"tokens":[{"text":"And","is_final":false}]}"#)
    try await Task.sleep(for: .milliseconds(700))
    #expect(finalizes() == 1)
    clock.value = 503
    socket.push(#"{"tokens":[{"text":"And","is_final":false},{"text":" then","is_final":false}]}"#)
    #expect(await eventually { finalizes() == 2 })
    ears.stop()
}

final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval

    init(_ now: TimeInterval) {
        self.now = now
    }

    var value: TimeInterval {
        get { lock.withLock { now } }
        set { lock.withLock { now = newValue } }
    }
}
