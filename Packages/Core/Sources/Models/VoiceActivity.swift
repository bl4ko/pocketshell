import Foundation

#if os(iOS) && !targetEnvironment(macCatalyst)
    import ActivityKit

    public struct VoiceActivityAttributes: ActivityAttributes, Sendable {
        public typealias ContentState = VoiceActivityState

        public var hostName: String

        public init(hostName: String) {
            self.hostName = hostName
        }
    }
#endif

public struct VoiceActivityState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case starting
        case listening
        case hearing
        case thinking
        case speaking
        case muted
        case paused
        case dictating

        public var label: String {
            switch self {
            case .starting: "Starting"
            case .listening: "Listening"
            case .hearing: "Hearing you"
            case .thinking: "Thinking"
            case .speaking: "Speaking"
            case .muted: "Muted"
            case .paused: "Paused"
            case .dictating: "Dictating"
            }
        }

        public var symbol: String {
            switch self {
            case .starting: "hourglass"
            case .listening: "ear"
            case .hearing: "mic.fill"
            case .thinking: "ellipsis"
            case .speaking: "speaker.wave.2.fill"
            case .muted: "mic.slash.fill"
            case .paused: "pause.fill"
            case .dictating: "square.and.pencil"
            }
        }
    }

    public var status: Status
    public var caption: String
    public var muted: Bool

    public init(status: Status, caption: String = "", muted: Bool = false) {
        self.status = status
        self.caption = caption
        self.muted = muted
    }

    public static let captionLimit = 140

    public static func line(_ text: String, limit: Int = captionLimit) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let tail = flat.suffix(limit)
        let cut = tail.firstIndex(of: " ").map { tail[tail.index(after: $0)...] } ?? tail
        return "…" + cut
    }
}
