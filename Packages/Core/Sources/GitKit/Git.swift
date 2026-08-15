import Foundation

public struct GitFileChange: Identifiable, Hashable, Sendable {
    public let path: String
    public let index: Character
    public let worktree: Character

    public var id: String { path }
    public var isUntracked: Bool { index == "?" }
    public var staged: Bool { index != " " && index != "?" }

    public init(path: String, index: Character, worktree: Character) {
        self.path = path
        self.index = index
        self.worktree = worktree
    }
}

public struct GitCommit: Identifiable, Hashable, Sendable {
    public let hash: String
    public let date: String
    public let subject: String

    public var id: String { hash }

    public init(hash: String, date: String, subject: String) {
        self.hash = hash
        self.date = date
        self.subject = subject
    }
}

public struct GitDiffLine: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable {
        case context
        case added
        case removed
        case hunk
    }

    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
    public let id: Int
}

public struct GitDiffFile: Identifiable, Hashable, Sendable {
    public let path: String
    public let lines: [GitDiffLine]
    public var id: String { path }
    public var added: Int { lines.count { $0.kind == .added } }
    public var removed: Int { lines.count { $0.kind == .removed } }
}

public enum Git {
    /// `cd` rather than `-C`: the path comes from tmux and may be a symlinked
    /// worktree the caller wants resolved the same way the shell would.
    public static func command(_ arguments: String, in directory: String) -> String {
        "cd \(shellQuote(directory)) && git --no-pager \(arguments) 2>&1"
    }

    public static func statusCommand(in directory: String) -> String {
        command("status --porcelain=v1 --untracked-files=normal", in: directory)
    }

    public static func branchCommand(in directory: String) -> String {
        command("rev-parse --abbrev-ref HEAD", in: directory)
    }

    public static func diffCommand(in directory: String, path: String? = nil, staged: Bool = false) -> String {
        let staging = staged ? " --cached" : ""
        let file = path.map { " -- \(shellQuote($0))" } ?? ""
        return command("diff\(staging) --no-color -U3\(file)", in: directory)
    }

    public static func logCommand(in directory: String, count: Int = 20) -> String {
        command("log -n \(count) --date=short --pretty=format:%h%x09%ad%x09%s", in: directory)
    }

    public static func parseStatus(_ output: String) -> [GitFileChange] {
        output.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let characters = Array(line)
            let path = String(characters[3...])
            // Renames read "old -> new"; the new path is what the diff uses.
            let resolved = path.components(separatedBy: " -> ").last ?? path
            return GitFileChange(path: resolved, index: characters[0], worktree: characters[1])
        }
    }

    public static func parseLog(_ output: String) -> [GitCommit] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return GitCommit(hash: String(fields[0]), date: String(fields[1]), subject: String(fields[2]))
        }
    }

    public static func parseDiff(_ output: String) -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        var path: String?
        var lines: [GitDiffLine] = []
        var oldNumber = 0
        var newNumber = 0
        var id = 0

        func flush() {
            if let path, !lines.isEmpty {
                files.append(GitDiffFile(path: path, lines: lines))
            }
            lines = []
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flush()
                path = line.components(separatedBy: " b/").last
                continue
            }
            if line.hasPrefix("@@") {
                let numbers = line.matches(of: /[-+](\d+)/).compactMap { Int($0.1) }
                oldNumber = numbers.first ?? 0
                newNumber = numbers.count > 1 ? numbers[1] : 0
                id += 1
                lines.append(GitDiffLine(kind: .hunk, text: line, oldNumber: nil, newNumber: nil, id: id))
                continue
            }
            guard path != nil, !lines.isEmpty else { continue }
            id += 1
            if line.hasPrefix("+") {
                lines.append(
                    GitDiffLine(
                        kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: newNumber, id: id))
                newNumber += 1
            } else if line.hasPrefix("-") {
                lines.append(
                    GitDiffLine(
                        kind: .removed, text: String(line.dropFirst()), oldNumber: oldNumber, newNumber: nil, id: id))
                oldNumber += 1
            } else if line.hasPrefix(" ") || line.isEmpty {
                lines.append(
                    GitDiffLine(
                        kind: .context, text: String(line.dropFirst()), oldNumber: oldNumber, newNumber: newNumber,
                        id: id))
                oldNumber += 1
                newNumber += 1
            }
        }
        flush()
        return files
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
