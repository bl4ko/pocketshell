import TmuxKit

public struct TabStatusResolver: Sendable {
    private var lastText: [String: String] = [:]
    private var lastStatus: [String: AgentStatus] = [:]

    public init() {}

    public mutating func resolve(key: String, text: String, userTyped: Bool = false) -> AgentStatus? {
        let previous = lastText[key]
        lastText[key] = text
        guard let detected = AgentStatus.detectAgent(text) else {
            lastStatus[key] = nil
            return nil
        }
        let status: AgentStatus
        if detected == .waiting {
            status = .waiting
        } else if previous == nil {
            status = detected
        } else if userTyped {
            status = lastStatus[key] ?? detected
        } else {
            status = previous != text ? .busy : .idle
        }
        lastStatus[key] = status
        return status
    }

    public mutating func forget(key: String) {
        lastText[key] = nil
        lastStatus[key] = nil
    }
}
