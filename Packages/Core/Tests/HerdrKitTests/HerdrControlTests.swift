import Foundation
import HerdrKit
import Testing

private let herdr = "PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH:$HOME/.local/bin\" herdr --session 'work'"

private func fixtureSnapshot() throws -> HerdrSnapshot {
    let url = try #require(Bundle.module.url(forResource: "snapshot", withExtension: "json", subdirectory: "Fixtures"))
    return try #require(Herdr.parseSnapshot(String(decoding: try Data(contentsOf: url), as: UTF8.self)))
}

@Test func outlinesWorkspacesTabsAndPanesFromARealSnapshot() throws {
    let outline = HerdrOutline(try fixtureSnapshot())

    #expect(outline.workspaces.map(\.label) == ["~", "api2", "repo"])
    #expect(outline.workspaces.map(\.status) == [.blocked, .idle, .done])
    #expect(outline.workspaces.map(\.isGitRepository) == [false, false, true])
    #expect(outline.focusedWorkspace?.workspaceID == "w1")
    let home = try #require(outline.workspaces.first)
    #expect(home.tabs.map(\.label) == ["1", "build"])
    #expect(home.tabs.map(\.focused) == [true, false])
    #expect(home.tabs.map(\.zoomed) == [true, false])
    #expect(home.tabs[0].status == .blocked)
    #expect(home.tabs[1].status == nil)

    let split = home.tabs[0].panes
    #expect(split.map(\.paneID) == ["w1:p1", "w1:p3"])
    #expect(split.map(\.title) == ["main", "reviewer"])
    #expect(split.map(\.detail) == ["claude · /Users/dev", "codex · /Users/dev"])
    #expect(split.map(\.status) == [.working, .blocked])
    #expect(split.map(\.focused) == [true, false])

    let shell = try #require(home.tabs[1].panes.first)
    #expect(shell.title == "dev")
    #expect(shell.status == nil)
    #expect(outline.workspaces[2].tabs.first?.panes.first.map { [$0.title, $0.detail] } == ["claude", "…/src/repo"])
    #expect(outline.needingInput.map(\.paneID) == ["w1:p3"])
    #expect(outline.focusedPane?.paneID == "w1:p1")
    #expect(outline.tab(containing: "w1:p3")?.tabID == "w1:t1")
}

@Test func outlinesOlderSnapshotsWithoutPanesFromTheirAgents() throws {
    let output = """
        {"result":{"snapshot":{"version":"0.8.0","protocol":19,"focused_workspace_id":"w1",
          "workspaces":[{"workspace_id":"w1","label":"app","focused":true,"agent_status":"working","number":1}],
          "agents":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","agent":"claude","agent_status":"working","focused":true}]
        }}}
        """
    let outline = HerdrOutline(try #require(Herdr.parseSnapshot(output)))

    #expect(outline.workspaces.first?.tabs.map(\.label) == ["t1"])
    #expect(outline.workspaces.first?.tabs.first?.panes.map(\.title) == ["claude"])
    #expect(outline.workspaces.first?.tabs.first?.status == .working)
    #expect(outline.focusedPaneID == "w1:p1")
}

@Test func focusesAgentsTabsAndPlainSplitPanesWithoutLeavingThemZoomed() throws {
    var snapshot = try fixtureSnapshot()

    #expect(
        Herdr.focusCommand(session: "work", paneID: "w1:p3", in: snapshot)
            == "\(herdr) agent focus 'w1:p3' || \(herdr) tab focus 'w1:t1'")
    #expect(Herdr.focusCommand(session: "work", paneID: "w1:p2", in: snapshot) == "\(herdr) tab focus 'w1:t2'")

    snapshot.agents.removeAll { $0.paneID == "w1:p3" }
    snapshot.panes = snapshot.panes?.map {
        var pane = $0
        if pane.paneID == "w1:p3" { pane.agent = nil }
        return pane
    }
    #expect(Herdr.focusCommand(session: "work", paneID: "w1:p3", in: snapshot) == "\(herdr) pane zoom 'w1:p3' --on")

    snapshot.layouts = snapshot.layouts?.map {
        var layout = $0
        layout.zoomed = false
        return layout
    }
    #expect(
        Herdr.focusCommand(session: "work", paneID: "w1:p3", in: snapshot)
            == "\(herdr) pane zoom 'w1:p3' --on && \(herdr) pane zoom 'w1:p3' --off")
}

