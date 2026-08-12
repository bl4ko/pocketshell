import Testing

@testable import MonitorKit

struct AgentHistoryTests {
    @Test func keepsTheNewestUniquePaths() {
        let output = """
            /Users/bl4ot/Projects/github/pocketshell
            /Users/bl4ot/Projects/github/pocketshell
            /Users/bl4ot/Projects/github/corpus

            not-a-path
            """
        let directories = AgentHistory.parseRecentDirectories(output)
        #expect(
            directories.map(\.path) == [
                "/Users/bl4ot/Projects/github/pocketshell", "/Users/bl4ot/Projects/github/corpus",
            ])
        #expect(directories.first?.name == "pocketshell")
    }

    @Test func commandReadsTheTranscriptCwd() {
        let command = AgentHistory.recentDirectoriesCommand(limit: 3)
        #expect(command.contains("head -3"))
        #expect(command.contains(".claude/projects"))
        #expect(command.contains("cwd"))
    }
}
