import KeyKit
import Models
import SSHKit
import SwiftUI

struct SnippetRunView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let host: HostConfig
    let snippet: Snippet
    @State private var state: RunState = .running

    enum RunState {
        case running
        case finished(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                switch state {
                case .running:
                    ProgressView("Running on \(host.name)…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                case .finished(let output):
                    outputText(output.isEmpty ? "(no output)" : output)
                case .failed(let message):
                    outputText(message).foregroundStyle(.red)
                }
            }
            .navigationTitle(snippet.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await run() }
        }
    }

    private func outputText(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .textSelection(.enabled)
    }

    private func run() async {
        do {
            let key = try store.key(for: host)
            let connection = SSHConnection(host: host, key: key, knownHosts: store.knownHosts)
            try await connection.connect()
            let output = try await connection.exec(snippet.command)
            await connection.disconnect()
            state = .finished(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            state = .failed("\(error)")
        }
    }
}
