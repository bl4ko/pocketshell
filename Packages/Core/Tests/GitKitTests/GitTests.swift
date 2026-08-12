import Testing

@testable import GitKit

struct GitTests {
    @Test func parsesPorcelainStatus() {
        let output = """
             M App/Stores.swift
            A  App/New.swift
            ?? notes.md
            R  old.swift -> new.swift
            """
        let changes = Git.parseStatus(output)
        #expect(changes.map(\.path) == ["App/Stores.swift", "App/New.swift", "notes.md", "new.swift"])
        #expect(changes[0].staged == false)
        #expect(changes[1].staged)
        #expect(changes[2].isUntracked)
    }

    @Test func parsesLog() {
        let commits = Git.parseLog("a1b2c3d\t2026-08-12\tfix(push): split keys\ne4f5g6h\t2026-08-11\tdocs: herdr")
        #expect(commits.count == 2)
        #expect(commits[0].hash == "a1b2c3d")
        #expect(commits[0].subject == "fix(push): split keys")
    }

    @Test func parsesUnifiedDiffWithLineNumbers() {
        let output = """
            diff --git a/App/Stores.swift b/App/Stores.swift
            index 1111111..2222222 100644
            --- a/App/Stores.swift
            +++ b/App/Stores.swift
            @@ -10,7 +10,8 @@ final class AppStore {
                 let a = 1
            -    let b = 2
            +    let b = 3
            +    let c = 4
                 let d = 5
            """
        let files = Git.parseDiff(output)
        #expect(files.count == 1)
        #expect(files[0].path == "App/Stores.swift")
        #expect(files[0].added == 2)
        #expect(files[0].removed == 1)
        let removed = files[0].lines.first { $0.kind == .removed }
        #expect(removed?.oldNumber == 11)
    }

    @Test func quotesPathsWithSpaces() {
        #expect(Git.statusCommand(in: "/tmp/my repo").contains("cd '/tmp/my repo'"))
    }
}
