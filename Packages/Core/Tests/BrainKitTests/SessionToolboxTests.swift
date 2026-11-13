import Foundation
import Models
import MonitorKit
import Testing

@testable import BrainKit

@MainActor
private final class Harness {
    var commands: [String] = []
    var replies: [(match: String, output: String)] = []
    var tabs: [AppTab] = [
        AppTab(
            id: "t1", label: "api", backend: .tmux(session: "work", windowIndex: 2, windowID: "@7"), isCurrent: true),
        AppTab(id: "t2", label: "2", backend: .shell),
        AppTab(id: "t3", label: "herdr", backend: .herdr(session: "default", workspaceID: "w1")),
    ]
    var focused: [BrainSession.Place] = []
    var typed: [(String, String)] = []
    var renamed: [(String, String)] = []
    var closed: [String] = []
    var newTabs: [(String?, String?)] = []
    var sessionRenames: [(String, String)] = []
    var skipped = 0
    var screens: [String: String] = ["t2": "$ ls\u{0}\u{0}src\n$ \n\n"]
    var snippets: [Snippet] = []
    let list: String
    lazy var toolbox: AgentToolbox = makeToolbox()

    init() throws {
        list = try fixture("list-sessions.txt")
    }

    func makeToolbox() -> AgentToolbox {
        let toolbox = AgentToolbox(
            io: .init(
                exec: { [unowned self] in self.exec($0) }, focus: { _ in true },
                current: { [unowned self] in
                    switch self.tabs.first(where: \.isCurrent)?.backend {
                    case .tmux(let session, let index, let id):
                        CurrentTarget(tmuxSession: session, windowIndex: index, windowID: id)
                    case .herdr(let session, _): CurrentTarget(herdrSession: session)
                    default: nil
                    }
                }))
        toolbox.sessions = SessionToolbox(
            io: .init(
                exec: { [unowned self] in self.exec($0) },
                tabs: { [unowned self] in self.tabs },
                screen: { [unowned self] in self.screens[$0] },
                type: { [unowned self] in
                    self.typed.append(($0, $1))
                    return true
                },
                focus: { [unowned self] in
                    self.focused.append($0)
                    return true
                },
                newTab: { [unowned self] in
                    self.newTabs.append(($0, $1))
                    return true
                },
                renameTab: { [unowned self] in
                    self.renamed.append(($0, $1))
                    return true
                },
                closeTab: { [unowned self] in
                    self.closed.append($0)
                    return true
                },
                tmuxSessionRenamed: { [unowned self] in self.sessionRenames.append(($0, $1)) },
                unseen: { session, index in session == "ops" && index == 0 },
                skipPermissions: { [unowned self] in
                    self.skipped += 1
                    return nil
                },
                snippets: { [unowned self] in self.snippets }))
        return toolbox
    }

    func exec(_ command: String) -> String? {
        commands.append(command)
        if command.contains("list-panes -a") { return list }
        if let reply = replies.first(where: { command.contains($0.match) }) { return reply.output }
        if command.contains("@@psh-exit") { return "\n@@psh-exit:0@@" }
        return ""
    }

    func call(_ name: String, _ arguments: String = "{}") async -> String {
        await toolbox.call(ToolCall(id: "c", name: name, arguments: arguments))
    }

    func confirm() async -> String? {
        guard case .confirmed(let pending) = toolbox.gate.resolve(userTurn: "yes") else { return nil }
        return await toolbox.perform(pending.action)
    }

    var sent: [String] { commands.filter { !$0.contains("list-panes -a") } }
}

private func object(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

@Test func hostLayoutKeepsActivePanesAndPrefersTheBaseSessionOverAClone() throws {
    let layout = HostLayout.parse(try fixture("list-sessions.txt"))
    #expect(layout.windows.map(\.windowID) == ["@9", "@1", "@4", "@7"])
    #expect(layout.windows.first { $0.windowID == "@4" }?.paneID == "%5")
    #expect(layout.windows.first { $0.windowID == "@7" }?.session == "work")
    #expect(layout.tmuxSessions == ["ops", "work"])
    #expect(layout.herdrSessions == ["default"])
    #expect(
        HostAgents.parse(try fixture("list-sessions.txt")).map(\.id) == [
            "tmux:%3", "herdr:default:w1:p3", "herdr:default:w2:p7",
        ])
}

