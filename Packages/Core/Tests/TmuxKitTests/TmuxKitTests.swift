import Testing

@testable import TmuxKit
import Models

@Test func newWindowTargetsSession() {
    #expect(
        Tmux.newWindowCommand(session: "my work")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux new-window -t 'my work'"
    )
}

@Test func listWindowsCommandUsesPipeFormat() {
    #expect(
        Tmux.listWindowsCommand(session: "claude")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux list-windows -t 'claude' -F '#{window_index}|#{window_id}|#{window_active}|#{window_name}'"
    )
}

@Test func parseWindowsParsesIndexIDActiveName() {
    let output = """
        0|@7|1|homeops-1
        1|@1|0|homeops-2
        5|@31|0|slo-1
        """
    let windows = Tmux.parseWindows(output)
    #expect(
        windows == [
            TmuxWindow(index: 0, name: "homeops-1", active: true, windowID: "@7"),
            TmuxWindow(index: 1, name: "homeops-2", active: false, windowID: "@1"),
            TmuxWindow(index: 5, name: "slo-1", active: false, windowID: "@31"),
        ])
}

@Test func parseWindowsKeepsPipesInWindowName() {
    let windows = Tmux.parseWindows("2|@4|0|weird|name")
    #expect(windows == [TmuxWindow(index: 2, name: "weird|name", active: false, windowID: "@4")])
}

@Test func parseWindowsSkipsMalformedLines() {
    let windows = Tmux.parseWindows("garbage\n1|ok|1\n1|@2|1|ok\n\n")
    #expect(windows == [TmuxWindow(index: 1, name: "ok", active: true, windowID: "@2")])
}

@Test func listSessionsCommandUsesPipeFormat() {
    #expect(
        Tmux.listSessionsCommand()
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{session_group}'"
    )
}

@Test func diagnosticsCommandExcludesPaneContents() {
    let command = Tmux.diagnosticsCommand()
    #expect(command.contains("list-sessions"))
    #expect(command.contains("list-clients"))
    #expect(command.contains("list-panes -a"))
    #expect(!command.contains("capture-pane"))
}

@Test func parseSessionsParsesNameWindowsAttachedGroup() {
    let sessions = Tmux.parseSessions("claude|5|1|\nother|1|0|other")
    #expect(
        sessions == [
            TmuxSession(name: "claude", windows: 5, attached: true, group: nil),
            TmuxSession(name: "other", windows: 1, attached: false, group: "other"),
        ])
}

@Test func consolidateGroupsMergesClonesIntoBase() {
    let sessions = [
        TmuxSession(name: "agents", windows: 4, attached: false, group: "agents"),
        TmuxSession(name: "agents-psh-a1b2", windows: 4, attached: true, group: "agents"),
        TmuxSession(name: "solo", windows: 1, attached: false, group: nil),
    ]
    #expect(
        Tmux.consolidateGroups(sessions) == [
            TmuxSession(name: "agents", windows: 4, attached: true, group: "agents"),
            TmuxSession(name: "solo", windows: 1, attached: false, group: nil),
        ])
}

@Test func consolidateGroupsKeepsCloneWhenBaseGone() {
    let sessions = [
        TmuxSession(name: "agents-psh-a1b2", windows: 4, attached: true, group: "agents")
    ]
    #expect(
        Tmux.consolidateGroups(sessions) == [
            TmuxSession(name: "agents-psh-a1b2", windows: 4, attached: true, group: "agents")
        ])
}

@Test func staleStandaloneCloneResolvesToExistingBase() {
    let output = """
        homeops|5|0|homeops
        homeops-psh-226977d3|1|1|homeops-psh-226977d3
        """
    #expect(
        Tmux.consolidateGroups(Tmux.parseSessions(output)) == [
            TmuxSession(name: "homeops", windows: 5, attached: true, group: "homeops")
        ])
    #expect(
        Tmux.canonicalSessionMap(output, requested: ["homeops-psh-226977d3"])
            == ["homeops-psh-226977d3": "homeops"]
    )
}

@Test func consolidateGroupsPrefersRenamedSessionOverClone() {
    let sessions = [
        TmuxSession(name: "agents-psh-492f0b8f", windows: 6, attached: true, group: "agents"),
        TmuxSession(name: "homeops", windows: 6, attached: false, group: "agents"),
    ]
    #expect(
        Tmux.consolidateGroups(sessions) == [
            TmuxSession(name: "homeops", windows: 6, attached: true, group: "agents")
        ])
}

