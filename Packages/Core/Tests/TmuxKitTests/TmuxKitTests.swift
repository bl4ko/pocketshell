import Testing
@testable import TmuxKit

@Test func listWindowsCommandUsesPipeFormat() {
    #expect(Tmux.listWindowsCommand(session: "claude")
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux list-windows -t 'claude' -F '#{window_index}|#{window_name}|#{window_active}'")
}

@Test func parseWindowsParsesIndexNameActive() {
    let output = """
    0|homeops-1|1
    1|homeops-2|0
    5|slo-1|0
    """
    let windows = Tmux.parseWindows(output)
    #expect(windows == [
        TmuxWindow(index: 0, name: "homeops-1", active: true),
        TmuxWindow(index: 1, name: "homeops-2", active: false),
        TmuxWindow(index: 5, name: "slo-1", active: false),
    ])
}

@Test func parseWindowsKeepsPipesInWindowName() {
    let windows = Tmux.parseWindows("2|weird|name|0")
    #expect(windows == [TmuxWindow(index: 2, name: "weird|name", active: false)])
}

@Test func parseWindowsSkipsMalformedLines() {
    let windows = Tmux.parseWindows("garbage\n1|ok|1\n\n")
    #expect(windows == [TmuxWindow(index: 1, name: "ok", active: true)])
}

@Test func listSessionsCommandUsesPipeFormat() {
    #expect(Tmux.listSessionsCommand()
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{session_group}'")
}

@Test func parseSessionsParsesNameWindowsAttachedGroup() {
    let sessions = Tmux.parseSessions("claude|5|1|\nother|1|0|other")
    #expect(sessions == [
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
    #expect(Tmux.consolidateGroups(sessions) == [
        TmuxSession(name: "agents", windows: 4, attached: true, group: "agents"),
        TmuxSession(name: "solo", windows: 1, attached: false, group: nil),
    ])
}

@Test func consolidateGroupsKeepsCloneWhenBaseGone() {
    let sessions = [
        TmuxSession(name: "agents-psh-a1b2", windows: 4, attached: true, group: "agents"),
    ]
    #expect(Tmux.consolidateGroups(sessions) == [
        TmuxSession(name: "agents-psh-a1b2", windows: 4, attached: true, group: "agents"),
    ])
}

@Test func attachCommandWithWindow() {
    #expect(Tmux.attachCommand(session: "claude", windowIndex: 3, clientTag: "ab12cd")
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux -u new-session -t 'claude' -s 'claude-psh-ab12cd' \\; set-option destroy-unattached on \\; select-window -t 3")
}

@Test func attachCommandWithoutWindow() {
    #expect(Tmux.attachCommand(session: "claude", windowIndex: nil, clientTag: "ab12cd")
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux -u new-session -t 'claude' -s 'claude-psh-ab12cd' \\; set-option destroy-unattached on")
}

@Test func sessionNameWithSingleQuoteIsEscaped() {
    #expect(Tmux.listWindowsCommand(session: "a'b")
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux list-windows -t 'a'\\''b' -F '#{window_index}|#{window_name}|#{window_active}'")
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
    #expect(Tmux.newSessionCommand(name: "agents")
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux new-session -d -s 'agents'")
}

@Test func windowAndSplitKeysUsePrefix() {
    #expect(Tmux.newWindowKeys == "\u{02}c")
    #expect(Tmux.splitHorizontalKeys == "\u{02}%")
    #expect(Tmux.splitVerticalKeys == "\u{02}\"")
}

@Test func parseSessionsAcceptsMultipleAttachedClients() {
    let sessions = Tmux.parseSessions("agents|4|2|\nidle|1|0|")
    #expect(sessions == [
        TmuxSession(name: "agents", windows: 4, attached: true, group: nil),
        TmuxSession(name: "idle", windows: 1, attached: false, group: nil),
    ])
}

@Test func renameWindowCommandTargetsSessionAndIndex() {
    #expect(Tmux.renameWindowCommand(session: "agents", windowIndex: 2, name: "new name")
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux rename-window -t 'agents':2 'new name'")
}

@Test func renameSessionCommandQuotesBothNames() {
    #expect(Tmux.renameSessionCommand(from: "agents", to: "work")
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux rename-session -t 'agents' 'work'")
}

@Test func killSessionCommandTargetsName() {
    #expect(Tmux.killSessionCommand(name: "agents")
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux kill-session -t 'agents'")
}

@Test func killWindowCommandTargetsSessionAndIndex() {
    #expect(Tmux.killWindowCommand(session: "agents", windowIndex: 2)
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux kill-window -t 'agents':2")
}

@Test func cloneNameMatchesAttachCommand() {
    #expect(Tmux.cloneName(session: "claude", clientTag: "ab12cd") == "claude-psh-ab12cd")
    #expect(Tmux.attachCommand(session: "claude", windowIndex: nil, clientTag: "ab12cd")
        .contains("-s 'claude-psh-ab12cd'"))
}

@Test func currentWindowCommandTargetsClone() {
    #expect(Tmux.currentWindowCommand(clone: "claude-psh-ab12cd")
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux display-message -p -t 'claude-psh-ab12cd' '#{window_index}'")
}

@Test func parseCurrentWindowReadsIndex() {
    #expect(Tmux.parseCurrentWindow("3\n") == 3)
    #expect(Tmux.parseCurrentWindow("") == nil)
    #expect(Tmux.parseCurrentWindow("can't find session\n") == nil)
}
