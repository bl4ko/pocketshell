import Foundation

public enum SonioxSTT {
    public static let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    public static let model = "stt-rt-v6"
    public static let keepalive = #"{"type":"keepalive"}"#
    public static let finalize = #"{"type":"finalize"}"#

    public static func start(model: String = model, terms: [String]) -> String {
        var config: [String: Any] = [
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "language_hints": ["en"],
            "enable_endpoint_detection": true,
            "enable_agent_text_input": true,
        ]
        if !terms.isEmpty { config["context"] = ["terms": terms] }
        return SonioxJSON.string(config)
    }

    public static func agentText(_ text: String, end: Bool) -> String {
        SonioxJSON.string(["type": "agent_text", "text": text, "end_of_segment": end])
    }
}

public struct SonioxTranscript: Sendable {
    public enum Event: Equatable, Sendable {
        case partial(String)
        case phrase(String, startMs: Int?, endMs: Int?)
        case finished
        case failed(SonioxError)
    }

    private var final = ""
    private var firstStart: Int?
    private var lastEnd: Int?

    public init() {}

    public mutating func handle(_ message: SocketMessage) -> [Event] {
        guard let object = SonioxJSON.object(message) else { return [] }
        if let error = SonioxError.frame(object) { return [.failed(error)] }
        var events: [Event] = []
        var pending = ""
        var changed = false
        for token in object["tokens"] as? [[String: Any]] ?? [] {
            let text = token["text"] as? String ?? ""
            let isFinal = token["is_final"] as? Bool ?? false
            if text == "<end>" || text == "<fin>" {
                events.append(endpoint())
                pending = ""
                changed = false
                continue
            }
            changed = true
            if isFinal {
                if final.isEmpty, firstStart == nil { firstStart = token["start_ms"] as? Int }
                final += text
                if let end = token["end_ms"] as? Int { lastEnd = end }
            } else {
                pending += text
            }
        }
        if changed {
            events.append(.partial((final + pending).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if object["finished"] as? Bool == true { events.append(.finished) }
        return events
    }

    private mutating func endpoint() -> Event {
        let text = final.trimmingCharacters(in: .whitespacesAndNewlines)
        let event: Event = text.isEmpty ? .partial("") : .phrase(text, startMs: firstStart, endMs: lastEnd)
        final = ""
        firstStart = nil
        lastEnd = nil
        return event
    }
}