@Test func canonicalSessionNamesRemovesRequestedAliases() {
    let output = """
        agents-psh-a1b2|6|1|agents
        homeops|6|0|agents
        homeops-psh-c3d4|6|1|agents
        vibe-apps|2|1|corpus
        """
    #expect(
        Tmux.canonicalSessionNames(output, requested: ["agents", "homeops", "vibe-apps"])
            == ["homeops", "vibe-apps"]
    )
    #expect(
        Tmux.canonicalSessionMap(output, requested: ["agents", "homeops", "vibe-apps"])
            == ["agents": "homeops", "homeops": "homeops", "vibe-apps": "vibe-apps"]
    )
}

@Test func attachCommandWithWindow() {
    #expect(
        Tmux.attachCommand(session: "claude", windowIndex: 3, clientTag: "ab12cd")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux -u new-session -d -t 'claude' -s 'claude-psh-ab12cd' \\; select-window -t 'claude-psh-ab12cd':3 \\; attach-session -t 'claude-psh-ab12cd' \\; set-option -t 'claude-psh-ab12cd' destroy-unattached on \\; set-option -t 'claude-psh-ab12cd' status off"
    )
}

@Test func attachCommandPrefersWindowIDOverIndex() {
    let command = Tmux.attachCommand(session: "claude", windowIndex: 3, windowID: "@17", clientTag: "ab12cd")
    #expect(command.contains("select-window -t '@17'"))
    #expect(!command.contains("select-window -t 'claude-psh-ab12cd':3"))
}

@Test func attachCommandIgnoresMalformedWindowID() {
    let command = Tmux.attachCommand(session: "claude", windowIndex: 3, windowID: "17", clientTag: "ab12cd")
    #expect(command.contains("select-window -t 'claude-psh-ab12cd':3"))
}

@Test func attachCommandWithoutWindow() {
    #expect(
        Tmux.attachCommand(session: "claude", windowIndex: nil, clientTag: "ab12cd")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux -u new-session -d -t 'claude' -s 'claude-psh-ab12cd' \\; attach-session -t 'claude-psh-ab12cd' \\; set-option -t 'claude-psh-ab12cd' destroy-unattached on \\; set-option -t 'claude-psh-ab12cd' status off"
    )
}

@Test func attachCommandTargetsEveryOptionAtTheClone() {
    let parts = Tmux.attachCommand(session: "claude", windowIndex: 3, clientTag: "ab12cd")
        .components(separatedBy: " \\; ")
    for part in parts where part.contains("set-option") {
        #expect(part.contains("-t 'claude-psh-ab12cd'"))
    }
    let attach = parts.firstIndex { $0.hasPrefix("attach-session") }
    let firstOption = parts.firstIndex { $0.contains("set-option") }
    #expect(attach != nil && firstOption != nil && attach! < firstOption!)
}

@Test func cleanupClonesCommandSkipsAttachedAndUngroupedSessions() {
    let command = Tmux.cleanupClonesCommand()
    #expect(command.contains("*-psh-????????)"))
    #expect(command.contains("[ \"$a\" = 0 ]"))
    #expect(command.contains("[ -n \"$g\" ]"))
    #expect(command.contains("[ $((now - c)) -gt 60 ]"))
    #expect(command.contains("grep -Fxq \"${n%-psh-*}\""))
    #expect(command.contains("kill-session -t \"$n\""))
}

@Test func sessionNameWithSingleQuoteIsEscaped() {
    #expect(
        Tmux.listWindowsCommand(session: "a'b")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux list-windows -t 'a'\\''b' -F '#{window_index}|#{window_id}|#{window_active}|#{window_name}'"
    )
}

@Test func nextPaneKeysIsPrefixO() {
    #expect(Tmux.nextPaneKeys == "\u{02}o")
}

@Test func zoomPaneKeysIsPrefixZ() {
    #expect(Tmux.zoomPaneKeys == "\u{02}z")
}

@Test func windowCycleKeysUsePrefix() {
    #expect(Tmux.nextWindowKeys == "\u{02}n")
    #expect(Tmux.previousWindowKeys == "\u{02}p")
}

@Test func newSessionCommandCreatesDetachedSession() {
    #expect(
        Tmux.newSessionCommand(name: "agents")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux new-session -d -s 'agents'")
}

@Test func windowAndSplitKeysUsePrefix() {
    #expect(Tmux.newWindowKeys == "\u{02}c")
    #expect(Tmux.splitHorizontalKeys == "\u{02}%")
    #expect(Tmux.splitVerticalKeys == "\u{02}\"")
}

