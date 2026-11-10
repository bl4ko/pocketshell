@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import VoiceKit

private let liveKey = ProcessInfo.processInfo.environment["PS_SONIOX_LIVE_KEY"]

private func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

final class Loopback: AudioLine, @unchecked Sendable {
    static let rate = 24000.0
    private let lock = NSLock()
    private var queue: [(samples: [Float], done: @Sendable () -> Void)] = []
    private var cursor = 0
    private var voice: [Float] = []
    private var voiceAt = 0
    private var time = 0
    private var began = 0.0
    private var first: TimeInterval?
    private var recorded: [Float] = []
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var pump: Task<Void, Never>?
    private let gain: Float
    private let realtime: Bool

    init(gain: Float = 0, realtime: Bool = true) {
        self.gain = gain
        self.realtime = realtime
    }

    var firstAudio: TimeInterval? { lock.withLock { first } }
    var samples: [Float] { lock.withLock { recorded } }

    func setSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { self.sink = sink }
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @Sendable () -> Void) -> Bool {
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        lock.withLock {
            if first == nil { first = uptime() }
            recorded += samples
            if realtime { queue.append((samples, completion)) }
        }
        if !realtime { completion() }
        return true
    }

    func stop() {
        lock.withLock {
            queue = []
            cursor = 0
        }
    }

    func say(_ samples: [Float]) -> TimeInterval {
        lock.withLock {
            voice = samples
            voiceAt = time
            let last = samples.lastIndex { abs($0) > 0.02 } ?? samples.count
            return began + Double(time + last) / Self.rate
        }
    }

    func start() {
        let start = uptime()
        lock.withLock { began = start }
        pump = Task.detached { [self] in
            var tick = 0
            while !Task.isCancelled {
                tick += 1
                let wait = start + Double(tick) * 0.05 - uptime()
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                step(1200)
            }
        }
    }

    func end() {
        pump?.cancel()
    }

    private func step(_ count: Int) {
        var done: [@Sendable () -> Void] = []
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let out = buffer.floatChannelData![0]
        let sink = lock.withLock { () -> (@Sendable (AVAudioPCMBuffer) -> Void)? in
            for index in 0..<count {
                var sample = Float.random(in: -0.0003...0.0003)
                if let head = queue.first {
                    sample += gain * head.samples[cursor]
                    cursor += 1
                    if cursor == head.samples.count {
                        done.append(head.done)
                        queue.removeFirst()
                        cursor = 0
                    }
                }
                let spoken = time + index - voiceAt
                if voice.indices.contains(spoken) { sample += voice[spoken] }
                out[index] = sample
            }
            time += count
            return self.sink
        }
        sink?(buffer)
        for completion in done { completion() }
    }
}

@MainActor
final class LoopbackMicrophone: MicrophoneSource {
    var onInputLevel: ((Float) -> Void)?
    private let loop: Loopback

    init(_ loop: Loopback) {
        self.loop = loop
    }

    func setSink(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        loop.setSink(sink)
    }
}

@MainActor
@Suite(.enabled(if: liveKey != nil), .serialized)
struct SonioxLive {
    let key = liveKey ?? ""

    func synthesize(_ text: String, voice: String) async throws -> [Float] {
        let line = Loopback(realtime: false)
        let mouth = SonioxMouth(apiKey: key, voice: voice, line: { line })
        mouth.speak(text)
        #expect(await eventually(.seconds(20)) { !mouth.isSpeaking })
        mouth.shutdown()
        return line.samples
    }

