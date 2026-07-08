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

@Test func classifyBusyWhileCompacting() {
    #expect(AgentStatus.classify("· Compacting conversation… (21s)") == .busy)
}

@Test func classifyBusyForCodexCapitalEsc() {
    #expect(AgentStatus.classify("Working (7s • Esc to interrupt)") == .busy)
}

@Test func classifyBusyForSpinnerWithTimerParen() {
    #expect(AgentStatus.classify("✻ Waddling… (6m 14s · ↓ 22.7k tokens · almost done thinking)") == .busy)
}

@Test func classifyIdleForFinishedSpinnerLine() {
    #expect(AgentStatus.classify("✻ Baked for 12m 3s") == .idle)
}

@Test func classifyBusySpinnerInsideFullPane() {
    let pane = """
      … +53 lines (ctrl+o to expand)

    ✻ Waddling… (6m 14s · ↓ 22.7k tokens · almost done thinking)

    ● How is Claude doing this session? (optional)
      1: Bad    2: Fine   3: Good   0: Dismiss
      ctx: 12% used / 88% left  [Opus 4.8 (1M context)]
    """
    #expect(AgentStatus.classify(pane) == .busy)
}

@Test func classifyIdleForStatusLineParens() {
    let pane = """
    ❯ Yes recreate
      ctx: 9% used / 91% left  [Opus 4.8 (1M context)]
      ⏵⏵ auto mode on (shift+tab to cycle)
    """
    #expect(AgentStatus.classify(pane) == .idle)
}

@Test func previewLinesDropsDecorationOnlyLines() {
    let pane = """
    ⏺ Done refactoring auth module
    ╭──────────────────────────╮
    │ >                        │
    ╰──────────────────────────╯
    """
    #expect(Tmux.previewLines(pane, count: 3) == "⏺ Done refactoring auth module")
}

@Test func previewLinesDropsDashAndUnderscoreLines() {
    let pane = "result: 4 tests passed\n----------\n____________\n  ? for shortcuts"
    #expect(Tmux.previewLines(pane, count: 3) == "result: 4 tests passed\n  ? for shortcuts")
}

@Test func previewLinesKeepsLastCountMeaningfulLines() {
    let pane = "a1\nb2\nc3\nd4\ne5"
    #expect(Tmux.previewLines(pane, count: 3) == "c3\nd4\ne5")
}

@Test func previewLinesEmptyWhenNothingMeaningful() {
    #expect(Tmux.previewLines("───\n\n│ │", count: 3) == "")
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
