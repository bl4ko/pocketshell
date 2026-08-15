import TmuxKit

public enum AgentApproval {
    public enum Choice: String, Sendable {
        case approve
        case deny
    }

    public struct Keys: Equatable, Sendable {
        public let text: String
        public let pressEnter: Bool
    }

    /// Keys that answer the prompt currently on screen, or nil when the pane
    /// no longer waits for input — the agent moved on and the answer would
    /// land in whatever came next.
    public static func keys(for choice: Choice, screen: String) -> Keys? {
        guard AgentStatus.classify(screen) == .waiting else { return nil }
        switch choice {
        case .approve:
            let options = AgentQuickReply.options(in: screen)
            return options.contains(1) ? Keys(text: "1", pressEnter: true) : Keys(text: "", pressEnter: true)
        case .deny:
            // Escape cancels in Claude Code and Codex; picking the last numbered
            // option risks hitting "yes, and do not ask again".
            return Keys(text: "\u{1b}", pressEnter: false)
        }
    }
}
