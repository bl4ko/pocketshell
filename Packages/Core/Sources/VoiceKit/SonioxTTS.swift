import Foundation

public enum SonioxTTS {
    public static let url = URL(string: "wss://tts-rt.soniox.com/tts-websocket")!
    public static let model = "tts-rt-v2"
    public static let defaultVoice = "Hazel"
    public static let sampleRate = 24000
    public static let keepalive = #"{"keep_alive":true}"#
    public static let voices = [
        "Hazel", "Grace", "Logan", "Shane", "Reid", "Brooke", "Sloane", "Adrian", "Daniel", "Emma", "Isla", "Oliver",
        "Ruby", "Cooper",
    ]

    public static func start(stream: String, voice: String, model: String = model) -> String {
        SonioxJSON.string([
            "stream_id": stream, "model": model, "language": "en", "voice": voice, "audio_format": "pcm_s16le",
            "sample_rate": sampleRate, "return_timestamps": true,
        ])
    }

    public static func text(stream: String, _ text: String, end: Bool) -> String {
        SonioxJSON.string(["stream_id": stream, "text": text, "text_end": end])
    }

    public static func cancel(stream: String) -> String {
        SonioxJSON.string(["stream_id": stream, "cancel": true])
    }

    public struct Mark: Equatable, Sendable {
        public var text: String
        public var start: TimeInterval

        public init(_ text: String, _ start: TimeInterval) {
            self.text = text
            self.start = start
        }
    }

    public enum Reply: Equatable, Sendable {
        case audio(stream: String, pcm: Data, end: Bool, marks: [Mark])
        case terminated(String)
        case failed(stream: String?, SonioxError)
        case ignored
    }

    public static func parse(_ message: SocketMessage) -> Reply {
        guard let object = SonioxJSON.object(message) else { return .ignored }
        let stream = object["stream_id"] as? String
        if let error = SonioxError.frame(object) { return .failed(stream: stream, error) }
        guard let stream else { return .ignored }
        if let audio = object["audio"] as? String {
            let timestamps = object["timestamps"] as? [String: Any]
            let characters = timestamps?["characters"] as? [String] ?? []
            let starts = timestamps?["character_start_times_seconds"] as? [Double] ?? []
            return .audio(
                stream: stream, pcm: Data(base64Encoded: audio) ?? Data(), end: object["audio_end"] as? Bool ?? false,
                marks: zip(characters, starts).map { Mark($0, $1) })
        }
        if object["audio_end"] as? Bool == true { return .audio(stream: stream, pcm: Data(), end: true, marks: []) }
        if object["terminated"] as? Bool == true { return .terminated(stream) }
        return .ignored
    }
}

struct Playhead: Equatable, Sendable {
    private(set) var scheduled: TimeInterval = 0
    private var played: TimeInterval = 0
    private var queue: [TimeInterval] = []
    private var startedAt: TimeInterval?

    mutating func schedule(_ seconds: TimeInterval, at now: TimeInterval) {
        if queue.isEmpty { startedAt = now }
        queue.append(seconds)
        scheduled += seconds
    }

    mutating func finish(at now: TimeInterval) {
        guard !queue.isEmpty else { return }
        played += queue.removeFirst()
        startedAt = queue.isEmpty ? nil : now
    }

    func position(at now: TimeInterval) -> TimeInterval {
        guard let startedAt, let first = queue.first else { return played }
        return played + min(max(0, now - startedAt), first)
    }
}

public struct SonioxPlaybackQueue: Equatable, Sendable {
    public struct Chunk: Equatable, Sendable {
        public var stream: String
        public var pcm: Data

        public init(_ stream: String, _ pcm: Data) {
            self.stream = stream
            self.pcm = pcm
        }
    }

    private var order: [String] = []
    private var held: [String: [Data]] = [:]
    private var ended: Set<String> = []

    public init() {}

    public var isEmpty: Bool { order.isEmpty }

    public mutating func open(_ stream: String) {
        order.append(stream)
    }

    public mutating func audio(_ stream: String, _ pcm: Data) -> [Chunk] {
        guard order.contains(stream), !ended.contains(stream), !pcm.isEmpty else { return [] }
        if order.first == stream { return [Chunk(stream, pcm)] }
        held[stream, default: []].append(pcm)
        return []
    }

    public mutating func end(_ stream: String) -> [Chunk] {
        guard order.contains(stream) else { return [] }
        ended.insert(stream)
        var ready: [Chunk] = []
        while let head = order.first, ended.contains(head) {
            order.removeFirst()
            ended.remove(head)
            held[head] = nil
            if let next = order.first {
                ready += (held.removeValue(forKey: next) ?? []).map { Chunk(next, $0) }
            }
        }
        return ready
    }

    public mutating func reset() {
        order = []
        held = [:]
        ended = []
    }
}
