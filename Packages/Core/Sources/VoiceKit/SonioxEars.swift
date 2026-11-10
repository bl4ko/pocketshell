#if !os(watchOS)
    @preconcurrency import AVFoundation
    import Foundation

    @MainActor
    public final class SonioxEars: VoiceEars {
        public var onEvent: ((EarsEvent) -> Void)?
        public var muted = false {
            didSet {
                flag.on = muted
                if muted, !oldValue { outbox?.yield(.text(SonioxSTT.finalize)) }
            }
        }
        public var terms = ["Claude", "Codex", "Herdr", "tmux", "PocketShell"]
        public private(set) var lastError: SonioxError?
        public let model: String
        public let turnEnd: TurnEnd
        private let apiKey: String
        private let microphone: MicrophoneSource
        private let connect: SonioxConnect
        private let permission: @MainActor () async -> Bool
        private let timeline: AudioTimeline
        private let clock: @Sendable () -> TimeInterval
        private let flag = LockedFlag()
        private var socket: SonioxSocket?
        private var outbox: AsyncStream<SocketMessage>.Continuation?
        private var tasks: [Task<Void, Never>] = []
        private var partial = ""
        private var quietTask: Task<Void, Never>?
        private var finalizedAt = -TimeInterval.infinity
        static let finalizeSpacing: TimeInterval = 2

        public init(
            apiKey: String, microphone: MicrophoneSource, model: String = SonioxSTT.model,
            turnEnd: TurnEnd = .balanced,
            connect: @escaping SonioxConnect = WebSocketConnection.connect,
            permission: @escaping @MainActor () async -> Bool = { true },
            clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.apiKey = apiKey
            self.microphone = microphone
            self.model = model
            self.turnEnd = turnEnd
            self.connect = connect
            self.permission = permission
            self.clock = clock
            timeline = AudioTimeline(clock: clock)
        }

        public func start() async throws {
            guard await permission() else {
                throw SonioxError(.server, message: "Allow microphone access in Settings")
            }
            guard !apiKey.isEmpty else { throw SonioxError(.auth, message: "No Soniox API key") }
            let socket = connect(SonioxSTT.url, apiKey)
            let (stream, outbox) = AsyncStream<SocketMessage>.makeStream()
            outbox.yield(.text(SonioxSTT.start(model: model, terms: terms, turnEnd: turnEnd)))
            self.socket = socket
            self.outbox = outbox
            flag.on = muted
            tasks = [
                Task.detached {
                    for await message in stream {
                        do { try await socket.send(message) } catch { return }
                    }
                },
                Task { [weak self] in await self?.receive(socket) },
                Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(10))
                        if !Task.isCancelled { outbox.yield(.text(SonioxSTT.keepalive)) }
                    }
                },
            ]
            let resampler = PCM16Resampler()
            let batch = PCMBatch(bytes: 3200)
            let flag = flag
            let timeline = timeline
            microphone.setSink { buffer in
                guard !flag.on, let data = resampler.convert(buffer) else { return }
                timeline.advance(seconds: Double(data.count / 2) / PCM16Resampler.sampleRate)
                if let chunk = batch.add(data) { outbox.yield(.data(chunk)) }
            }
            microphone.onInputLevel = { [weak self] level in
                guard let self, !self.muted else { return }
                self.onEvent?(.level(level))
            }
        }

        public func stop() {
            teardown()
        }

        public func agentSaid(_ text: String, end: Bool) {
            outbox?.yield(.text(SonioxSTT.agentText(text, end: end)))
        }

        private func watchQuiet(_ text: String) {
            guard let quiet = turnEnd.quiet, text != partial else { return }
            partial = text
            quietTask?.cancel()
            guard !text.isEmpty else { return }
            quietTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(quiet))
                guard let self, !Task.isCancelled, self.partial == text, !self.muted,
                    self.clock() - self.finalizedAt >= Self.finalizeSpacing
                else { return }
                self.finalizedAt = self.clock()
                self.outbox?.yield(.text(SonioxSTT.finalize))
            }
        }

        private func receive(_ socket: SonioxSocket) async {
            var transcript = SonioxTranscript()
            while true {
                let message: SocketMessage
                do {
                    message = try await socket.receive()
                } catch {
                    if self.socket === socket { fail(SonioxError(.network, message: "Soniox connection lost")) }
                    return
                }
                guard self.socket === socket else { return }
                for event in transcript.handle(message) {
                    switch event {
                    case .partial(let text):
                        onEvent?(.partial(text))
                        watchQuiet(text)
                    case .phrase(let text, let start, let end):
                        watchQuiet("")
                        if let start, let end {
                            onEvent?(
                                .spoken(
                                    start: timeline.uptime(atAudioSecond: Double(start) / 1000),
                                    end: timeline.uptime(atAudioSecond: Double(end) / 1000)))
                        }
                        onEvent?(.phrase(text))
                    case .finished:
                        fail(SonioxError(.server, message: "Soniox ended the session"))
                        return
                    case .failed(let error):
                        fail(error)
                        return
                    }
                }
            }
        }

        private func fail(_ error: SonioxError) {
            lastError = error
            teardown()
            onEvent?(.failed(error.notice))
        }

        private func teardown() {
            microphone.setSink(nil)
            microphone.onInputLevel = nil
            outbox?.finish()
            outbox = nil
            for task in tasks { task.cancel() }
            tasks = []
            quietTask?.cancel()
            partial = ""
            socket?.close()
            socket = nil
        }
    }

    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var on: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    final class PCMBatch: @unchecked Sendable {
        private let lock = NSLock()
        private let bytes: Int
        private var pending = Data()

        init(bytes: Int) {
            self.bytes = bytes
        }

        func add(_ data: Data) -> Data? {
            lock.withLock {
                pending.append(data)
                guard pending.count >= bytes else { return nil }
                defer { pending = Data() }
                return pending
            }
        }
    }
#endif
