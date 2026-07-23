import Models
import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var client: WatchClient

    var body: some View {
        NavigationStack {
            List {
                if let statusMessage = client.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let snapshot = client.snapshot {
                    ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                        NavigationLink {
                            ReplyView(window: window)
                        } label: {
                            row(window)
                        }
                    }
                    Text(snapshot.updatedAt, style: .relative)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("agents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        client.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private func row(_ window: SessionSnapshot.Window) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color(window.status))
                    .frame(width: 6, height: 6)
                Text(window.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            Text(window.lastLine)
                .font(.system(size: 11).monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "busy": .orange
        case "needs input": .purple
        default: .green
        }
    }
}

struct ReplyView: View {
    @EnvironmentObject var client: WatchClient

    let window: SessionSnapshot.Window

    private static let replies: [(label: String, text: String)] = [
        ("yes", "y"),
        ("1", "1"),
        ("2", "2"),
        ("proceed", "proceed"),
        ("continue", "continue"),
    ]

    var body: some View {
        List {
            Section("Recent output") {
                Text(window.lastLine)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.secondary)
            }
            Section("Reply") {
                ForEach(Self.replies, id: \.label) { reply in
                    Button(reply.label) {
                        client.send(window: window, text: reply.text, pressEnter: true)
                    }
                }
                Button("Enter only") {
                    client.send(window: window, text: "", pressEnter: true)
                }
            }
        }
        .navigationTitle(window.name)
    }
}
