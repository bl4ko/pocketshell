import Foundation
import Testing

@testable import BrainKit

let titleTabs = [
    AppTab(id: "t1", label: "claude", backend: .tmux(session: "dev", windowIndex: 1, windowID: "@2")),
    AppTab(id: "t2", label: "herdr", backend: .herdr(session: "default", workspaceID: "w2"), isCurrent: true),
    AppTab(id: "t3", label: "3", backend: .shell),
]

func titleTabsWith(currentID id: String) -> [AppTab] {
    titleTabs.map { tab in
        var tab = tab
        tab.isCurrent = tab.id == id
        return tab
    }
}

func titleCatalog(_ tabs: [AppTab]) throws -> [BrainSession] {
    let output = try fixture("list-titles.txt")
    return SessionCatalog.build(
        tabs: tabs, layout: HostLayout.parse(output), agents: HostAgents.parse(output), unseen: { _, _ in false })
}

func resolvedID(_ name: String, in sessions: [BrainSession]) -> String? {
    if case .found(let session) = SessionResolver.resolve(name, in: sessions) { return session.id }
    return nil
}

@Test func agentsAreNamedByTheirSessionTitle() throws {
    let output = try fixture("list-titles.txt")
    let agents = HostAgents.parse(output)
    #expect(agents.map(\.id) == ["tmux:%2", "tmux:%3", "herdr:default:w1:p1", "herdr:default:w2:p1"])
    #expect(agents.map(\.title) == ["CPAMC", "QBIT-FIX", "HW-PROXY | iris", "POCKETSHELL"])
    #expect(
        agents.map(\.spokenName) == ["Claude CPAMC", "Codex QBIT-FIX", "Claude HW-PROXY | iris", "Claude POCKETSHELL"])
    #expect(agents[1].name == "web|tools")
    #expect(HostLayout.paneTitles(output) == ["%1": "dev@box: ~", "%2": "CPAMC", "%3": "QBIT-FIX"])

    func agent(_ name: String) -> String? {
        if case .found(let agent) = AgentResolver.resolve(name, in: agents) { return agent.id }
        return nil
    }
    #expect(agent("cpamc") == "tmux:%2")
    #expect(agent("CPAMC") == "tmux:%2")
    #expect(agent("qbit fix") == "tmux:%3")
    #expect(agent("hw-proxy") == "herdr:default:w1:p1")
    #expect(agent("pocketshell") == "herdr:default:w2:p1")
    #expect(agent("codex") == "tmux:%3")
}

@Test func aClaudeSessionNameBeatsThePaneTitle() throws {
    let output = try fixture("list-titles.txt").replacingOccurrences(
        of: "@@psh-tmux:%2|5101|claude|dev|1|@2|claude@@\n",
        with: "@@psh-tmux:%2|5101|claude|dev|1|@2|claude@@\n@@psh-session@@\n{\"pid\":5101,\"name\":\"MY-NAME\"}\n")
    #expect(HostAgents.parse(output).first?.title == "MY-NAME")
}

@Test func titlesAndOldNamesBothResolve() throws {
    let sessions = try titleCatalog(titleTabs)
    #expect(resolvedID("cpamc", in: sessions) == "tab:t1")
    #expect(resolvedID("claude tab", in: sessions) == "tab:t1")
    #expect(resolvedID("QBIT-FIX", in: sessions) == "window:@3")
    #expect(resolvedID("web tools", in: sessions) == "window:@3")
    #expect(resolvedID("HW-PROXY | iris", in: sessions) == "herdr-tab:default:w1:t1")
    #expect(resolvedID("hw", in: sessions) == "herdr-tab:default:w1:t1")
    #expect(resolvedID("zsh", in: sessions) == "window:@1")
}

@Test func listSessionsGivesTheTitleAndTheOldName() throws {
    let summary = try titleCatalog(titleTabs).map(SessionCatalog.summary)
    let window = try #require(summary.first { $0["id"] as? String == "window:@3" })
    #expect(window["name"] as? String == "QBIT-FIX")
    #expect(window["aka"] as? String == "web|tools")
    #expect(window["number"] as? Int == 2)
}
