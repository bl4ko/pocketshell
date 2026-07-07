import Models
import SwiftUI

struct VNCHostFormView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var password = ""
    @State private var group: String

    private let existing: VNCHostConfig?

    init(host: VNCHostConfig?) {
        existing = host
        _name = State(initialValue: host?.name ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: String(host?.port ?? 5900))
        _username = State(initialValue: host?.username ?? "")
        _group = State(initialValue: host?.group ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Hostname / IP", text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Group (optional)", text: $group)
                }
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(existing == nil ? "Password" : "Password (unchanged if empty)", text: $password)
                } footer: {
                    Text("For macOS Screen Sharing use your macOS login. Leave username empty for plain VNC password auth.")
                }
            }
            .navigationTitle(existing == nil ? "Add Desktop" : "Edit Desktop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || hostname.isEmpty)
                }
            }
        }
    }

    private func save() {
        var host = existing ?? VNCHostConfig(name: name, hostname: hostname)
        host.name = name
        host.hostname = hostname
        host.port = Int(port) ?? 5900
        host.username = username
        host.group = group.isEmpty ? nil : group
        if let index = store.vncHosts.firstIndex(where: { $0.id == host.id }) {
            store.vncHosts[index] = host
        } else {
            store.vncHosts.append(host)
        }
        if !password.isEmpty {
            store.setVNCPassword(password, for: host)
        }
        dismiss()
    }
}