@Test func zoomsOnlyTheFocusedPaneOfAnUnzoomedSplitAndUndoesItsOwnZoom() throws {
    var snapshot = try fixtureSnapshot()
    #expect(Herdr.zoomTarget(in: snapshot) == nil)
    #expect(
        Herdr.unzoomCommands(session: "work", tabIDs: ["w1:t1", "w2:t1"], in: snapshot)
            == ["\(herdr) pane zoom 'w1:p1' --off"])

    snapshot.layouts = snapshot.layouts?.map {
        var layout = $0
        layout.zoomed = false
        return layout
    }
    let target = try #require(Herdr.zoomTarget(in: snapshot))
    #expect(target.paneID == "w1:p1")
    #expect(target.tabID == "w1:t1")
    #expect(Herdr.unzoomCommands(session: "work", tabIDs: ["w1:t1"], in: snapshot).isEmpty)

    snapshot.focusedPaneID = "w1:p2"
    #expect(Herdr.zoomTarget(in: snapshot) == nil)
}

@Test func buildsFocusedCreateCommandsThatReportErrorsAsOutput() {
    #expect(
        Herdr.createCommand(session: "work", item: .tab(workspaceID: "w1"), label: " docs ", cwd: "/srv/my app")
            == "\(herdr) tab create --workspace 'w1' --cwd '/srv/my app' --label 'docs' --focus 2>&1 || true")
    #expect(
        Herdr.createCommand(
            session: "work", item: .split(paneID: "w1:p1", direction: .down), label: "ignored", cwd: "/srv")
            == "\(herdr) pane split 'w1:p1' --direction down --cwd '/srv' --focus 2>&1 || true")
    #expect(
        Herdr.createCommand(session: "work", item: .workspace, label: "", cwd: "")
            == "\(herdr) workspace create --focus 2>&1 || true")
    #expect(
        Herdr.createCommand(
            session: "work", item: .worktree(workspaceID: "w3"), label: "fix", cwd: "/srv", branch: "fix/it's")
            == "\(herdr) worktree create --workspace 'w3' --branch 'fix/it'\\''s' --label 'fix' --focus 2>&1 || true")
    #expect(
        Herdr.startAgentCommand(session: "work", name: "claude-2", kind: "claude", paneID: "w2:p2")
            == "\(herdr) agent start 'claude-2' --kind 'claude' --pane 'w2:p2' 2>&1 || true")
}

@Test func readsCreatedPanesAndHerdrErrorsFromCommandOutput() {
    let tab = """
        {"id":"cli:tab:create","result":{"root_pane":{"agent_status":"unknown","cwd":"/Users/dev","focused":false,"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"},"tab":{"label":"build","tab_id":"w1:t2","workspace_id":"w1"},"type":"tab_created"}}
        """
    let split = """
        {"id":"cli:pane:split","result":{"pane":{"agent_status":"unknown","pane_id":"w1:p3","tab_id":"w1:t1","workspace_id":"w1"},"type":"pane_info"}}
        """
    let blocked = """
        {"error":{"code":"agent_not_ready","message":"agent claude-1 is blocked during startup and is not ready for prompts"},"id":"cli:agent:start"}
        """
    let missing = #"{"error":{"code":"tab_not_found","message":"tab w1:t9 not found"},"id":"cli:tab:close"}"#

    #expect(Herdr.parseActionResult(tab + "\n") == .done(paneID: "w1:p2"))
    #expect(Herdr.parseActionResult(split) == .done(paneID: "w1:p3"))
    #expect(Herdr.parseActionResult(#"{"id":"cli:pane:close","result":{"type":"ok"}}"#) == .done(paneID: nil))
    #expect(Herdr.parseActionResult(missing) == .failed(code: "tab_not_found", message: "tab w1:t9 not found"))
    #expect(Herdr.agentStarted(Herdr.parseActionResult(blocked)))
    #expect(!Herdr.agentStarted(Herdr.parseActionResult(missing)))
    #expect(
        Herdr.parseActionResult("zsh: command not found: herdr\n")
            == .failed(code: "unreadable", message: "zsh: command not found: herdr"))
    #expect(Herdr.parseActionResult("") == .failed(code: "unreadable", message: "Herdr returned nothing."))
}

