import Models
import SwiftUI

struct HostFormView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let host: HostConfig?
    @State private var name = ""
    @State private var hostname = ""
    @State private var alternateHostnames = ""
    @State private var port = 22
    @State private var username = ""
    @State private var group = ""
    @State private var keyTag = AppStore.deviceKeyTag
    @State private var tmuxSession = ""
    @State private var onConnectCommand = ""
    @State private var proxyJump: UUID?
    @AppStorage(AppSettings.iCloudCredentialsSyncKey) private var credentialsSync = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("Hostname or IP", text: $hostname)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Alternate hostnames or IPs", text: $alternateHostnames, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    GroupField(group: $group, groups: groups)
                    Picker("Key", selection: $keyTag) {
                        Text(credentialsSync ? "Shared PocketShell key" : "Device key").tag(AppStore.deviceKeyTag)
                        ForEach(store.importedKeys) { key in
                            Text(key.name).tag(key.tag)
                        }
                    }
                    Picker("Jump host", selection: $proxyJump) {
                        Text("Direct").tag(UUID?.none)
                        ForEach(bastionCandidates) { candidate in
                            Text(candidate.name).tag(UUID?.some(candidate.id))
                        }
                    }
                    .accessibilityIdentifier("jump-host-picker")
                }
                Section {
                    TextField("tmux session (optional)", text: $tmuxSession)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("On-connect command (optional)", text: $onConnectCommand)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(
                        "With a tmux session set, connecting lists its windows for one-tap attach. Otherwise the on-connect command (or a plain shell) runs."
                    )
                }
            }
            .navigationTitle(host == nil ? "Add Host" : "Edit Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || hostname.isEmpty || username.isEmpty)
                }
            }
            .onAppear {
                guard let host else { return }
                name = host.name
                hostname = host.hostname
                alternateHostnames = (host.alternateHostnames ?? []).joined(separator: ", ")
                port = host.port
                username = host.username
                group = host.group ?? ""
                keyTag = host.keyTag
                tmuxSession = host.tmuxSession ?? ""
                onConnectCommand = host.onConnectCommand ?? ""
                proxyJump = host.proxyJump
            }
            .themedScreen()
        }
    }

    private func save() {
        var updated = host ?? HostConfig(name: "", hostname: "", username: "", keyTag: AppStore.deviceKeyTag)
        updated.name = name
        updated.hostname = hostname
        let alternates =
            alternateHostnames
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != hostname }
        let uniqueAlternates = alternates.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
        updated.alternateHostnames = uniqueAlternates.isEmpty ? nil : uniqueAlternates
        updated.port = port
        updated.username = username
        updated.group =
            group.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : group.trimmingCharacters(in: .whitespaces)
        updated.keyTag = keyTag
        updated.tmuxSession = tmuxSession.isEmpty ? nil : tmuxSession
        updated.onConnectCommand = onConnectCommand.isEmpty ? nil : onConnectCommand
        updated.proxyJump = proxyJump
        if let index = store.hosts.firstIndex(where: { $0.id == updated.id }) {
            store.hosts[index] = updated
        } else {
            store.hosts.append(updated)
        }
        dismiss()
    }

    private var bastionCandidates: [HostConfig] {
        store.hosts.filter { $0.id != host?.id }
    }

    private var groups: [String] {
        Array(Set(store.hosts.compactMap(\.group) + store.vncHosts.compactMap(\.group))).sorted()
    }
}

struct GroupField: View {
    @Binding var group: String
    let groups: [String]

    var body: some View {
        HStack {
            TextField("Group (optional)", text: $group)
                .autocorrectionDisabled()
            Menu {
                Button("No group") { group = "" }
                ForEach(groups, id: \.self) { name in
                    Button(name) { group = name }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .accessibilityLabel("Choose group")
            .accessibilityIdentifier("group-picker")
        }
    }
}
