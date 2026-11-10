#if !os(watchOS)
    @preconcurrency import AVFoundation
    import Foundation

    public struct Utterance: Equatable, Sendable {
        public var text: String
        public var reply: Int?

        public init(_ text: String, reply: Int? = nil) {
            self.text = text
            self.reply = reply
        }
    }

    @MainActor
    public protocol ProviderMouth: VoiceMouth {
        var onFailure: ((SonioxError, [Utterance], Int?) -> Void)? { get set }
    }

    @MainActor
    public final class SonioxMouth: ProviderMouth {
        public var onEvent: ((MouthEvent) -> Void)?
        public var onFailure: ((SonioxError, [Utterance], Int?) -> Void)?
        public private(set) var isSpeaking = false
        public var voice: String
        public let model: String
        public static let lead: TimeInterval = 0.7
        static let maxStreams = 3
        static let firstSentenceLimit = 70
        static let generatingLength = 120
        private let apiKey: String
        private let line: @MainActor () -> AudioLine?
        private let connect: SonioxConnect
        private let firstAudioTimeout: TimeInterval
        private let stallTimeout: TimeInterval
        private let keepaliveInterval: Duration
        private let clock: @Sendable () -> TimeInterval
        private var socket: SonioxSocket?
        private var outbox: AsyncStream<SocketMessage>.Continuation?
        private var tasks: [Task<Void, Never>] = []
        private var ticker: Task<Void, Never>?
        private var queue = SonioxPlaybackQueue()
        private var playhead = Playhead()
        private var streams: [String: Stream] = [:]
        private var order: [String] = []
        private var cleaner = SpeechCleaner()
        private var current: String?
        private var reply: Int?
        private var split = false
        private var counter = 0
        private var scheduled = 0
        private var generation = 0

        struct Stream {
            var reply: Int?
            var spaced: Bool
            var text = ""
            var unsent = ""
            var ended = false
            var opened = false
            var closed = false
            var terminated = false
            var sentAt: TimeInterval = 0
            var expectAudio: TimeInterval?
            var gotAudio = false
            var audioDone = false
            var remainder = Data()
            var marks: [SonioxTTS.Mark] = []
            var offset: TimeInterval?
            var received: TimeInterval = 0
            var seconds: TimeInterval = 0
            var upcoming = 0
            var heard = 0
        }

        public init(
            apiKey: String, voice: String = SonioxTTS.defaultVoice, model: String = SonioxTTS.model,
            line: @escaping @MainActor () -> AudioLine?, connect: @escaping SonioxConnect = WebSocketConnection.connect,
            firstAudioTimeout: TimeInterval = 4, stallTimeout: TimeInterval = 2,
            keepaliveInterval: Duration = .seconds(20),
            clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.apiKey = apiKey
            self.voice = voice
            self.model = model
            self.line = line
            self.connect = connect
            self.firstAudioTimeout = firstAudioTimeout
            self.stallTimeout = stallTimeout
            self.keepaliveInterval = keepaliveInterval
            self.clock = clock
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
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            finish()
            let id = open(reply: nil)
            streams[id]?.text = text
            streams[id]?.unsent = text
            streams[id]?.ended = true
            flush(id)
        }

        public func stream(_ delta: String, reply: Int) {
            self.reply = reply
            add(cleaner.append(delta))
        }

        public func finish() {
            guard reply != nil else { return }
            add(cleaner.flush(), last: true)
            current = nil
            reply = nil
            split = false
            cleaner = SpeechCleaner()
        }

        public func stop() {
            generation += 1
            for (id, stream) in streams where stream.opened && !stream.terminated {
                outbox?.yield(.text(SonioxTTS.cancel(stream: id)))
            }
            reset()
            playhead = Playhead()
            scheduled = 0
            line()?.stop()
            guard isSpeaking else { return }
            isSpeaking = false
            ticker?.cancel()
            onEvent?(.idle)
        }

        private func add(_ piece: String, last: Bool = false) {
            guard !piece.isEmpty || (last && current != nil) else { return }
            let id = current ?? open(reply: reply)
            current = id
            streams[id]?.text += piece
            streams[id]?.unsent += piece
            if !split, var stream = streams[id], let end = SpeechChunker.sentenceEnd(in: stream.text) {
                split = true
                if stream.text.distance(from: stream.text.startIndex, to: end) <= Self.firstSentenceLimit {
                    let tail = String(stream.text[end...])
                    stream.text = String(stream.text[..<end])
                    stream.unsent.removeLast(min(tail.count, stream.unsent.count))
                    stream.ended = true
                    streams[id] = stream
                    current = nil
                    flush(id)
                    add(String(tail.drop(while: \.isWhitespace)), last: last)
                    return
                }
            }
            if last {
                streams[id]?.ended = true
                current = nil
            }
            flush(id)
        }

        private func open(reply: Int?) -> String {
            counter += 1
            let id = "s\(counter)"
            streams[id] = Stream(reply: reply, spaced: isSpeaking)
            order.append(id)
            queue.open(id)
            if !isSpeaking {
                isSpeaking = true
                onEvent?(.started)
                startTicker()
            }
            return id
        }

        private func flush(_ id: String) {
            guard var stream = streams[id], !stream.closed else { return }
            guard !apiKey.isEmpty else {
                fail(SonioxError(.auth, message: "No Soniox API key"))
                return
            }
            if !stream.opened {
                guard streams.values.filter({ $0.opened && !$0.terminated }).count < Self.maxStreams else { return }
                stream.opened = true
                ensureSocket().yield(.text(SonioxTTS.start(stream: id, voice: voice, model: model)))
            }
            if !stream.unsent.isEmpty || stream.ended {
                outbox?.yield(.text(SonioxTTS.text(stream: id, stream.unsent, end: stream.ended)))
                stream.unsent = ""
                stream.closed = stream.ended
                stream.sentAt = clock()
                if stream.expectAudio == nil, stream.closed || stream.text.count >= Self.generatingLength {
                    stream.expectAudio = stream.sentAt
                }
            }
            streams[id] = stream
        }

        private func startTicker() {
            ticker?.cancel()
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self, !Task.isCancelled, self.isSpeaking else { return }
                    self.tick()
                }
            }
        }

        private func tick() {
            let now = clock()
            if let id = current, let stream = streams[id], stream.opened, now - stream.sentAt >= stallTimeout {
                streams[id]?.ended = true
                current = nil
                flush(id)
            }
            let late = streams.values.contains { stream in
                !stream.gotAudio && stream.expectAudio.map { now - $0 >= firstAudioTimeout } == true
            }
            if late {
                fail(SonioxError(.timeout, message: "No audio from Soniox"))
            } else {
                progress()
                checkIdle()
            }
        }

        private func ensureSocket() -> AsyncStream<SocketMessage>.Continuation {
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
                    let pending = streams.values.contains { $0.opened && !$0.terminated }
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
            case .audio(let id, let pcm, let end, let marks):
                guard var stream = streams[id] else { return }
                stream.gotAudio = true
                stream.marks += marks
                var data = stream.remainder + pcm
                let even = data.count - data.count % 2
                stream.remainder = data.count > even ? data.suffix(1) : Data()
                data = data.prefix(even)
                stream.received += Double(even / 2) / Double(SonioxTTS.sampleRate)
                if end { stream.audioDone = true }
                streams[id] = stream
                for chunk in queue.audio(id, data) { play(chunk) }
                if end { for chunk in queue.end(id) { play(chunk) } }
                progress()
            case .terminated(let id):
                guard let stream = streams[id] else { return }
                if !stream.audioDone { for chunk in queue.end(id) { play(chunk) } }
                streams[id]?.terminated = true
                for waiting in order { flush(waiting) }
                progress()
                checkIdle()
            case .failed(_, let error):
                fail(error)
            case .ignored:
                break
            }
        }

        private func play(_ chunk: SonioxPlaybackQueue.Chunk) {
            guard let buffer = PCM.floatBuffer(s16le: chunk.pcm, sampleRate: Double(SonioxTTS.sampleRate)) else {
                return
            }
            let seconds = Double(buffer.frameLength) / Double(SonioxTTS.sampleRate)
            let now = clock()
            if streams[chunk.stream]?.offset == nil { streams[chunk.stream]?.offset = playhead.scheduled }
            streams[chunk.stream]?.seconds += seconds
            playhead.schedule(seconds, at: now)
            scheduled += 1
            let generation = generation
            let clock = clock
            let finished: @Sendable () -> Void = { [weak self] in
                let at = clock()
                Task { @MainActor in self?.played(generation, at: at) }
            }
            if line()?.schedule(buffer, completion: finished) != true { played(generation, at: now) }
            onEvent?(.level(PCM.level(buffer)))
        }

        private func played(_ value: Int, at time: TimeInterval) {
            guard value == generation else { return }
            scheduled = max(0, scheduled - 1)
            playhead.finish(at: time)
            progress()
            checkIdle()
        }

        private func progress() {
            let position = playhead.position(at: clock())
            var events: [MouthEvent] = []
            var upcoming = true
            var heard = true
            for id in order {
                guard var stream = streams[id] else { continue }
                let at = stream.offset.map { position - $0 }
                let played =
                    stream.seconds >= stream.received - 0.000_001 && (at ?? .infinity) >= stream.seconds - 0.000_001
                let done = stream.terminated && played
                if let at = done ? TimeInterval.infinity : at {
                    Self.report(&stream, at: at, upcoming: upcoming, heard: heard, into: &events)
                }
                let complete = stream.audioDone || stream.terminated
                upcoming = upcoming && complete && stream.upcoming == stream.marks.count
                heard = heard && complete && stream.heard == stream.marks.count
                if done {
                    if stream.marks.isEmpty, !stream.text.isEmpty {
                        let text = (stream.spaced ? " " : "") + stream.text
                        events += [.upcoming(text), .heard(text, reply: stream.reply)]
                    }
                    streams[id] = nil
                } else {
                    streams[id] = stream
                }
            }
            order.removeAll { streams[$0] == nil }
            for event in events { onEvent?(event) }
        }

        private static func report(
            _ stream: inout Stream, at position: TimeInterval, upcoming ahead: Bool = true, heard audible: Bool = true,
            into events: inout [MouthEvent]
        ) {
            let marks = stream.marks
            func isSpace(_ index: Int) -> Bool { marks[index].text.allSatisfy(\.isWhitespace) }
            var heard = audible ? marks.prefix { $0.start <= position }.count : 0
            while heard > 0, heard < marks.count, !isSpace(heard - 1), !isSpace(heard) { heard += 1 }
            heard = max(heard, stream.heard)
            let upcoming = max(ahead ? marks.prefix { $0.start <= position + lead }.count : 0, heard, stream.upcoming)
            func text(_ range: Range<Int>) -> String {
                (range.lowerBound == 0 && stream.spaced ? " " : "") + marks[range].map(\.text).joined()
            }
            if upcoming > stream.upcoming { events.append(.upcoming(text(stream.upcoming..<upcoming))) }
            if heard > stream.heard { events.append(.heard(text(stream.heard..<heard), reply: stream.reply)) }
            stream.upcoming = upcoming
            stream.heard = heard
        }

        private func checkIdle() {
            guard isSpeaking, streams.isEmpty, scheduled == 0 else { return }
            isSpeaking = false
            ticker?.cancel()
            playhead = Playhead()
            onEvent?(.idle)
        }

        private func fail(_ error: SonioxError) {
            var events: [MouthEvent] = []
            var unspoken: [Utterance] = []
            for id in order {
                guard var stream = streams[id] else { continue }
                Self.report(&stream, at: .infinity, into: &events)
                let rest = Self.remainder(of: stream.text, after: stream.marks)
                if !rest.isEmpty { unspoken.append(Utterance(rest, reply: stream.reply)) }
            }
            let open = reply
            if let open, !cleaner.held.isEmpty {
                if let last = unspoken.indices.last, unspoken[last].reply == open {
                    unspoken[last].text += " " + cleaner.held
                } else {
                    unspoken.append(Utterance(cleaner.held, reply: open))
                }
            }
            reset()
            closeSocket()
            for event in events { onEvent?(event) }
            onFailure?(error, unspoken, open)
            checkIdle()
        }

        static func remainder(of text: String, after marks: [SonioxTTS.Mark]) -> String {
            var count = marks.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
            guard count > 0 else { return text.trimmingCharacters(in: .whitespaces) }
            var index = text.startIndex
            while index < text.endIndex, count > 0 {
                if !text[index].isWhitespace { count -= 1 }
                index = text.index(after: index)
            }
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            return text[index...].trimmingCharacters(in: .whitespaces)
        }

        private func reset() {
            streams = [:]
            order = []
            queue.reset()
            cleaner = SpeechCleaner()
            current = nil
            reply = nil
            split = false
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
