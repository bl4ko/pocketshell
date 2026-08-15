import Testing

@testable import MonitorKit

struct AgentApprovalTests {
    private let prompt = """
        Do you want to run rm -rf node_modules?
        ❯ 1. Yes
          2. Yes, and don't ask again
          3. No, and tell Claude what to do
        """

    @Test func approveSelectsTheFirstOption() {
        #expect(AgentApproval.keys(for: .approve, screen: prompt) == .init(text: "1", pressEnter: true))
    }

    @Test func denySendsEscape() {
        #expect(AgentApproval.keys(for: .deny, screen: prompt) == .init(text: "\u{1b}", pressEnter: false))
    }

    @Test func promptWithoutOptionsConfirmsWithEnter() {
        let screen = "Press Enter to confirm"
        #expect(AgentApproval.keys(for: .approve, screen: screen) == .init(text: "", pressEnter: true))
    }

    @Test func nothingIsSentOnceTheAgentMovedOn() {
        let screen = "Running tests… (12s · esc to interrupt)"
        #expect(AgentApproval.keys(for: .approve, screen: screen) == nil)
        #expect(AgentApproval.keys(for: .deny, screen: screen) == nil)
    }
}
