import GitKit
import SwiftUI

struct DiffView: View {
    let controller: ConnectionController

    @Environment(\.dismiss) private var dismiss
    @State private var directory = ""
    @State private var branch = ""
    @State private var changes: [GitFileChange] = []
    @State private var files: [GitDiffFile] = []
    @State private var commits: [GitCommit] = []
    @State private var selected: String?
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if let message {
                    ContentUnavailableView("No diff", systemImage: "arrow.triangle.branch", description: Text(message))
                } else {
                    content
                }
            }
            .navigationTitle(directory.isEmpty ? "Diff" : (directory as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("diff.reload")
                }
            }
        }
        .task { await load() }
    }

    private var content: some View {
        List {
            Section {
                ForEach(changes) { change in
                    Button {
                        selected = selected == change.path ? nil : change.path
                    } label: {
                        fileRow(change)
                    }
                    .buttonStyle(.plain)
                    if selected == change.path, let file = files.first(where: { $0.path == change.path }) {
                        diffLines(file)
                    }
                }
                if changes.isEmpty {
                    Text("Working tree is clean")
                        .font(PocketshellTheme.mono(12))
                        .foregroundStyle(PocketshellTheme.muted)
                }
            } header: {
                Text("\(branch) · \(totalAdded) added, \(totalRemoved) removed")
                    .font(PocketshellTheme.mono(10, weight: .semibold))
            }
            Section("Recent commits") {
                ForEach(commits) { commit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.subject)
                            .font(PocketshellTheme.mono(12))
                            .lineLimit(2)
                        Text("\(commit.hash) · \(commit.date)")
                            .font(PocketshellTheme.mono(10))
                            .foregroundStyle(PocketshellTheme.muted)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func fileRow(_ change: GitFileChange) -> some View {
        let file = files.first { $0.path == change.path }
        return HStack(spacing: 8) {
            Image(systemName: selected == change.path ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(PocketshellTheme.muted)
            Text(change.path)
                .font(PocketshellTheme.mono(12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if let file {
                Text("+\(file.added)")
                    .font(PocketshellTheme.mono(10))
                    .foregroundStyle(PocketshellTheme.idleText)
                Text("−\(file.removed)")
                    .font(PocketshellTheme.mono(10))
                    .foregroundStyle(PocketshellTheme.waitingText)
            } else if change.isUntracked {
                Text("new")
                    .font(PocketshellTheme.mono(10))
                    .foregroundStyle(PocketshellTheme.muted)
            }
        }
    }

    private func diffLines(_ file: GitDiffFile) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(file.lines) { line in
                    Text(line.kind == .hunk ? line.text : prefix(line) + line.text)
                        .font(PocketshellTheme.mono(10))
                        .foregroundStyle(color(line))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line))
                }
            }
        }
    }

    private func prefix(_ line: GitDiffLine) -> String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private func color(_ line: GitDiffLine) -> Color {
        switch line.kind {
        case .added: PocketshellTheme.idleText
        case .removed: PocketshellTheme.waitingText
        case .hunk: PocketshellTheme.muted
        case .context: PocketshellTheme.body
        }
    }

    private func background(_ line: GitDiffLine) -> Color {
        switch line.kind {
        case .added: PocketshellTheme.idle.opacity(0.12)
        case .removed: PocketshellTheme.waiting.opacity(0.12)
        default: .clear
        }
    }

    private var totalAdded: Int { files.reduce(0) { $0 + $1.added } }
    private var totalRemoved: Int { files.reduce(0) { $0 + $1.removed } }

    private func load() async {
        loading = true
        message = nil
        guard let directory = await controller.currentDirectory() else {
            message = "PocketShell could not resolve the working directory."
            loading = false
            return
        }
        self.directory = directory
        let branchOutput = await controller.run(Git.branchCommand(in: directory)) ?? ""
        guard !branchOutput.contains("not a git repository") else {
            message = "\(directory) is not a git repository."
            loading = false
            return
        }
        branch = branchOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        changes = Git.parseStatus(await controller.run(Git.statusCommand(in: directory)) ?? "")
        let unstaged = Git.parseDiff(await controller.run(Git.diffCommand(in: directory)) ?? "")
        let staged = Git.parseDiff(await controller.run(Git.diffCommand(in: directory, staged: true)) ?? "")
        files = unstaged + staged.filter { file in !unstaged.contains { $0.path == file.path } }
        commits = Git.parseLog(await controller.run(Git.logCommand(in: directory)) ?? "")
        loading = false
    }
}
