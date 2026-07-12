import TmuxKit

public struct TabStatusResolver: Sendable {
    private var lastText: [String: String] = [:]
    private var lastStatus: [String: AgentStatus] = [:]
    private var blankStreak: [String: Int] = [:]

    public init() {}

    public mutating func resolve(key: String, text: String, userTyped: Bool = false) -> AgentStatus? {
        guard let detected = AgentStatus.detectAgent(text) else {
            let streak = blankStreak[key, default: 0]
            blankStreak[key] = streak + 1
            if streak == 0, let held = lastStatus[key] {
                return held
            }
            lastText[key] = nil
            lastStatus[key] = nil
            return nil
        }
        blankStreak[key] = 0
        let previous = lastText[key]
        lastText[key] = text
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
        blankStreak[key] = nil
    }
}
