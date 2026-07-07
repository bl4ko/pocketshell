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
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}'")
}

@Test func parseSessionsParsesNameWindowsAttached() {
    let sessions = Tmux.parseSessions("claude|5|1\nother|1|0")
    #expect(sessions == [
        TmuxSession(name: "claude", windows: 5, attached: true),
        TmuxSession(name: "other", windows: 1, attached: false),
    ])
}

@Test func attachCommandWithWindow() {
    #expect(Tmux.attachCommand(session: "claude", windowIndex: 3)
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux -u attach-session -t 'claude' \\; select-window -t 3")
}

@Test func attachCommandWithoutWindow() {
    #expect(Tmux.attachCommand(session: "claude", windowIndex: nil)
        == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux -u attach-session -t 'claude'")
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

@Test func parseSessionsAcceptsMultipleAttachedClients() {
    let sessions = Tmux.parseSessions("agents|4|2\nidle|1|0")
    #expect(sessions == [
        TmuxSession(name: "agents", windows: 4, attached: true),
        TmuxSession(name: "idle", windows: 1, attached: false),
    ])
}