@Test func parseSessionsAcceptsMultipleAttachedClients() {
    let sessions = Tmux.parseSessions("agents|4|2|\nidle|1|0|")
    #expect(
        sessions == [
            TmuxSession(name: "agents", windows: 4, attached: true, group: nil),
            TmuxSession(name: "idle", windows: 1, attached: false, group: nil),
        ])
}

@Test func renameWindowCommandTargetsSessionAndIndex() {
    #expect(
        Tmux.renameWindowCommand(session: "agents", windowIndex: 2, name: "new name")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux rename-window -t 'agents':2 'new name'")
}

@Test func renameSessionCommandQuotesBothNames() {
    #expect(
        Tmux.renameSessionCommand(from: "agents", to: "work")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux rename-session -t 'agents' 'work'")
}

@Test func killSessionCommandTargetsName() {
    #expect(
        Tmux.killSessionCommand(name: "agents")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux kill-session -t 'agents'")
}

@Test func killWindowCommandTargetsSessionAndIndex() {
    #expect(
        Tmux.killWindowCommand(session: "agents", windowIndex: 2)
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux kill-window -t 'agents':2")
}

@Test func cloneNameDoesNotNestOnRestoredCloneNames() {
    #expect(Tmux.baseSessionName("vibe-apps") == "vibe-apps")
    #expect(Tmux.baseSessionName("vibe-apps-psh-a5fcd501") == "vibe-apps")
    #expect(Tmux.baseSessionName("vibe-apps-psh-4363b8ed-psh-12f81680-psh-2d7868e5") == "vibe-apps")
    #expect(Tmux.baseSessionName("my-psh-session") == "my-psh-session")
    #expect(
        Tmux.cloneName(session: "vibe-apps-psh-4363b8ed-psh-12f81680", clientTag: "0badf00d")
            == "vibe-apps-psh-0badf00d"
    )
    #expect(
        Tmux.attachCommand(session: "vibe-apps-psh-a5fcd501", windowIndex: nil, clientTag: "0badf00d")
            .contains("-t 'vibe-apps-psh-a5fcd501' -s 'vibe-apps-psh-0badf00d'")
    )
}

@Test func cloneNameMatchesAttachCommand() {
    #expect(Tmux.cloneName(session: "claude", clientTag: "ab12cd") == "claude-psh-ab12cd")
    #expect(
        Tmux.attachCommand(session: "claude", windowIndex: nil, clientTag: "ab12cd")
            .contains("-s 'claude-psh-ab12cd'"))
}

@Test func currentWindowCommandTargetsClone() {
    #expect(
        Tmux.currentWindowCommand(clone: "claude-psh-ab12cd")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux display-message -p -t 'claude-psh-ab12cd' '#{window_index}'"
    )
}

@Test func parseCurrentWindowReadsIndex() {
    #expect(Tmux.parseCurrentWindow("3\n") == 3)
    #expect(Tmux.parseCurrentWindow("") == nil)
    #expect(Tmux.parseCurrentWindow("can't find session\n") == nil)
}

@Test func reorderWindowsCommandSwapsDownward() {
    #expect(
        Tmux.reorderWindowsCommand(session: "agents", indexes: [0, 1, 2, 3, 4], fromOffset: 0, toOffset: 3)
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux swap-window -d -s 'agents':0 -t 'agents':1 \\; swap-window -d -s 'agents':1 -t 'agents':2"
    )
}

@Test func reorderWindowsCommandSwapsUpward() {
    #expect(
        Tmux.reorderWindowsCommand(session: "agents", indexes: [0, 2, 5], fromOffset: 2, toOffset: 0)
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux swap-window -d -s 'agents':5 -t 'agents':2 \\; swap-window -d -s 'agents':2 -t 'agents':0"
    )
}

@Test func reorderWindowsCommandNoopOrInvalidReturnsNil() {
    #expect(Tmux.reorderWindowsCommand(session: "agents", indexes: [0, 1, 2], fromOffset: 1, toOffset: 1) == nil)
    #expect(Tmux.reorderWindowsCommand(session: "agents", indexes: [0, 1, 2], fromOffset: 1, toOffset: 2) == nil)
    #expect(Tmux.reorderWindowsCommand(session: "agents", indexes: [0, 1, 2], fromOffset: 5, toOffset: 0) == nil)
    #expect(Tmux.reorderWindowsCommand(session: "agents", indexes: [0, 1, 2], fromOffset: 0, toOffset: 9) == nil)
}

@Test func capturePanesCommandCapturesVisibleOnly() {
    let command = Tmux.capturePanesCommand(session: "agents")
    #expect(!command.contains("-S -"))
    #expect(command.contains("capture-pane -p -t 'agents':$w"))
}

