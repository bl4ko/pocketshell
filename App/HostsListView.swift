import KeyKit
import Models
import SwiftUI

struct HostsListView: View {
    @EnvironmentObject var store: AppStore
    @State private var editingHost: HostConfig?
    @State private var addingHost = false
    @State private var addingVNCHost = false
    @State private var editingVNCHost: VNCHostConfig?
    @State private var runningSnippet: SnippetRun?

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedHosts, id: \.0) { group, hosts in
                    Section {
                        ForEach(hosts) { host in
                            hostRow(host)
                        }
                    } header: {
                        if let group {
                            Text(group)
                        }
                    }
                }
                if !store.vncHosts.isEmpty {
                    Section("Desktops") {
                        ForEach(store.vncHosts) { host in
                            vncHostRow(host)
                        }
                    }
                }
            }
            .navigationTitle("pocketshell")
            .navigationDestination(for: HostConfig.self) { host in
                HostTabsScreen(host: host)
            }
            .navigationDestination(for: VNCHostConfig.self) { host in
                VNCDesktopScreen(host: host)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink("Keys") { KeysView() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink("Snippets") { SnippetsView() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("SSH Host") { addingHost = true }
                        Button("VNC Desktop") { addingVNCHost = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("plus")
                }
            }
            .sheet(isPresented: $addingHost) {
                HostFormView(host: nil)
            }
            .sheet(item: $editingHost) { host in
                HostFormView(host: host)
            }
            .sheet(isPresented: $addingVNCHost) {
                VNCHostFormView(host: nil)
            }
            .sheet(item: $editingVNCHost) { host in
                VNCHostFormView(host: host)
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
            .themedScreen()
        }
    }

    private var groupedHosts: [(String?, [HostConfig])] {
        let grouped = Dictionary(grouping: store.hosts) { $0.group }
        var result: [(String?, [HostConfig])] = []
        if let ungrouped = grouped[nil] {
            result.append((nil, ungrouped))
        }
        for group in grouped.keys.compactMap({ $0 }).sorted() {
            result.append((group, grouped[group] ?? []))
        }
        return result
    }

    private func hostRow(_ host: HostConfig) -> some View {
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

    private func vncHostRow(_ host: VNCHostConfig) -> some View {
        NavigationLink(value: host) {
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.headline)
                Text("vnc://\(host.hostname):\(String(host.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Edit") { editingVNCHost = host }
            Button("Delete", role: .destructive) {
                store.deleteVNCHost(host)
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
