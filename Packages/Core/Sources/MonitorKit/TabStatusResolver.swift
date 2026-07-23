import TmuxKit

public struct TabStatusResolver: Sendable {
    private var lastStatus: [String: AgentStatus] = [:]
    private var blankStreak: [String: Int] = [:]

    public init() {}

    public mutating func resolve(key: String, text: String, agentRunning: Bool? = nil) -> AgentStatus? {
        if let detected = AgentStatus.detectAgent(text) {
            blankStreak[key] = 0
            lastStatus[key] = detected
            return detected
        }

        if agentRunning == true {
            return lastStatus[key]
        }
        if agentRunning == false {
            forget(key: key)
            return nil
        }

        let streak = blankStreak[key, default: 0]
        blankStreak[key] = streak + 1
        if streak == 0 {
            return lastStatus[key]
        }
        forget(key: key)
        return nil
    }

    public mutating func forget(key: String) {
        lastStatus[key] = nil
        blankStreak[key] = nil
    }
}
