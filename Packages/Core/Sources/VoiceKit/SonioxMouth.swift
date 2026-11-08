#if !os(watchOS)
    @preconcurrency import AVFoundation
    import Foundation

    @MainActor
    public protocol ProviderMouth: VoiceMouth {
        var onFailure: ((SonioxError, [String]) -> Void)? { get set }
    }

    @MainActor
    public final class SonioxMouth: ProviderMouth {
        public var onEvent: ((MouthEvent) -> Void)?
        public var onFailure: ((SonioxError, [String]) -> Void)?
        public private(set) var isSpeaking = false
        public var voice: String
        public let model: String
        private let apiKey: String
        private let line: @MainActor () -> AudioLine?
        private let connect: SonioxConnect
        private let firstAudioTimeout: Duration
        private let keepaliveInterval: Duration
        private var socket: SonioxSocket?
        private var outbox: AsyncStream<SocketMessage>.Continuation?
        private var tasks: [Task<Void, Never>] = []
        private var queue = SonioxPlaybackQueue()
        private var streams: [String: Utterance] = [:]
        private var order: [String] = []
        private var unannounced: [String: String] = [:]
        private var counter = 0
        private var scheduled = 0
        private var generation = 0
        private static let maxStreams = 4

        struct Utterance {
            var text: String
            var sent = false
            var heard = false
            var audioDone = false
            var remainder = Data()
        }

        public init(
            apiKey: String, voice: String = SonioxTTS.defaultVoice, model: String = SonioxTTS.model,
            line: @escaping @MainActor () -> AudioLine?, connect: @escaping SonioxConnect = WebSocketConnection.connect,
            firstAudioTimeout: Duration = .seconds(4), keepaliveInterval: Duration = .seconds(20)
        ) {
            self.apiKey = apiKey
            self.voice = voice
            self.model = model
            self.line = line
            self.connect = connect
            self.firstAudioTimeout = firstAudioTimeout
            self.keepaliveInterval = keepaliveInterval
        }

        public func prepare() {
            guard !apiKey.isEmpty else { return }
            _ = ensureSocket()
        }

        public func shutdown() {
            stop()
            closeSocket()
        }

        public func speak(_ text: String) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            counter += 1
            let id = "s\(counter)"
            streams[id] = Utterance(text: text)
            unannounced[id] = text
            order.append(id)
            queue.open(id)
            if !isSpeaking {
                isSpeaking = true
                onEvent?(.started)
            }
            guard !apiKey.isEmpty else {
                fail(SonioxError(.auth, message: "No Soniox API key"))
                return
            }
            sendWaiting()
        }

        public func stop() {
            generation += 1
            for (id, utterance) in streams where utterance.sent {
                outbox?.yield(.text(SonioxTTS.cancel(stream: id)))
            }
            streams = [:]
            order = []
            unannounced = [:]
            queue.reset()
            scheduled = 0
            line()?.stop()
            guard isSpeaking else { return }
            isSpeaking = false
            onEvent?(.idle)
        }

        private func sendWaiting() {
            var active = streams.values.filter(\.sent).count
            for id in order where active < Self.maxStreams {
                guard var utterance = streams[id], !utterance.sent else { continue }
                guard let outbox = ensureSocket() else { return }
                utterance.sent = true
                streams[id] = utterance
                active += 1
                outbox.yield(.text(SonioxTTS.start(stream: id, voice: voice, model: model)))
                outbox.yield(.text(SonioxTTS.text(stream: id, utterance.text)))
                let timeout = firstAudioTimeout
                tasks.append(
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        guard let self, !Task.isCancelled, let utterance = self.streams[id], !utterance.heard else {
                            return
                        }
                        self.fail(SonioxError(.timeout, message: "No audio from Soniox"))
                    })
            }
        }

        private func ensureSocket() -> AsyncStream<SocketMessage>.Continuation? {
            if let outbox { return outbox }
            let socket = connect(SonioxTTS.url, apiKey)
            let (stream, outbox) = AsyncStream<SocketMessage>.makeStream()
            self.socket = socket
            self.outbox = outbox
            let interval = keepaliveInterval
            tasks.append(
                Task.detached {
                    for await message in stream {
                        do { try await socket.send(message) } catch { return }
                    }
                })
            tasks.append(Task { [weak self] in await self?.receive(socket) })
            tasks.append(
                Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: interval)
                        guard let self, self.socket === socket else { return }
                        self.outbox?.yield(.text(SonioxTTS.keepalive))
                    }
                })
            return outbox
        }

        private func receive(_ socket: SonioxSocket) async {
            while true {
                let message: SocketMessage
                do {
                    message = try await socket.receive()
                } catch {
                    guard self.socket === socket else { return }
                    let pending = streams.values.contains(where: \.sent)
                    closeSocket()
                    if pending { fail(SonioxError(.network, message: "Soniox connection lost")) }
                    return
                }
                guard self.socket === socket else { return }
                handle(SonioxTTS.parse(message))
            }
        }

        func handle(_ reply: SonioxTTS.Reply) {
            switch reply {
            case .audio(let id, let pcm, let end):
                guard var utterance = streams[id] else { return }
                utterance.heard = true
                var data = utterance.remainder + pcm
                let even = data.count - data.count % 2
                utterance.remainder = data.count > even ? data.suffix(1) : Data()
                data = data.prefix(even)
                if end { utterance.audioDone = true }
                streams[id] = utterance
                for chunk in queue.audio(id, data) { play(chunk) }
                if end { for chunk in queue.end(id) { play(chunk) } }
            case .terminated(let id):
                guard let utterance = streams[id] else { return }
                if !utterance.audioDone { for chunk in queue.end(id) { play(chunk) } }
                streams[id] = nil
                order.removeAll { $0 == id }
                sendWaiting()
                checkIdle()
            case .failed(_, let error):
                fail(error)
            case .ignored:
                break
            }
        }

        private func play(_ chunk: SonioxPlaybackQueue.Chunk) {
            guard let buffer = PCM.floatBuffer(s16le: chunk.pcm, sampleRate: Double(SonioxTTS.sampleRate)),
                let line = line()
            else { return }
            if let text = unannounced.removeValue(forKey: chunk.stream) { onEvent?(.playing(text)) }
            scheduled += 1
            let generation = generation
            let finished: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in self?.played(generation) }
            }
            let scheduledOK = line.schedule(buffer, completion: finished)
            if !scheduledOK { played(generation) }
            onEvent?(.level(PCM.level(buffer)))
        }

        private func played(_ value: Int) {
            guard value == generation else { return }
            scheduled = max(0, scheduled - 1)
            checkIdle()
        }

        private func checkIdle() {
            guard isSpeaking, streams.isEmpty, scheduled == 0 else { return }
            isSpeaking = false
            onEvent?(.idle)
        }

        private func fail(_ error: SonioxError) {
            let unspoken = order.compactMap { id -> String? in
                guard let utterance = streams[id], !utterance.heard else { return nil }
                return utterance.text
            }
            streams = [:]
            order = []
            unannounced = [:]
            queue.reset()
            closeSocket()
            onFailure?(error, unspoken)
            checkIdle()
        }

        private func closeSocket() {
            outbox?.finish()
            outbox = nil
            for task in tasks { task.cancel() }
            tasks = []
            socket?.close()
            socket = nil
        }
    }
#endif
