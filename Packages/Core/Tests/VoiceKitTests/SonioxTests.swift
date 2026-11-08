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

@Test func sonioxStartRequestAsksForEnglishPCMWithEndpointDetection() {
    let config = json(.text(SonioxSTT.start(terms: ["Claude", "Herdr"])))
    #expect(config["model"] as? String == "stt-rt-v6")
    #expect(config["audio_format"] as? String == "pcm_s16le")
    #expect(config["sample_rate"] as? Int == 16000)
    #expect(config["num_channels"] as? Int == 1)
    #expect(config["language_hints"] as? [String] == ["en"])
    #expect(config["enable_endpoint_detection"] as? Bool == true)
    #expect((config["context"] as? [String: Any])?["terms"] as? [String] == ["Claude", "Herdr"])
    #expect(config["api_key"] == nil)
}

@Test func sonioxTTSRequestsUsePCMOneStreamPerSentence() {
    let start = json(.text(SonioxTTS.start(stream: "s1", voice: "Hazel")))
    #expect(start["stream_id"] as? String == "s1")
    #expect(start["model"] as? String == "tts-rt-v2")
    #expect(start["language"] as? String == "en")
    #expect(start["voice"] as? String == "Hazel")
    #expect(start["audio_format"] as? String == "pcm_s16le")
    #expect(start["sample_rate"] as? Int == 24000)
    #expect(start["api_key"] == nil)
    let text = json(.text(SonioxTTS.text(stream: "s1", "Hello there.")))
    #expect(text["text"] as? String == "Hello there.")
    #expect(text["text_end"] as? Bool == true)
    let cancel = json(.text(SonioxTTS.cancel(stream: "s1")))
    #expect(cancel["cancel"] as? Bool == true)
    #expect(cancel["stream_id"] as? String == "s1")
}

@Test func sonioxTTSRepliesDecodeAudioEndTerminationAndErrors() {
    let audio = pcm(samples: 4)
    #expect(SonioxTTS.parse(.text(audioReply("s1", audio))) == .audio(stream: "s1", pcm: audio, end: false))
    #expect(SonioxTTS.parse(.text(audioReply("s1", audio, end: true))) == .audio(stream: "s1", pcm: audio, end: true))
    #expect(SonioxTTS.parse(.text(#"{"terminated":true,"stream_id":"s1"}"#)) == .terminated("s1"))
    let failed = SonioxTTS.parse(
        .text(#"{"stream_id":"s2","error_code":408,"error_type":"request_timeout","error_message":"Timeout"}"#))
    #expect(
        failed == .failed(stream: "s2", SonioxError(.server, code: 408, type: "request_timeout", message: "Timeout")))
    #expect(SonioxTTS.parse(.text("not json")) == .ignored)
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
@Test func sonioxMouthPlaysSentencesInOrderAndGoesIdleAfterPlayback() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let mouth = SonioxMouth(apiKey: "test-key", voice: "Hazel", line: { line }, connect: factory.connect)
    var events: [MouthEvent] = []
    mouth.onEvent = { if case .level = $0 {} else { events.append($0) } }
    mouth.speak("First sentence.")
    mouth.speak("Second one.")
    let socket = try #require(factory.last)
    #expect(socket.url == SonioxTTS.url)
    #expect(socket.key == "test-key")
    #expect(await eventually { socket.sent.count == 4 })
    let sent = socket.sentJSON
    #expect(sent.map { $0["stream_id"] as? String } == ["s1", "s1", "s2", "s2"])
    #expect(sent[1]["text"] as? String == "First sentence.")
    #expect(sent[3]["text"] as? String == "Second one.")

    socket.push(audioReply("s2", pcm(samples: 240), end: true))
    socket.push(#"{"terminated":true,"stream_id":"s2"}"#)
    socket.push(audioReply("s1", pcm(samples: 480)))
    #expect(await eventually { line.scheduled.count == 1 })
    #expect(line.scheduled[0].frameLength == 480)
    socket.push(audioReply("s1", Data(), end: true))
    socket.push(#"{"terminated":true,"stream_id":"s1"}"#)
    #expect(await eventually { line.scheduled.count == 2 })
    #expect(line.scheduled[1].frameLength == 240)
    #expect(mouth.isSpeaking)
    line.playAll()
    #expect(await eventually { !mouth.isSpeaking })
    #expect(events == [.started, .playing("First sentence."), .playing("Second one."), .idle])
    mouth.shutdown()
    #expect(socket.closed)
}

@MainActor
@Test func sonioxMouthStopCancelsStreamsAndIgnoresLateAudio() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let mouth = SonioxMouth(apiKey: "test-key", line: { line }, connect: factory.connect)
    var events: [MouthEvent] = []
    mouth.onEvent = { if case .level = $0 {} else { events.append($0) } }
    mouth.speak("Long reply that the user interrupts.")
    let socket = try #require(factory.last)
    socket.push(audioReply("s1", pcm(samples: 480)))
    #expect(await eventually { line.scheduled.count == 1 })
    mouth.stop()
    #expect(!mouth.isSpeaking)
    #expect(line.stopCount == 1)
    #expect(await eventually { socket.sentJSON.contains { $0["cancel"] as? Bool == true } })
    socket.push(audioReply("s1", pcm(samples: 480)))
    try await Task.sleep(for: .milliseconds(50))
    #expect(line.scheduled.count == 1)
    #expect(events == [.started, .playing("Long reply that the user interrupts."), .idle])
    mouth.speak("Next turn.")
    #expect(await eventually { socket.sentJSON.last?["stream_id"] as? String == "s2" })
    #expect(factory.sockets.count == 1)
    mouth.shutdown()
}

@MainActor
@Test func sonioxMouthReportsUnspokenSentencesOnAuthErrorAndTimeout() async throws {
    let factory = SocketFactory()
    let line = FakeLine()
    let mouth = SonioxMouth(apiKey: "bad", line: { line }, connect: factory.connect)
    var failures: [(SonioxError, [String])] = []
    mouth.onFailure = { failures.append(($0, $1)) }
    mouth.speak("One.")
    mouth.speak("Two.")
    let socket = try #require(factory.last)
    socket.push(#"{"error_code":401,"error_type":"unauthenticated","error_message":"Invalid API key."}"#)
    #expect(await eventually { failures.count == 1 })
    #expect(failures[0].0.kind == .auth)
    #expect(failures[0].1 == ["One.", "Two."])
    #expect(!mouth.isSpeaking)
    #expect(socket.closed)

    let slow = SonioxMouth(
        apiKey: "key", line: { line }, connect: factory.connect, firstAudioTimeout: .milliseconds(30))
    slow.onFailure = { failures.append(($0, $1)) }
    slow.speak("Hello?")
    #expect(await eventually { failures.count == 2 })
    #expect(failures[1].0.kind == .timeout)
    #expect(failures[1].1 == ["Hello?"])
    #expect(!slow.isSpeaking)
}

@MainActor
final class ScriptedMouth: ProviderMouth {
    var onEvent: ((MouthEvent) -> Void)?
    var onFailure: ((SonioxError, [String]) -> Void)?
    private(set) var isSpeaking = false
    private(set) var spoken: [String] = []

    func speak(_ text: String) {
        spoken.append(text)
        if !isSpeaking {
            isSpeaking = true
            onEvent?(.started)
        }
    }

    func stop() {
        guard isSpeaking else { return }
        isSpeaking = false
        onEvent?(.idle)
    }

    func fail(_ kind: SonioxError.Kind) {
        onFailure?(SonioxError(kind, message: "x"), spoken)
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
