import TmuxKit

public struct TabStatusResolver: Sendable {
    private var lastText: [String: String] = [:]

    public init() {}

    public mutating func resolve(key: String, text: String) -> AgentStatus? {
        let previous = lastText[key]
        lastText[key] = text
        guard let detected = AgentStatus.detectAgent(text) else { return nil }
        guard let previous else { return detected }
        if detected == .waiting { return .waiting }
        return previous != text ? .busy : .idle
    }

    public mutating func forget(key: String) {
        lastText[key] = nil
    }
}
