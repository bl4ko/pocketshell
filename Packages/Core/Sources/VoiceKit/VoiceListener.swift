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
        @Published public private(set) var problem: String?
        @Published public private(set) var hearingSound = false
        public var contextualStrings: [String] = []
        public var onPhrase: ((String) -> Void)?

        public private(set) static weak var current: VoiceListener?

        private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        private let feed = AudioFeed()
        private var engine: AVAudioEngine?
        private var starting: UUID?
        private var task: SFSpeechRecognitionTask?
        private var phraseID: ObjectIdentifier?
        private var pending: Task<Void, Never>?
        private var muteObserver: NSObjectProtocol?
        private var routeObserver: NSObjectProtocol?
        private var fallback = SpeechFallback(onDeviceAvailable: false)
        private var tapFormat = "-"
        private var restarts = 0
        private var results = 0
        private var lastFailure: SpeechFailure?

        public init() {}

        public var isOn: Bool {
            state == .listening || state == .paused
        }

        public var status: String? {
            switch state {
            case .off: nil
            case .listening:
                !partial.isEmpty ? partial : problem ?? (hearingSound ? "hearing you…" : "listening…")
            case .paused: "paused"
            case .failed(let message): message
            }
        }

        public static var report: String {
            current?.report ?? "never started"
        }

        public var report: String {
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
            let failure = lastFailure.map { "\($0.domain) \($0.code) \($0.message)" } ?? "-"
            return """
                state=\(state) onDevice=\(fallback.onDevice) engine=\(engine?.isRunning == true ? "running" : "stopped") restarts=\(restarts)
                route=\(route.joined(separator: ",")) sessionRate=\(Int(session.sampleRate)) tap=\(tapFormat) muted=\(AVAudioApplication.shared.isInputMuted)
                \(feed.stats) results=\(results)
                lastFailure=\(failure)
                """
        }

        public func start() async {
            guard !isOn, starting == nil else { return }
            let attempt = UUID()
            starting = attempt
            defer { if starting == attempt { starting = nil } }
            Self.current = self
            feed.reset()
            let allowed = await Self.speechAuthorized()
            guard starting == attempt else { return }
            let recordAllowed = await AVAudioApplication.requestRecordPermission()
            guard starting == attempt else { return }
            guard allowed, recordAllowed else {
                fail("Allow microphone and speech recognition in Settings")
                return
            }
            guard let recognizer, recognizer.isAvailable else {
                fail("Speech recognition is not available")
                return
            }
            fallback = SpeechFallback(onDeviceAvailable: recognizer.supportsOnDeviceRecognition)
            problem = nil
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
                try session.setActive(true)
                try startEngine()
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
            starting = nil
            guard isOn else {
                if case .failed = state { state = .off }
                return
            }
            teardown()
            state = .off
        }

        private func fail(_ message: String) {
            teardown()
            starting = nil
            state = .failed(message)
        }

        private func startEngine() throws {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            tapFormat = "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
            guard format.sampleRate > 0, format.channelCount > 0 else { throw NoMicrophone() }
            Self.installTap(on: input, format: format, feed: feed) { [weak self] loud in self?.hearingSound = loud }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
            self.engine = engine
            routeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartEngine() }
            }
        }

        private func stopEngine() {
            if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
            routeObserver = nil
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
        }

        private func restartEngine() {
            guard isOn else { return }
            restarts += 1
            stopEngine()
            do {
                try startEngine()
            } catch {
                fail(error.localizedDescription)
            }
        }

        private func teardown() {
            endPhrase()
            stopEngine()
            hearingSound = false
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
            request.requiresOnDeviceRecognition = fallback.onDevice
            request.contextualStrings = contextualStrings
            request.taskHint = .dictation
            let id = ObjectIdentifier(request)
            phraseID = id
            feed.request = request
            task = Self.recognize(request, with: recognizer) { [weak self] text, final, failure in
                self?.heard(text, final: final, failure: failure, from: id)
            }
        }

        private func heard(_ text: String?, final: Bool, failure: SpeechFailure?, from id: ObjectIdentifier) {
            guard id == phraseID else { return }
            if let text {
                partial = text
                problem = nil
                results += 1
            }
            if let failure { lastFailure = failure }
            let done = final || failure != nil
            if let failure, let message = fallback.phraseEnded(heardSpeech: !partial.isEmpty, failure: failure) {
                problem = message
            }
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

        nonisolated private static func installTap(
            on node: AVAudioInputNode, format: AVAudioFormat, feed: AudioFeed,
            loudness: @escaping @MainActor (Bool) -> Void
        ) {
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                if let loud = feed.append(buffer) {
                    Task { @MainActor in loudness(loud) }
                }
            }
        }

        nonisolated private static func recognize(
            _ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
            update: @escaping @MainActor (String?, Bool, SpeechFailure?) -> Void
        ) -> SFSpeechRecognitionTask {
            recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failure = (error as NSError?).map {
                    SpeechFailure(domain: $0.domain, code: $0.code, message: $0.localizedDescription)
                }
                Task { @MainActor in update(text, final, failure) }
            }
        }
    }

    private struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "No microphone input is available" }
    }

    private final class AudioFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var current: SFSpeechAudioBufferRecognitionRequest?
        private var loud = false
        private var buffers = 0
        private var maxPeak: Float = 0

        var request: SFSpeechAudioBufferRecognitionRequest? {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }

        func append(_ buffer: AVAudioPCMBuffer) -> Bool? {
            request?.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return nil }
            let peak = (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
            return lock.withLock {
                buffers += 1
                maxPeak = max(maxPeak, peak)
                guard (peak > 0.05) != loud else { return nil }
                loud.toggle()
                return loud
            }
        }

        var stats: String {
            lock.withLock { "buffers=\(buffers) maxPeak=\(String(format: "%.3f", maxPeak))" }
        }

        func reset() {
            lock.withLock {
                buffers = 0
                maxPeak = 0
                loud = false
            }
        }
    }
#endif
