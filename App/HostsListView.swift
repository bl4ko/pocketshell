import KeyKit
import Models
import SwiftUI

struct HostsListView: View {
    @EnvironmentObject var store: AppStore
    @State private var editingHost: HostConfig?
    @State private var addingHost = false
    @State private var runningSnippet: SnippetRun?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.hosts) { host in
                    NavigationLink(value: host) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name).font(.headline)
                            Text("\(host.username)@\(host.hostname):\(String(host.port))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Edit") { editingHost = host }
                        ForEach(execSnippets(for: host)) { snippet in
                            Button(snippet.name) {
                                runningSnippet = SnippetRun(host: host, snippet: snippet)
                            }
                        }
                        Button("Delete", role: .destructive) {
                            store.hosts.removeAll { $0.id == host.id }
                        }
                    }
                }
            }
            .navigationTitle("pocketshell")
            .navigationDestination(for: HostConfig.self) { host in
                TerminalScreen(
                    host: host,
                    controller: ConnectionController(
                        host: host,
                        key: (try? store.deviceKey()) ?? .software(.init()),
                        knownHosts: store.knownHosts
                    )
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink("Keys") { KeysView() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Snippets") { SnippetsView() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingHost = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $addingHost) {
                HostFormView(host: nil)
            }
            .sheet(item: $editingHost) { host in
                HostFormView(host: host)
            }
            .sheet(item: $runningSnippet) { run in
                SnippetRunView(host: run.host, snippet: run.snippet)
            }
            .overlay {
                if store.hosts.isEmpty {
                    ContentUnavailableView(
                        "No hosts",
                        systemImage: "server.rack",
                        description: Text("Add a host, then install the device key from the Keys screen.")
                    )
                }
            }
        }
    }

    private func execSnippets(for host: HostConfig) -> [Snippet] {
        store.snippets.filter {
            $0.runMode == .execAndShowOutput && ($0.hostID == nil || $0.hostID == host.id)
        }
    }
}

struct SnippetRun: Identifiable {
    let host: HostConfig
    let snippet: Snippet
    var id: UUID { snippet.id }
}
