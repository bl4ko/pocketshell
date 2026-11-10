import Foundation

#if os(iOS)
    @preconcurrency import AVFoundation
#endif

public enum VoicePreviewClip: Equatable, Sendable {
    case file(URL)
    case speech(text: String, voiceIdentifier: String?)
}

@MainActor
public protocol VoicePreviewOutput: AnyObject {
    func play(_ clip: VoicePreviewClip, finished: @escaping @MainActor () -> Void) throws
    func stop()
}

@MainActor
public final class VoicePreviewPlayer: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case loading(String)
        case playing(String)
        case failed(String, String)
    }

    public typealias Loader = @Sendable () async throws -> VoicePreviewClip

    @Published public private(set) var state: State = .idle
    private let output: VoicePreviewOutput
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(output: VoicePreviewOutput) {
        self.output = output
    }

    public func isActive(_ id: String) -> Bool {
        state == .loading(id) || state == .playing(id)
    }

    public func error(for id: String) -> String? {
        if case .failed(id, let message) = state { return message }
        return nil
    }

    public func toggle(_ id: String, load: @escaping Loader) {
        if isActive(id) { stop() } else { play(id, load: load) }
    }

    public func play(_ id: String, load: @escaping Loader) {
        stop()
        let current = generation
        state = .loading(id)
        task = Task { [weak self] in
            do {
                let clip = try await load()
                guard let self, self.generation == current else { return }
                try self.output.play(clip) { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.stop()
                }
                self.state = .playing(id)
            } catch {
                guard let self, self.generation == current else { return }
                self.output.stop()
                self.state = .failed(id, Self.message(error))
            }
        }
    }

    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
        output.stop()
        state = .idle
    }

    static func message(_ error: Error) -> String {
        (error as? SonioxError)?.previewMessage ?? error.localizedDescription
    }
}

@MainActor
public final class TimedPreviewOutput: VoicePreviewOutput {
    public private(set) var played: [VoicePreviewClip] = []
    private let seconds: Double
    private var task: Task<Void, Never>?

    public init(seconds: Double = 2) {
        self.seconds = seconds
    }

    public func play(_ clip: VoicePreviewClip, finished: @escaping @MainActor () -> Void) throws {
        task?.cancel()
        played.append(clip)
        let seconds = seconds
        task = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { finished() }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}

#if os(iOS)
    @MainActor
    public final class SystemPreviewOutput: NSObject, VoicePreviewOutput, AVAudioPlayerDelegate,
        AVSpeechSynthesizerDelegate
    {
        private let synthesizer = AVSpeechSynthesizer()
        private var player: AVAudioPlayer?
        private var utterance: AVSpeechUtterance?
        private var finished: (@MainActor () -> Void)?
        private var active = false
        private var release: Task<Void, Never>?

        public override init() {
            super.init()
            synthesizer.delegate = self
        }

        public func play(_ clip: VoicePreviewClip, finished: @escaping @MainActor () -> Void) throws {
            stop()
            release?.cancel()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            active = true
            self.finished = finished
            switch clip {
            case .file(let url):
                let player = try AVAudioPlayer(contentsOf: url)
                player.delegate = self
                self.player = player
                guard player.play() else { throw VoicePreviewError(message: "The preview audio did not play") }
            case .speech(let text, let voiceIdentifier):
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = SpeechVoices.choose(voiceIdentifier, from: SpeechVoices.installed()).flatMap {
                    AVSpeechSynthesisVoice(identifier: $0.id)
                }
                self.utterance = utterance
                synthesizer.speak(utterance)
            }
        }

        public func stop() {
            finished = nil
            player?.stop()
            player = nil
            utterance = nil
            if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
            guard active else { return }
            active = false
            release?.cancel()
            release = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, !self.active else { return }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }

        private func ended(_ source: ObjectIdentifier) {
            guard source == player.map(ObjectIdentifier.init) || source == utterance.map(ObjectIdentifier.init)
            else { return }
            let finished = finished
            self.finished = nil
            finished?()
        }

        nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            let source = ObjectIdentifier(player)
            Task { @MainActor in self.ended(source) }
        }

        nonisolated public func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
        ) {
            let source = ObjectIdentifier(utterance)
            Task { @MainActor in self.ended(source) }
        }
    }

    struct VoicePreviewError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
#endif
