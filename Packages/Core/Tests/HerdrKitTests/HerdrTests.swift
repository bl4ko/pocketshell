import HerdrKit
import Testing

@Test func parsesRunningAndStoppedSessions() {
    let output = """
        {"sessions":[
          {"default":true,"name":"default","running":false,"session_dir":"/home/me/.config/herdr"},
          {"default":false,"name":"work","running":true,"socket_path":"/tmp/herdr.sock"}
        ]}
        """

    #expect(
        Herdr.parseSessions(output) == [
            HerdrSession(name: "default", isDefault: true, running: false),
            HerdrSession(name: "work", isDefault: false, running: true),
        ])
    #expect(Herdr.parseSessions("not json").isEmpty)
}

@Test func parsesSemanticAgentSnapshotAndIgnoresUnknownFields() throws {
    let output = """
        {"id":"cli:api:snapshot","result":{"type":"session_snapshot","snapshot":{
          "version":"0.8.0","protocol":19,"focused_workspace_id":"w1",
          "workspaces":[{"workspace_id":"w1","label":"PocketShell","focused":true,"agent_status":"blocked","number":1}],
          "agents":[{"terminal_id":"term_1","pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"codex","display_agent":"Codex","title":"Needs approval","agent_status":"blocked","focused":true,"revision":2}],
          "panes":[],"tabs":[],"layouts":[]
        }}}
        """

    let snapshot = try #require(Herdr.parseSnapshot(output))
    #expect(snapshot.version == "0.8.0")
    #expect(snapshot.protocolVersion == 19)
    #expect(snapshot.focusedWorkspaceID == "w1")
    #expect(snapshot.workspaces.first?.label == "PocketShell")
    #expect(snapshot.agents.first?.status == .blocked)
    #expect(snapshot.agents.first?.displayAgent == "Codex")
}

@Test func mapsFutureAgentStatesToUnknown() throws {
    let output = """
        {"result":{"snapshot":{"version":"1.0","protocol":20,"workspaces":[],"agents":[
          {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent_status":"paused","focused":false}
        ]}}}
        """

    #expect(try #require(Herdr.parseSnapshot(output)).agents.first?.status == .unknown)
}

@Test func buildsQuotedCommandsForDefaultAndNamedSessions() {
    #expect(Herdr.listSessionsCommand().hasSuffix("herdr session list --json"))
    #expect(Herdr.attachCommand(session: "default").hasSuffix("herdr"))
    #expect(Herdr.attachCommand(session: "client's work").hasSuffix("herdr --session 'client'\\''s work'"))
    #expect(
        Herdr.focusWorkspaceCommand(session: "work", workspaceID: "w'1")
            .hasSuffix("herdr --session 'work' workspace focus 'w'\\''1'"))
}