@MainActor
@Test func listSessionsCoversTabsTmuxWindowsAndHerdrPanes() async throws {
    let harness = try Harness()
    let sessions = object(await harness.call("list_sessions"))["sessions"] as? [[String: Any]] ?? []
    let names = sessions.map { "\($0["kind"] ?? ""):\($0["name"] ?? "")" }
    #expect(
        names == [
            "tab:api", "tab:2", "tab:herdr", "tmux_session:ops", "tmux_window:backups", "tmux_session:work",
            "tmux_window:zsh", "tmux_window:build", "tmux_window:api", "herdr_workspace:infra", "herdr_tab:deploy",
            "herdr_pane:reviewer", "herdr_pane:server", "herdr_tab:logs", "herdr_pane:log",
            "herdr_workspace:pocketshell",
            "herdr_tab:1", "herdr_pane:claude",
        ])
    let api = sessions[0]
    #expect(api["status"] as? String == "busy")
    #expect(api["agent"] as? String == "claude")
    #expect(api["current"] as? Bool == true)
    #expect(sessions.first { $0["name"] as? String == "build" }?["running"] as? String == "npm")
    #expect(sessions.first { $0["name"] as? String == "backups" }?["unseen_finished"] as? Bool == true)
    #expect(sessions.first { $0["name"] as? String == "claude" }?["status"] as? String == "done")
    #expect(sessions.first { $0["name"] as? String == "server" }?["status"] == nil)
    #expect(
        sessions.first { $0["kind"] as? String == "tmux_window" && $0["name"] as? String == "api" }?["current"] as? Bool
            == true)
}

@MainActor
@Test func sessionSnapshotIsShortStableAndRidesWithTheAgentNote() async throws {
    let harness = try Harness()
    await harness.toolbox.listAgents()
    let note = try #require(harness.toolbox.snapshot)
    #expect(note.hasPrefix(AgentToolbox.snapshotPrefix))
    let sessions = try #require(note.split(separator: "\n").last.map(String.init))
    #expect(
        sessions
            == "[app: Sessions now: tab \"api\" (tmux work, claude, busy, current); tab \"2\" (shell); tab \"herdr\" (Herdr, waiting); "
            + "tmux window \"backups\" in ops (unseen); tmux window \"zsh\" in work; tmux window \"build\" in work (busy); "
            + "Herdr tab \"deploy\" in infra (waiting); Herdr pane \"reviewer\" in infra tab deploy (codex, waiting); "
            + "Herdr pane \"server\" in infra tab deploy; Herdr tab \"logs\" in infra; Herdr tab \"1\" in pocketshell (done).]"
    )
    await harness.toolbox.listAgents()
    #expect(harness.toolbox.snapshot == note)
    harness.tabs[1].label = "backups"
    #expect(harness.toolbox.snapshot != note)
}

@Test func sessionNamesResolveFromSpeech() throws {
    let tabs = [
        AppTab(
            id: "t1", label: "api", backend: .tmux(session: "work", windowIndex: 2, windowID: "@7"), isCurrent: true),
        AppTab(id: "t2", label: "2", backend: .shell),
    ]
    let layout = HostLayout.parse(try fixture("list-sessions.txt"))
    let sessions = SessionCatalog.build(tabs: tabs, layout: layout, agents: [], unseen: { _, _ in false })
    func resolved(_ name: String?) -> String? {
        if case .found(let session) = SessionResolver.resolve(name, in: sessions) { return session.id }
        return nil
    }
    #expect(resolved(nil) == "tab:t1")
    #expect(resolved("this tab") == "tab:t1")
    #expect(resolved("this window") == "window:@7")
    #expect(resolved("the build tab") == "window:@4")
    #expect(resolved("build") == "window:@4")
    #expect(resolved("api") == "tab:t1")
    #expect(resolved("tmux window api") == "window:@7")
    #expect(resolved("tab 2") == "tab:t2")
    #expect(resolved("window 0 in ops") == "window:@9")
    #expect(resolved("the homelab one") == "window:@9")
    #expect(resolved("work session") == "tmux-session:work")
    #expect(resolved("the herdr pane server") == "herdr-pane:default:w1:p5")
    #expect(resolved("deploy") == "herdr-tab:default:w1:t1")
    #expect(resolved("infra workspace") == "herdr-workspace:default:w1")
    #expect(resolved("nonsense") == nil)
}

