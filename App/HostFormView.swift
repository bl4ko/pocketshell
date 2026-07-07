import Models
import SwiftUI

struct HostFormView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let host: HostConfig?
    @State private var name = ""
    @State private var hostname = ""
    @State private var port = 22
    @State private var username = ""
    @State private var group = ""
    @State private var keyTag = AppStore.deviceKeyTag
    @State private var tmuxSession = ""
    @State private var onConnectCommand = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("Hostname or IP", text: $hostname)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Group (optional)", text: $group)
                        .autocorrectionDisabled()
                    Picker("Key", selection: $keyTag) {
                        Text("Device key").tag(AppStore.deviceKeyTag)
                        ForEach(store.importedKeys) { key in
                            Text(key.name).tag(key.tag)
                        }
                    }
                }
                Section {
                    TextField("tmux session (optional)", text: $tmuxSession)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("On-connect command (optional)", text: $onConnectCommand)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("With a tmux session set, connecting lists its windows for one-tap attach. Otherwise the on-connect command (or a plain shell) runs.")
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
                port = host.port
                username = host.username
                group = host.group ?? ""
                keyTag = host.keyTag
                tmuxSession = host.tmuxSession ?? ""
                onConnectCommand = host.onConnectCommand ?? ""
            }
        }
    }

    private func save() {
        var updated = host ?? HostConfig(name: "", hostname: "", username: "", keyTag: AppStore.deviceKeyTag)
        updated.name = name
        updated.hostname = hostname
        updated.port = port
        updated.username = username
        updated.group = group.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : group.trimmingCharacters(in: .whitespaces)
        updated.keyTag = keyTag
        updated.tmuxSession = tmuxSession.isEmpty ? nil : tmuxSession
        updated.onConnectCommand = onConnectCommand.isEmpty ? nil : onConnectCommand
        if let index = store.hosts.firstIndex(where: { $0.id == updated.id }) {
            store.hosts[index] = updated
        } else {
            store.hosts.append(updated)
        }
        dismiss()
    }
}
