import Foundation

public struct RecentDirectory: Identifiable, Hashable, Sendable {
    public let path: String
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String) {
        self.path = path
    }
}

public enum AgentHistory {
    /// Claude Code names its project folders after an escaped path, which cannot be
    /// unescaped reliably (a directory may itself contain a dash), so the real path
    /// is read back out of the newest transcript in each folder.
    public static func recentDirectoriesCommand(limit: Int = 8) -> String {
        "for d in $(ls -1dt \"$HOME\"/.claude/projects/*/ 2>/dev/null | head -\(limit)); do"
            + " f=$(ls -1t \"$d\"*.jsonl 2>/dev/null | head -1);"
            + " [ -n \"$f\" ] && head -1 \"$f\" | sed -n 's/.*\"cwd\":\"\\([^\"]*\\)\".*/\\1/p';"
            + " done; true"
    }

    public static func parseRecentDirectories(_ output: String) -> [RecentDirectory] {
        var seen: Set<String> = []
        return output.split(separator: "\n").compactMap { line in
            let path = line.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
            return RecentDirectory(path: path)
        }
    }
}