@MainActor
@Test func focusSessionShowsTabsWindowsAndHerdrPanes() async throws {
    let harness = try Harness()
    #expect(await harness.call("focus_session", #"{"target":"tab 2"}"#).contains("focused"))
    #expect(harness.focused.last == .tab(id: "t2", backend: .shell))
    _ = await harness.call("focus_session", #"{"target":"work session"}"#)
    #expect(harness.focused.last == .tmuxWindow(session: "work", windowIndex: 0, windowID: "@1", paneID: "%1"))
    _ = await harness.call("focus_session", #"{"target":"server pane"}"#)
    #expect(harness.focused.last == .herdrPane(session: "default", workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p5"))
    #expect(harness.sent.last?.contains("pane zoom 'w1:p5' --on && ") == true)
    _ = await harness.call("focus_session", #"{"target":"logs"}"#)
    #expect(harness.sent.last?.hasSuffix("tab focus 'w1:t2'") == true)
}

@MainActor
@Test func readScreenReadsShellsWindowsAndHerdrPanes() async throws {
    let harness = try Harness()
    harness.replies = [("capture-pane -p -t '%5'", "> web@1.0 build\nvite building…\n\n\n")]
    let shell = object(await harness.call("read_screen", #"{"target":"tab 2"}"#))
    #expect(shell["screen"] as? String == "$ ls  src\n$")
    let build = object(await harness.call("read_screen", #"{"target":"build"}"#))
    #expect(build["screen"] as? String == "> web@1.0 build\nvite building…")
    #expect(build["status"] as? String == "busy")
    _ = await harness.call("read_screen", #"{"target":"logs"}"#)
    #expect(harness.sent.last?.hasSuffix("pane read 'w1:p6' --source visible") == true)
    _ = await harness.call("read_screen", #"{"target":"herdr"}"#)
    #expect(harness.sent.last?.hasSuffix("pane read 'w1:p3' --source visible") == true)
    #expect(SessionCommands.cleanScreen(String(repeating: "x\n", count: 100), lines: 3) == "x\nx\nx")
}

@MainActor
@Test func sendTextTypesIntoIdleTargetsAndAsksFirstForBusyOrRiskyOnes() async throws {
    let harness = try Harness()
    #expect(await harness.call("send_text", #"{"target":"tab 2","text":"ls -la","enter":true}"#).contains("typed"))
    #expect(harness.typed.last! == ("t2", "ls -la\r"))

    let held = await harness.call("send_text", #"{"target":"build","text":"q"}"#)
    #expect(held.contains("needs_confirmation"))
    #expect(!harness.sent.contains { $0.contains("send-keys") })
    #expect(await harness.confirm()?.contains("typed") == true)
    #expect(harness.sent.last?.contains("send-keys -t '%5' -l -- 'q'") == true)

    #expect(
        await harness.call("send_text", #"{"target":"zsh","text":"git push --force"}"#).contains("needs_confirmation"))
    harness.toolbox.gate.cancel()

    _ = await harness.call("send_text", #"{"target":"logs","text":"tail -f syslog","enter":true}"#)
    #expect(harness.sent.last?.contains("pane send-text 'w1:p6' 'tail -f syslog' && ") == true)
    #expect(harness.sent.last?.contains("pane send-keys 'w1:p6' enter") == true)
}

@MainActor
@Test func sendKeyReachesAnyTargetWithTheNewKeys() async throws {
    let harness = try Harness()
    _ = await harness.call("send_key", #"{"target":"zsh","key":"tab"}"#)
    #expect(harness.sent.last?.contains("send-keys -t '%1' Tab") == true)
    _ = await harness.call("send_key", #"{"key":"shift_tab","target":"server"}"#)
    #expect(harness.sent.last?.contains("pane send-keys 'w1:p5' shift+tab") == true)
    _ = await harness.call("send_key", #"{"key":"up","target":"tab 2"}"#)
    #expect(harness.typed.last! == ("t2", "\u{1b}[A"))
    _ = await harness.call("send_key", #"{"key":"down"}"#)
    #expect(harness.sent.last?.contains("send-keys -t '%3' Down") == true)

    #expect(await harness.call("send_key", #"{"key":"ctrl_d","target":"zsh"}"#).contains("needs_confirmation"))
    #expect(await harness.confirm()?.contains("ctrl_d") == true)
    #expect(harness.sent.last?.contains("send-keys -t '%1' C-d") == true)
    #expect(await harness.call("send_key", #"{"key":"esc","target":"api"}"#).contains("Should I interrupt"))
    harness.toolbox.gate.cancel()
    #expect(await harness.call("send_key", #"{"key":"esc","target":"zsh"}"#).contains("\"key\":\"esc\""))
}

@MainActor
@Test func newSessionOpensTheSameKindAsTheCurrentTabInANamedFolder() async throws {
    let harness = try Harness()
    harness.replies = [("new-window", "work|3|@12|%20\n\n@@psh-exit:0@@")]
    let result = object(await harness.call("new_session", #"{"directory":"homelab","name":"lab"}"#))
    #expect(result["opened"] as? String == "tmux_window")
    #expect(result["directory"] as? String == "/home/dev/homelab")
    let command = try #require(harness.sent.last)
    #expect(command.contains("new-window -t 'work' -c '/home/dev/homelab' -n 'lab' -P -F"))
    #expect(!command.contains("send-keys"))
    #expect(harness.focused.last == .tmuxWindow(session: "work", windowIndex: 3, windowID: "@12", paneID: "%20"))

    #expect(
        await harness.call("new_session", #"{"kind":"tmux_window","agent":"claude"}"#).contains(
            "Should I start a new Claude session?"))
    #expect(harness.sent.last == command)
    _ = await harness.confirm()
    #expect(harness.sent.last?.contains("send-keys -t \"$p\" -l -- claude") == true)

    _ = await harness.call("new_session", #"{"kind":"shell_tab","directory":"/srv/data"}"#)
    #expect(harness.newTabs.last! == ("/srv/data", nil))
}

@MainActor
@Test func newSessionLooksUpUnknownFoldersOnTheHost() async throws {
    let harness = try Harness()
    harness.replies = [("find \"$HOME\"", "/home/dev/Projects/dotfiles\n")]
    _ = await harness.call("new_session", #"{"kind":"shell_tab","directory":"dotfiles"}"#)
    #expect(harness.newTabs.last! == ("/home/dev/Projects/dotfiles", nil))
    harness.replies = []
    let missing = await harness.call("new_session", #"{"kind":"shell_tab","directory":"nowhere"}"#)
    #expect(missing.contains("No folder named nowhere"))
    #expect(harness.newTabs.count == 1)
}

@MainActor
@Test func newSessionOpensHerdrTabsSplitsAndAgents() async throws {
    let harness = try Harness()
    harness.replies = [
        ("tab create", #"{"result":{"root_pane":{"pane_id":"w1:p9"}}}"#),
        ("pane split", #"{"result":{"pane":{"pane_id":"w1:p10"}}}"#),
        ("agent start", #"{"error":{"code":"agent_not_ready","message":"blocked"}}"#),
    ]
    let tab = await harness.call("new_session", #"{"kind":"herdr_tab","in":"infra","name":"tests"}"#)
    #expect(tab.contains("herdr_tab"))
    #expect(harness.sent.last?.contains("tab create --workspace 'w1' --label 'tests' --focus") == true)
    #expect(harness.focused.last == .herdrPane(session: "default", workspaceID: "w1", tabID: "", paneID: "w1:p9"))

    _ = await harness.call("new_session", #"{"kind":"herdr_split","in":"server","name":"watch"}"#)
    #expect(harness.sent.contains { $0.contains("pane split 'w1:p5' --direction right --focus") })
    #expect(harness.sent.last?.contains("pane rename 'w1:p10' 'watch'") == true)

    #expect(
        await harness.call("new_session", #"{"kind":"herdr_tab","agent":"codex","in":"pocketshell"}"#).contains(
            "needs_confirmation"))
    let started = await harness.confirm()
    #expect(started?.contains("\"started\":\"Codex\"") == true)
    #expect(harness.sent.contains { $0.contains("tab create --workspace 'w2'") })
    #expect(harness.sent.last?.contains("agent start 'codex' --kind 'codex' --pane 'w1:p9'") == true)
}

@MainActor
@Test func startAgentUsesHerdrWhenTheCurrentTabIsHerdr() async throws {
    let harness = try Harness()
    harness.tabs = harness.tabs.map { tab in
        var tab = tab
        tab.isCurrent = tab.id == "t3"
        return tab
    }
    harness.replies = [("tab create", #"{"result":{"root_pane":{"pane_id":"w1:p9"}}}"#)]
    #expect(await harness.call("start_agent", #"{"kind":"claude"}"#).contains("needs_confirmation"))
    _ = await harness.confirm()
    #expect(harness.sent.contains { $0.contains("herdr tab create --workspace 'w1' --focus") })
    #expect(harness.sent.last?.contains("agent start 'claude' --kind 'claude' --pane 'w1:p9'") == true)
    #expect(!harness.sent.contains { $0.contains("new-window") })
}

@MainActor
@Test func renameUsesTheTabLabelOrTheRealTmuxAndHerdrNames() async throws {
    let harness = try Harness()
    #expect(await harness.call("rename", #"{"name":"backups"}"#).contains("renamed"))
    #expect(harness.renamed.last! == ("t1", "backups"))
    _ = await harness.call("rename", #"{"target":"build","name":"web build"}"#)
    #expect(harness.sent.last?.contains("rename-window -t '@4' 'web build'") == true)
    _ = await harness.call("rename", #"{"target":"ops session","name":"homelab"}"#)
    #expect(harness.sent.last?.contains("rename-session -t 'ops' 'homelab'") == true)
    #expect(harness.sessionRenames.last! == ("ops", "homelab"))
    _ = await harness.call("rename", #"{"target":"logs","name":"syslog"}"#)
    #expect(harness.sent.last?.contains("tab rename 'w1:t2' 'syslog'") == true)
}

@MainActor
@Test func closeAlwaysAsksAndKillingAWindowClosesItsTab() async throws {
    let harness = try Harness()
    let held = await harness.call("close", #"{"target":"tab 2"}"#)
    #expect(held.contains("Should I close the 2 tab?"))
    #expect(harness.closed.isEmpty)
    _ = await harness.confirm()
    #expect(harness.closed == ["t2"])

    #expect(await harness.call("close", #"{"target":"tmux window api"}"#).contains("Its programs stop."))
    #expect(!harness.sent.contains { $0.contains("kill-window") })
    _ = await harness.confirm()
    #expect(harness.sent.last?.contains("kill-window -t '@7'") == true)
    #expect(harness.closed == ["t2", "t1"])

    #expect(await harness.call("close", #"{"target":"server pane"}"#).contains("needs_confirmation"))
    #expect(harness.toolbox.gate.resolve(userTurn: "no") != .none)
    #expect(!harness.sent.contains { $0.contains("pane close") })
}

@MainActor
@Test func skipPermissionsAlwaysAsksThenShowsTheAgentAndRunsTheAppFlow() async throws {
    let harness = try Harness()
    let held = await harness.call("skip_permissions", #"{"agent":"Claude in api"}"#)
    #expect(held.contains("Should I turn off permission prompts in the api tab"))
    #expect(harness.skipped == 0)
    #expect(await harness.confirm()?.contains("skipped_permissions") == true)
    #expect(harness.focused.last == .tab(id: "t1", backend: .tmux(session: "work", windowIndex: 2, windowID: "@7")))
    #expect(harness.skipped == 1)
    #expect(await harness.call("skip_permissions", #"{"agent":"reviewer"}"#).contains("give Codex full access"))
}

@MainActor
@Test func gitStatusReadsTheTargetFolder() async throws {
    let harness = try Harness()
    harness.replies = [
        (
            "rev-parse",
            "main\n@@psh-status@@\n M App/Foo.swift\n?? notes.txt\n@@psh-log@@\nabc1234\t2026-11-12\tfix: things"
        )
    ]
    let status = object(await harness.call("git_status", #"{"target":"build"}"#))
    #expect(harness.sent.last?.hasPrefix("cd '/home/dev/src/web' && git") == true)
    #expect(status["branch"] as? String == "main")
    #expect(status["changed_files"] as? Int == 2)
    #expect(status["files"] as? [String] == [" M App/Foo.swift", "?? notes.txt"])
    #expect(status["recent_commits"] as? [String] == ["2026-11-12 fix: things"])
    #expect(await harness.call("git_status", #"{"target":"tab 2"}"#).contains("is not known"))
}

@MainActor
@Test func runSnippetTypesSafeSnippetsAndAsksForRiskyOnes() async throws {
    let harness = try Harness()
    harness.snippets = [
        Snippet(name: "disk usage", command: "df -h"),
        Snippet(name: "deploy", command: "make deploy"),
        Snippet(name: "uptime", command: "uptime", runMode: .execAndShowOutput),
    ]
    _ = await harness.call("run_snippet", #"{"name":"disk","target":"tab 2"}"#)
    #expect(harness.typed.last! == ("t2", "df -h\r"))
    #expect(await harness.call("run_snippet", #"{"name":"deploy","target":"tab 2"}"#).contains("needs_confirmation"))
    #expect(harness.typed.count == 1)
    _ = await harness.confirm()
    #expect(harness.typed.last! == ("t2", "make deploy\r"))
    harness.replies = [("uptime", "10:00 up 3 days\n")]
    #expect(object(await harness.call("run_snippet", #"{"name":"uptime"}"#))["output"] as? String == "10:00 up 3 days")
    #expect(await harness.call("run_snippet", #"{"name":"missing"}"#).contains("disk usage, deploy, uptime"))
}

@MainActor
@Test func sessionToolsAreOfferedNextToTheAgentTools() {
    let names = (AgentToolbox.definitions + SessionToolbox.definitions).map(\.name)
    #expect(Set(names).count == names.count)
    #expect(
        SessionToolbox.toolNames == [
            "list_sessions", "focus_session", "read_screen", "send_text", "new_session", "rename", "close",
            "skip_permissions", "git_status", "run_snippet",
        ])
    #expect(BrainPrompt.system(hostName: "box").contains("[app: Sessions now: ...]"))
}

@MainActor
@Test func sendTextToAnAgentReadsBackWordsTheUserDidNotSay() async throws {
    let harness = try Harness()
    harness.toolbox.spokenTurns = ["tell the api agent to work in subagents"]
    let held = await harness.call(
        "send_text",
        #"{"target":"api","text":"PocketShell should also work with subagents for the user.","enter":true}"#)
    #expect(held.contains("I will send to"))
    #expect(held.contains("word for word"))
    harness.toolbox.gate.cancel()
    let sent = await harness.call("send_text", #"{"target":"api","text":"Work in subagents.","enter":true}"#)
    #expect(!sent.contains("I will send to"))
}
