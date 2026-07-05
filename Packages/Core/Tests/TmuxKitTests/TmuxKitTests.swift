import Testing
@testable import TmuxKit

@Test func listWindowsCommandUsesPipeFormat() {
    #expect(Tmux.listWindowsCommand(session: "claude")
        == "tmux list-windows -t 'claude' -F '#{window_index}|#{window_name}|#{window_active}'")
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
        == "tmux list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}'")
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
        == "tmux attach-session -t 'claude' \\; select-window -t 3")
}

@Test func attachCommandWithoutWindow() {
    #expect(Tmux.attachCommand(session: "claude", windowIndex: nil)
        == "tmux attach-session -t 'claude'")
}

@Test func sessionNameWithSingleQuoteIsEscaped() {
    #expect(Tmux.listWindowsCommand(session: "a'b")
        == "tmux list-windows -t 'a'\\''b' -F '#{window_index}|#{window_name}|#{window_active}'")
}
