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
            "sample_rate": sampleRate,
        ])
    }

    public static func text(stream: String, _ text: String) -> String {
        SonioxJSON.string(["stream_id": stream, "text": text, "text_end": true])
    }

    public static func cancel(stream: String) -> String {
        SonioxJSON.string(["stream_id": stream, "cancel": true])
    }

    public enum Reply: Equatable, Sendable {
        case audio(stream: String, pcm: Data, end: Bool)
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
            return .audio(
                stream: stream, pcm: Data(base64Encoded: audio) ?? Data(), end: object["audio_end"] as? Bool ?? false)
        }
        if object["audio_end"] as? Bool == true { return .audio(stream: stream, pcm: Data(), end: true) }
        if object["terminated"] as? Bool == true { return .terminated(stream) }
        return .ignored
    }

    public static let modelsURL = URL(string: "https://api.soniox.com/v1/tts-models")!

    public static func fetchVoices(apiKey: String, session: URLSession = .shared) async -> [String] {
        var request = URLRequest(url: modelsURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }
        return ordered(voices(fromModels: data))
    }

    public static func ordered(_ fetched: [String]) -> [String] {
        guard !fetched.isEmpty else { return voices }
        let available = Set(fetched)
        let curated = voices.filter(available.contains)
        return curated + fetched.filter { !curated.contains($0) }.sorted()
    }

    public static func voices(fromModels data: Data, model: String = model) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let models = object["models"] as? [[String: Any]],
            let entry = models.first(where: { $0["id"] as? String == model })
        else { return [] }
        return (entry["voices"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
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
