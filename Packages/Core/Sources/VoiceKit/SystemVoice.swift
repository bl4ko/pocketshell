#if os(iOS)
    @preconcurrency import AVFoundation
    import Foundation
    @preconcurrency import Speech

    @MainActor
    public final class SystemMouth: VoiceMouth {
        public var onEvent: ((MouthEvent) -> Void)?
        public private(set) var isSpeaking = false
        public var voiceIdentifier: String? {
            didSet { if voiceIdentifier != oldValue { voice = nil } }
        }
        private var voice: AVSpeechSynthesisVoice?
        private let synthesizer = AVSpeechSynthesizer()
        private let audio: DuplexAudio
        private let state = MouthState()

        public init(audio: DuplexAudio, voiceIdentifier: String? = nil) {
            self.audio = audio
            self.voiceIdentifier = voiceIdentifier
        }

        public func speak(_ text: String) {
            let utterance = AVSpeechUtterance(string: text)
            if voice == nil {
                voice = SpeechVoices.choose(voiceIdentifier, from: SpeechVoices.installed()).flatMap {
                    AVSpeechSynthesisVoice(identifier: $0.id)
                }
            }
            utterance.voice = voice
            let generation = state.beginUtterance()
            if !isSpeaking {
                isSpeaking = true
                onEvent?(.started)
            }
            let line = audio.line
            let state = state
            let finished: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in self?.drained(generation) }
            }
            synthesizer.write(utterance) { [weak self] buffer in
                guard state.isCurrent(generation) else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    if state.finishUtterance(generation) { finished() }
                    return
                }
                state.addBuffer()
                let scheduled = line.schedule(pcm) {
                    if state.bufferPlayed(generation) { finished() }
                }
                if !scheduled, state.bufferPlayed(generation) { finished() }
                let level = Self.level(pcm)
                Task { @MainActor in self?.onEvent?(.level(level)) }
            }
        }

        public func stop() {
            state.reset()
            synthesizer.stopSpeaking(at: .immediate)
            audio.line.stop()
            guard isSpeaking else { return }
            isSpeaking = false
            onEvent?(.idle)
        }

        private func drained(_ generation: Int) {
            guard state.isIdle(generation), isSpeaking else { return }
            isSpeaking = false
            onEvent?(.idle)
        }

        nonisolated private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return 0 }
            var sum: Float = 0
            if let samples = buffer.floatChannelData?[0] {
                for frame in 0..<frames { sum += samples[frame] * samples[frame] }
            } else if let samples = buffer.int16ChannelData?[0] {
                for frame in 0..<frames {
                    let value = Float(samples[frame]) / Float(Int16.max)
                    sum += value * value
                }
            }
            return min(1, (sum / Float(frames)).squareRoot() * 5)
        }
    }

    final class MouthState: @unchecked Sendable {
        private let lock = NSLock()
        private var generation = 0
        private var utterances = 0
        private var buffers = 0

        func beginUtterance() -> Int {
            lock.withLock {
                utterances += 1
                return generation
            }
        }

        func isCurrent(_ value: Int) -> Bool {
            lock.withLock { value == generation }
        }

        func addBuffer() {
            lock.withLock { buffers += 1 }
        }

        func finishUtterance(_ value: Int) -> Bool {
            lock.withLock {
                guard value == generation else { return false }
                utterances = max(0, utterances - 1)
                return utterances == 0 && buffers == 0
            }
        }

        func bufferPlayed(_ value: Int) -> Bool {
            lock.withLock {
                guard value == generation else { return false }
                buffers = max(0, buffers - 1)
                return utterances == 0 && buffers == 0
            }
        }

        func isIdle(_ value: Int) -> Bool {
            lock.withLock { value == generation && utterances == 0 && buffers == 0 }
        }

        func reset() {
            lock.withLock {
                generation += 1
                utterances = 0
                buffers = 0
            }
        }
    }

    @MainActor
    public final class OnDeviceEars: VoiceEars {
        public var onEvent: ((EarsEvent) -> Void)?
        public var muted = false {
            didSet {
                gate.paused = muted
                if muted, let flush { Task { await flush() } }
            }
        }
        public var contextualStrings: [String] = ["Claude", "Codex", "Herdr", "tmux"]
        private let audio: DuplexAudio
        private let gate = EarsGate()
        private var listenTask: Task<Void, Never>?
        private var flush: (@Sendable () async -> Void)?
        private var finish: (@Sendable () async -> Void)?

        public init(audio: DuplexAudio) {
            self.audio = audio
        }

        public func start() async throws {
            guard #available(iOS 26, *) else { throw EarsError(message: "Voice mode needs iOS 26") }
            let speech = await Self.speechAuthorized()
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard speech, microphone else {
                throw EarsError(message: "Allow microphone and speech recognition in Settings")
            }
            let stream = try await SpeechStream.make(contextualStrings: contextualStrings)
            let gate = gate
            gate.paused = muted
            audio.setSink { buffer in
                if !gate.paused { stream.append(buffer) }
            }
            audio.onInputLevel = { [weak self] level in
                guard let self, !self.muted else { return }
                self.onEvent?(.level(level))
            }
            flush = { await stream.flush() }
            finish = { await stream.finish() }
            listenTask = Task { [weak self] in
                do {
                    for try await event in stream.events {
                        switch event {
                        case .partial(let text): self?.onEvent?(.partial(text))
                        case .phrase(let text): self?.onEvent?(.phrase(text))
                        }
                    }
                } catch {
                    if !Task.isCancelled { self?.onEvent?(.failed(error.localizedDescription)) }
                }
            }
        }

        public func stop() {
            audio.setSink(nil)
            audio.onInputLevel = nil
            listenTask?.cancel()
            listenTask = nil
            if let finish { Task { await finish() } }
            finish = nil
            flush = nil
        }

        nonisolated private static func speechAuthorized() async -> Bool {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
    }

    private struct EarsError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    final class EarsGate: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var paused: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
#endif
