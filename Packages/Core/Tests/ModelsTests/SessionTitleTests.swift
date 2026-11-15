import Testing

@testable import Models

@Test func sessionTitleStripsStatusGlyphsAndKeepsTheName() {
    #expect(SessionTitle.clean("✳ CPAMC") == "CPAMC")
    #expect(SessionTitle.clean("◐ POCKETSHELL") == "POCKETSHELL")
    #expect(SessionTitle.clean("⠋ Fixing the login test") == "Fixing the login test")
    #expect(SessionTitle.clean("✶✻ · HW-PROXY-IRIS ") == "HW-PROXY-IRIS")
    #expect(SessionTitle.clean("a | b | c") == "a | b | c")
    #expect(SessionTitle.clean("~/src/api") == "~/src/api")
    #expect(SessionTitle.clean("3D print") == "3D print")
}

@Test func sessionTitleDropsDefaultsHostnamesAndEmptyTitles() {
    #expect(SessionTitle.clean(nil) == nil)
    #expect(SessionTitle.clean("  ") == nil)
    #expect(SessionTitle.clean("✳ ") == nil)
    #expect(SessionTitle.clean("✳ Claude Code") == nil)
    #expect(SessionTitle.clean("codex") == nil)
    #expect(SessionTitle.clean("box.lan", host: "box.lan") == nil)
    #expect(SessionTitle.clean("BOX", host: "box.lan") == nil)
    #expect(SessionTitle.clean("box.local", host: "box") == nil)
    #expect(SessionTitle.clean("boxer", host: "box") == "boxer")
}

@Test func sessionTitleDropsCodexsFolderSuffixAndLimitsLength() {
    #expect(SessionTitle.clean("QBIT-FIX | github", cwd: "/Users/me/github") == "QBIT-FIX")
    #expect(SessionTitle.clean("QBIT-FIX | github", cwd: "/Users/me/other") == "QBIT-FIX | github")
    let long = SessionTitle.clean(String(repeating: "x", count: 120))
    #expect(long?.count == 80)
    #expect(long?.hasSuffix("…") == true)
    #expect(SessionTitle.same("CPAMC", "cpamc"))
    #expect(!SessionTitle.same("CPAMC", nil))
}