@Test func namesNewAgentsUniquelyWithinHerdrsNameRules() {
    #expect(Herdr.agentName(kind: "claude", taken: []) == "claude")
    #expect(Herdr.agentName(kind: "claude", taken: ["claude"]) == "claude-2")
    #expect(Herdr.agentName(kind: "claude", taken: ["claude", "claude-2", "codex"]) == "claude-3")
    #expect(Herdr.agentName(kind: "Qwen Code", taken: []) == "qwencode")
    #expect(Herdr.agentName(kind: "9x", taken: []) == "agent")
    #expect(Herdr.agentKinds.first == "claude")
}

@Test func renamesAndClosesWorkspacesTabsAndPanes() {
    #expect(
        Herdr.renameCommand(session: "work", target: .workspace("w1"), label: "api")
            == "\(herdr) workspace rename 'w1' 'api' 2>&1 || true")
    #expect(
        Herdr.renameCommand(session: "work", target: .tab("w1:t1"), label: "it's")
            == "\(herdr) tab rename 'w1:t1' 'it'\\''s' 2>&1 || true")
    #expect(
        Herdr.renameCommand(session: "work", target: .pane("w1:p1"), label: " ")
            == "\(herdr) pane rename 'w1:p1' --clear 2>&1 || true")
    #expect(
        Herdr.closeCommand(session: "work", target: .pane("w1:p3")) == "\(herdr) pane close 'w1:p3' 2>&1 || true")
    #expect(Herdr.closeCommand(session: "work", target: .tab("w1:t2")) == "\(herdr) tab close 'w1:t2' 2>&1 || true")
    #expect(
        Herdr.closeCommand(session: "work", target: .workspace("w2"))
            == "\(herdr) workspace close 'w2' 2>&1 || true")
}

@Test func resolvesTheSidebarToggleFromHerdrKeyConfig() {
    #expect(Herdr.sidebarToggleKeys(config: "") == [0x02, 0x62])
    #expect(
        Herdr.sidebarToggleKeys(
            config: """
                [keys]
                # prefix = "ctrl+q"
                prefix = "ctrl+a"   # tmux habit
                toggle_sidebar = "prefix+s"

                [[keys.command]]
                key = "prefix+alt+g"
                prefix = "f12"
                """) == [0x01, 0x73])
    #expect(Herdr.sidebarToggleKeys(config: "[keys]\nprefix = \"esc\"\n") == [0x1b, 0x62])
    #expect(Herdr.sidebarToggleKeys(config: "[keys]\ntoggle_sidebar = \"\"\n") == nil)
    #expect(Herdr.sidebarToggleKeys(config: "[keys]\ntoggle_sidebar = \"ctrl+alt+b\"\n") == nil)
    #expect(Herdr.sidebarToggleKeys(config: "[keys]\nprefix = \"f12\"\n") == nil)
    #expect(Herdr.sidebarToggleKeys(config: "[ui]\nprefix = \"ctrl+a\"\n") == [0x02, 0x62])
}

@Test func detectsTheExpandedSidebarOnlyOnHerdrsDesktopLayout() {
    let desktop = """
         spaces                  │  1 Z      build    +
                                 │┌ codex ─────────────────┐
        """
    let compact = """
        1 ●│  1 Z      build    +
        2 ○│┌ codex ──────────────┐
        """
    let mobile = """
         ● ~                        tab 1 · 1/2 │        ●
         ◉ 1 blocked · 1 working · 1 idle       │ switch
        """

    #expect(Herdr.sidebarExpanded(screen: desktop))
    #expect(!Herdr.sidebarExpanded(screen: compact))
    #expect(!Herdr.sidebarExpanded(screen: mobile))
    #expect(!Herdr.sidebarExpanded(screen: "spaces are fine in a shell"))
    #expect(!Herdr.sidebarExpanded(screen: ""))
}
