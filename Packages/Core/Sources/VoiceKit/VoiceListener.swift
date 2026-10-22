#if os(iOS)
    @preconcurrency import AVFoundation
    import Foundation
    @preconcurrency import Speech

    @MainActor
    public final class VoiceListener: ObservableObject {
        public enum State: Equatable, Sendable {
            case off
            case listening
            case paused
            case failed(String)
        }

        @Published public private(set) var state: State = .off
        @Published public private(set) var partial = ""
        public var contextualStrings: [String] = []
        public var onPhrase: ((String) -> Void)?

        private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        private let engine = AVAudioEngine()
        private let feed = AudioFeed()
        private var wanted = false
        private var task: SFSpeechRecognitionTask?
        private var phraseID: ObjectIdentifier?
        private var pending: Task<Void, Never>?
        private var muteObserver: NSObjectProtocol?

        public init() {}

        public var isOn: Bool {
            state == .listening || state == .paused
        }

        public func start() async {
            guard !isOn, !wanted else { return }
            wanted = true
            let allowed = await Self.speechAuthorized()
            guard wanted else { return }
            guard allowed, await AVAudioApplication.requestRecordPermission(), wanted else {
                fail("Allow microphone and speech recognition in Settings")
                return
            }
            guard let recognizer, recognizer.isAvailable else {
                fail("Speech recognition is not available")
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
                try session.setActive(true)
                Self.installTap(on: engine.inputNode, feed: feed)
                engine.prepare()
                try engine.start()
            } catch {
                fail(error.localizedDescription)
                return
            }
            try? AVAudioApplication.shared.setInputMuted(false)
            muteObserver = NotificationCenter.default.addObserver(
                forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main
            ) { [weak self] note in
                let muted = (note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue ?? false
                MainActor.assumeIsolated { self?.setMuted(muted) }
            }
            state = .listening
            beginPhrase()
        }

        public func stop() {
            wanted = false
            guard isOn else {
                if case .failed = state { state = .off }
                return
            }
            teardown()
            state = .off
        }

        private func fail(_ message: String) {
            teardown()
            wanted = false
            state = .failed(message)
        }

        private func teardown() {
            endPhrase()
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if let muteObserver { NotificationCenter.default.removeObserver(muteObserver) }
            muteObserver = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        private func setMuted(_ muted: Bool) {
            if muted, state == .listening {
                endPhrase()
                state = .paused
            } else if !muted, state == .paused {
                state = .listening
                beginPhrase()
            }
        }

        private func beginPhrase() {
            guard let recognizer, state == .listening else { return }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.contextualStrings = contextualStrings
            request.taskHint = .dictation
            let id = ObjectIdentifier(request)
            phraseID = id
            feed.request = request
            task = Self.recognize(request, with: recognizer) { [weak self] text, done in
                self?.heard(text, done: done, from: id)
            }
        }

        private func heard(_ text: String?, done: Bool, from id: ObjectIdentifier) {
            guard id == phraseID else { return }
            if let text { partial = text }
            pending?.cancel()
            let wait: Duration = done ? (partial.isEmpty ? .seconds(1) : .zero) : .seconds(1)
            pending = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.finishPhrase()
            }
        }

        private func finishPhrase() {
            let phrase = partial
            endPhrase()
            if !phrase.isEmpty { onPhrase?(phrase) }
            beginPhrase()
        }

        private func endPhrase() {
            pending?.cancel()
            pending = nil
            feed.request = nil
            phraseID = nil
            task?.cancel()
            task = nil
            partial = ""
        }

        // Callbacks formed on the main actor trap when audio or speech threads call them.
        nonisolated private static func speechAuthorized() async -> Bool {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }

        nonisolated private static func installTap(on node: AVAudioInputNode, feed: AudioFeed) {
            node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { buffer, _ in
                feed.append(buffer)
            }
        }

        nonisolated private static func recognize(
            _ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
            update: @escaping @MainActor (String?, Bool) -> Void
        ) -> SFSpeechRecognitionTask {
            recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let done = result?.isFinal == true || error != nil
                Task { @MainActor in update(text, done) }
            }
        }
    }

    private final class AudioFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var current: SFSpeechAudioBufferRecognitionRequest?

        var request: SFSpeechAudioBufferRecognitionRequest? {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            request?.append(buffer)
        }
    }
#endif
