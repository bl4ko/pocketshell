import Testing
@testable import TmuxKit

@Test func classifyBusyWhenEscToInterruptVisible() {
    let pane = """
    * Reticulating splines… (esc to interrupt)
    """
    #expect(AgentStatus.classify(pane) == .busy)
}

@Test func classifyWaitingOnPermissionPrompt() {
    let pane = """
    Do you want to make this edit to main.swift?
    > 1. Yes
      2. No
    """
    #expect(AgentStatus.classify(pane) == .waiting)
}

@Test func classifyIdleOtherwise() {
    #expect(AgentStatus.classify("$ ") == .idle)
    #expect(AgentStatus.classify("") == .idle)
}

@Test func busyWinsOverWaiting() {
    let pane = "Do you want tea?\nworking… (esc to interrupt)"
    #expect(AgentStatus.classify(pane) == .busy)
}

@Test func capturePanesCommandLoopsWindowsWithSentinel() {
    let cmd = Tmux.capturePanesCommand(session: "claude", lines: 6)
    #expect(cmd.contains("list-windows -t 'claude' -F '#{window_index}'"))
    #expect(cmd.contains("@@pane:$w@@"))
    #expect(cmd.contains("capture-pane -p -t 'claude':$w -S -6"))
}

@Test func parsePaneCapturesSplitsBySentinel() {
    let output = """
    @@pane:0@@
    line a
    line b
    @@pane:3@@
    $ echo hi
    hi
    """
    let captures = Tmux.parsePaneCaptures(output)
    #expect(captures[0] == "line a\nline b")
    #expect(captures[3] == "$ echo hi\nhi")
}

@Test func parsePaneCapturesTrimsTrailingBlankLines() {
    let output = "@@pane:1@@\ntext\n\n\n"
    #expect(Tmux.parsePaneCaptures(output) == [1: "text"])
}

@Test func parsePaneCapturesIgnoresLeadingGarbage() {
    let output = "noise\n@@pane:2@@\nok"
    #expect(Tmux.parsePaneCaptures(output) == [2: "ok"])
}
