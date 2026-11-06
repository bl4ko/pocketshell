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

        private let feed = AudioFeed()
        private var engine: AVAudioEngine?
        private var starting: UUID?
        private var generation = 0
        private var flushStream: (@Sendable () async -> Void)?
        private var finishStream: (@Sendable () async -> Void)?
        private var muteObserver: NSObjectProtocol?
        private var routeObserver: NSObjectProtocol?
        private var model = "-"
        private var tapFormat = "-"
        private var restarts = 0
        private var phrases = 0
        private var lastFailure = "-"

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
            return """
                state=\(state) model=\(model) engine=\(engine?.isRunning == true ? "running" : "stopped") restarts=\(restarts)
                route=\(route.joined(separator: ",")) sessionRate=\(Int(session.sampleRate)) tap=\(tapFormat) muted=\(AVAudioApplication.shared.isInputMuted)
                \(feed.stats) phrases=\(phrases)
                lastFailure=\(lastFailure)
                """
        }

        public func start() async {
            guard !isOn, starting == nil else { return }
            guard #available(iOS 26, *) else {
                fail("Voice mode needs iOS 26")
                return
            }
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
            problem = "loading speech model…"
            state = .listening
            let stream: SpeechStream
            do {
                stream = try await SpeechStream.make(contextualStrings: contextualStrings + VoiceCommand.vocabulary) {
                    [weak self] in
                    Task { @MainActor in self?.problem = "downloading speech model…" }
                }
            } catch {
                if starting == attempt { fail(error.localizedDescription) }
                return
            }
            guard starting == attempt, isOn else {
                await stream.finish()
                return
            }
            model = "\(stream.engine) \(stream.locale.identifier) \(Int(stream.format.sampleRate))Hz"
            generation += 1
            listen(to: stream, generation: generation)
            feed.sink = stream.append
            flushStream = { await stream.flush() }
            finishStream = { await stream.finish() }
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
            problem = nil
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

        @available(iOS 26, *)
        private func listen(to stream: SpeechStream, generation: Int) {
            Task { [weak self] in
                do {
                    for try await event in stream.events {
                        guard let self else { return }
                        switch event {
                        case .partial(let text):
                            if self.generation == generation, self.isOn { self.partial = text }
                        case .phrase(let text):
                            if self.generation == generation { self.partial = "" }
                            self.phrases += 1
                            self.onPhrase?(text)
                        }
                    }
                } catch {
                    guard let self else { return }
                    self.lastFailure = error.localizedDescription
                    if self.generation == generation, self.isOn { self.fail(error.localizedDescription) }
                }
            }
        }

        private func fail(_ message: String) {
            lastFailure = message
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
            stopEngine()
            feed.sink = nil
            if let finishStream { Task { await finishStream() } }
            finishStream = nil
            flushStream = nil
            partial = ""
            hearingSound = false
            if let muteObserver { NotificationCenter.default.removeObserver(muteObserver) }
            muteObserver = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        private func setMuted(_ muted: Bool) {
            if muted, state == .listening {
                feed.paused = true
                if let flushStream { Task { await flushStream() } }
                state = .paused
            } else if !muted, state == .paused {
                feed.paused = false
                state = .listening
            }
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
    }

    private struct NoMicrophone: LocalizedError {
        var errorDescription: String? { "No microphone input is available" }
    }

    private final class AudioFeed: @unchecked Sendable {
        private let lock = NSLock()
        private var target: (@Sendable (AVAudioPCMBuffer) -> Void)?
        private var muted = false
        private var loud = false
        private var buffers = 0
        private var maxPeak: Float = 0

        var sink: (@Sendable (AVAudioPCMBuffer) -> Void)? {
            get { lock.withLock { target } }
            set { lock.withLock { target = newValue } }
        }

        var paused: Bool {
            get { lock.withLock { muted } }
            set { lock.withLock { muted = newValue } }
        }

        func append(_ buffer: AVAudioPCMBuffer) -> Bool? {
            let (sink, paused) = lock.withLock { (target, muted) }
            if !paused { sink?(buffer) }
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
                muted = false
            }
        }
    }
#endif