@Test func capturePaneSnapshotCommandQuotesTarget() {
    #expect(
        Tmux.capturePaneSnapshotCommand(target: "agents-psh-a'b")
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux display-message -p -t 'agents-psh-a'\\''b' '@@snapshot:#{window_index}|#{window_id}|#{pane_current_command}|#{window_name}@@' && PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux capture-pane -p -t 'agents-psh-a'\\''b'"
    )
}

@Test func parsePaneSnapshotSeparatesWindowCommandAndText() {
    #expect(
        Tmux.parsePaneSnapshot("@@snapshot:2|@9|codex|api|server@@\nhello\nctx: 14% used / 86% left\n")
            == TmuxPaneSnapshot(
                windowIndex: 2,
                windowName: "api|server",
                command: "codex",
                text: "hello\nctx: 14% used / 86% left\n",
                windowID: "@9"
            )
    )
    #expect(Tmux.parsePaneSnapshot("ordinary pane text") == nil)
    #expect(Tmux.parsePaneSnapshot("@@snapshot:2|api|server|codex@@\nhello") == nil)
}

@Test func interactiveShellDetectionUsesCommandBasename() {
    #expect(Tmux.isInteractiveShell("zsh"))
    #expect(Tmux.isInteractiveShell("/bin/-bash"))
    #expect(!Tmux.isInteractiveShell("codex"))
    #expect(!Tmux.isInteractiveShell("node"))
}

@Test func classifyIgnoresStaleSpinnerAboveTail() {
    let stale = "✻ Cooking… (39s · esc to interrupt)"
    let transcript = (1...20).map { "transcript line \($0)" }.joined(separator: "\n")
    let footer = "› \n▶▶ auto mode on (shift+tab to cycle)"
    #expect(AgentStatus.classify([stale, transcript, footer].joined(separator: "\n")) == .idle)
}

@Test func classifyDetectsSpinnerInTail() {
    #expect(AgentStatus.classify("transcript\n✻ Cooking… (39s · esc to interrupt)") == .busy)
}

@Test func classifyIgnoresTrailingBlankLines() {
    let text = "✻ Cooking… (39s · esc to interrupt)\n" + String(repeating: "\n", count: 30)
    #expect(AgentStatus.classify(text) == .busy)
}

@Test func orderSessionsAppliesSavedOrderUnknownLast() {
    let sessions = [
        TmuxSession(name: "a", windows: 1, attached: false, group: nil),
        TmuxSession(name: "b", windows: 1, attached: false, group: nil),
        TmuxSession(name: "c", windows: 1, attached: false, group: nil),
    ]
    #expect(Tmux.orderSessions(sessions, by: ["c", "a"]).map(\.name) == ["c", "a", "b"])
    #expect(Tmux.orderSessions(sessions, by: [String]()).map(\.name) == ["a", "b", "c"])
}

@Test func placeholderWindowNamesDetected() {
    #expect(Tmux.isPlaceholderWindowName("[tmux]"))
    #expect(Tmux.isPlaceholderWindowName("[dead]"))
    #expect(Tmux.isPlaceholderWindowName(""))
    #expect(!Tmux.isPlaceholderWindowName("homeassistant"))
    #expect(!Tmux.isPlaceholderWindowName("tmux"))
}

@Test func liveWindowNameUsesTerminalTitleOnlyForRunningApps() {
    #expect(Tmux.liveWindowName(terminalTitle: " new agent ", windowName: "old", agentRunning: true) == "new agent")
    #expect(Tmux.liveWindowName(terminalTitle: "stale", windowName: "shell", agentRunning: false) == "shell")
    #expect(Tmux.liveWindowName(terminalTitle: "[tmux]", windowName: "agent", agentRunning: true) == "agent")
}

@Test func windowDisplayNamePrefersSavedTabNameOverCopyModePlaceholder() {
    let window = TmuxWindow(index: 4, name: "[tmux]", active: false)
    let records = [
        TabRecord(name: "homeassistant", tmuxSession: "homeops", windowIndex: 4, windowName: "[tmux]")
    ]
    #expect(Tmux.windowDisplayName(window: window, session: "homeops", records: records) == "homeassistant")
    #expect(Tmux.windowDisplayName(window: window, session: "homeops", records: []) == "window 4")
    let named = TmuxWindow(index: 2, name: "vim", active: false)
    #expect(Tmux.windowDisplayName(window: named, session: "homeops", records: []) == "vim")
    let saved = [TabRecord(tmuxSession: "homeops", windowIndex: 2, windowName: "editor")]
    #expect(Tmux.windowDisplayName(window: named, session: "homeops", records: saved) == "editor")
}
