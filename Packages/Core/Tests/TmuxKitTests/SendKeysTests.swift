import Testing

@testable import TmuxKit

@Test func sendKeysTypesLiteralText() {
    let cmd = Tmux.sendKeysCommand(session: "claude", windowIndex: 2, text: "y", pressEnter: false)
    #expect(cmd == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux send-keys -t 'claude':2 -l 'y'")
}

@Test func sendKeysWithEnterAppendsEnterKey() {
    let cmd = Tmux.sendKeysCommand(session: "claude", windowIndex: 0, text: "proceed", pressEnter: true)
    #expect(
        cmd
            == "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\" tmux send-keys -t 'claude':0 -l 'proceed' \\; send-keys -t 'claude':0 Enter"
    )
}

@Test func sendKeysEscapesSingleQuotes() {
    let cmd = Tmux.sendKeysCommand(session: "a'b", windowIndex: 1, text: "it's", pressEnter: false)
    #expect(cmd.contains("'a'\\''b':1"))
    #expect(cmd.contains("-l 'it'\\''s'"))
}