    func firstAudio(_ text: String, streaming: Bool, play: Bool = false) async throws -> (ms: Int, heard: String) {
        let line = Loopback()
        let mouth = SonioxMouth(apiKey: key, line: { line })
        let log = MouthLog(mouth)
        mouth.prepare()
        line.start()
        try await Task.sleep(for: .milliseconds(500))
        var chunker = SpeechChunker()
        var rest = Substring(text)
        let start = uptime()
        while !rest.isEmpty {
            let token = String(rest.prefix(4))
            rest = rest.dropFirst(4)
            if streaming {
                mouth.stream(token, reply: 1)
            } else {
                for sentence in chunker.append(token) { mouth.speak(sentence) }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        if streaming {
            mouth.finish()
        } else {
            for sentence in chunker.flush() { mouth.speak(sentence) }
        }
        #expect(await eventually(.seconds(10)) { line.firstAudio != nil })
        let first = line.firstAudio ?? start
        if play { #expect(await eventually(.seconds(30)) { !mouth.isSpeaking }) }
        mouth.shutdown()
        line.end()
        return (Int((first - start) * 1000), log.heard(streaming ? 1 : nil))
    }

    @Test func firstAudioPerSentenceVersusTokenStream() async throws {
        let replies = [
            (
                "short first sentence",
                "Hmm, let me check that for you. Claude in the API project is still running the test suite."
            ),
            (
                "long first sentence",
                "Claude in the API project is still running the test suite, and Codex in web finished about two "
                    + "minutes ago with three files changed. Nothing needs your input."
            ),
            ("one short sentence", "Claude is still running the tests."),
        ]
        for (name, text) in replies {
            let old = try await firstAudio(text, streaming: false)
            let play = name == "short first sentence"
            let new = try await firstAudio(text, streaming: true, play: play)
            print("LIVE tts first audio, \(name): per sentence \(old.ms) ms, token stream \(new.ms) ms")
            if play {
                print("LIVE tts heard text: \(new.heard)")
                #expect(new.heard.split(separator: " ") == text.split(separator: " "))
            }
            #expect(new.ms < old.ms + 250)
        }
    }

    @Test func turnEndLatencyAtEachKnobLevel() async throws {
        let utterances = [
            try await synthesize("Tell Claude that the login page is broken on mobile.", voice: "Adrian"),
            try await synthesize("Wait, what about Codex?", voice: "Adrian"),
            try await synthesize("Okay, so the tests fail on main, and I want Codex to fix them.", voice: "Adrian"),
        ]
        for turnEnd in TurnEnd.allCases {
            for (index, samples) in utterances.enumerated() {
                let loop = Loopback()
                let ears = SonioxEars(apiKey: key, microphone: LoopbackMicrophone(loop), turnEnd: turnEnd)
                var phrases: [String] = []
                var last = 0.0
                ears.onEvent = { event in
                    guard case .phrase(let text) = event else { return }
                    phrases.append(text)
                    last = uptime()
                }
                try await ears.start()
                loop.start()
                try await Task.sleep(for: .milliseconds(400))
                let end = loop.say(samples)
                #expect(await eventually(.seconds(Double(samples.count) / Loopback.rate + 5)) { last > end - 0.3 })
                ears.stop()
                loop.end()
                print(
                    "LIVE stt turn end, \(turnEnd.label), utterance \(index + 1): "
                        + "\(Int((last - end) * 1000)) ms after speech stop, phrases \(phrases)")
            }
        }
    }

    @Test func agentTextSuppressesEchoOfTheMouth() async throws {
        let reply =
            "Claude in the API project is still running the test suite, and Codex in web finished about two "
            + "minutes ago with three files changed."
        let user = try await synthesize("Wait, stop. Tell Codex to open a pull request.", voice: "Adrian")
        for (agentText, bargeIn) in [(false, false), (true, false), (false, true), (true, true)] {
            let loop = Loopback(gain: 0.25)
            let ears = SonioxEars(apiKey: key, microphone: LoopbackMicrophone(loop))
            let mouth = SonioxMouth(apiKey: key, line: { loop })
            var partials: [String] = []
            var phrases: [String] = []
            ears.onEvent = { event in
                if case .partial(let text) = event, !text.isEmpty { partials.append(text) }
                if case .phrase(let text) = event { phrases.append(text) }
            }
            mouth.onEvent = { event in
                guard agentText else { return }
                if case .upcoming(let text) = event { ears.agentSaid(text, end: false) }
                if case .idle = event { ears.agentSaid("", end: true) }
            }
            try await ears.start()
            loop.start()
            mouth.speak(reply)
            if bargeIn {
                try await Task.sleep(for: .seconds(4))
                _ = loop.say(user)
            }
            #expect(await eventually(.seconds(30)) { !mouth.isSpeaking })
            try await Task.sleep(for: .seconds(3))
            ears.stop()
            mouth.shutdown()
            loop.end()
            print(
                "LIVE echo, agent text \(agentText ? "on" : "off"), user speaks \(bargeIn ? "yes" : "no"): "
                    + "first partial \"\(partials.first ?? "")\", \(partials.count) partials, phrases \(phrases)")
            if agentText, !bargeIn { #expect(partials.isEmpty && phrases.isEmpty) }
            if agentText, bargeIn { #expect(phrases.joined(separator: " ").lowercased().contains("pull request")) }
            if !agentText { #expect(!partials.isEmpty) }
        }
    }
}
