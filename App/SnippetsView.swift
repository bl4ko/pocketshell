import Models
import SwiftUI

struct SnippetsView: View {
    @EnvironmentObject var store: AppStore
    @State private var editingSnippet: Snippet?
    @State private var adding = false

    var body: some View {
        List {
            ForEach(store.snippets.sorted { $0.sortOrder < $1.sortOrder }) { snippet in
                Button {
                    editingSnippet = snippet
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(snippet.name).foregroundStyle(.primary)
                            Spacer()
                            Text(snippet.runMode == .execAndShowOutput ? "exec" : "type")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        Text(snippet.command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .onDelete { offsets in
                let sorted = store.snippets.sorted { $0.sortOrder < $1.sortOrder }
                let ids = offsets.map { sorted[$0].id }
                store.snippets.removeAll { ids.contains($0.id) }
            }
        }
        .navigationTitle("Snippets")
        .toolbar {
            Button {
                adding = true
            } label: {
                Image(systemName: "plus")
            }
        }
        .sheet(isPresented: $adding) {
            SnippetFormView(snippet: nil)
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetFormView(snippet: snippet)
        }
        .overlay {
            if store.snippets.isEmpty {
                ContentUnavailableView(
                    "No snippets",
                    systemImage: "text.badge.plus",
                    description: Text("Saved commands: type into the terminal, or exec from a host's context menu.")
                )
            }
        }
    }
}

struct SnippetFormView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let snippet: Snippet?
    @State private var name = ""
    @State private var command = ""
    @State private var runMode: Snippet.RunMode = .typeIntoTerminal
    @State private var hostID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Command", text: $command, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Run mode", selection: $runMode) {
                    Text("Type into terminal").tag(Snippet.RunMode.typeIntoTerminal)
                    Text("Exec, show output").tag(Snippet.RunMode.execAndShowOutput)
                }
                Picker("Host", selection: $hostID) {
                    Text("All hosts").tag(UUID?.none)
                    ForEach(store.hosts) { host in
                        Text(host.name).tag(UUID?.some(host.id))
                    }
                }
            }
            .navigationTitle(snippet == nil ? "Add Snippet" : "Edit Snippet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || command.isEmpty)
                }
            }
            .onAppear {
                guard let snippet else { return }
                name = snippet.name
                command = snippet.command
                runMode = snippet.runMode
                hostID = snippet.hostID
            }
        }
    }

    private func save() {
        var updated = snippet ?? Snippet(
            name: "",
            command: "",
            sortOrder: (store.snippets.map(\.sortOrder).max() ?? -1) + 1
        )
        updated.name = name
        updated.command = command
        updated.runMode = runMode
        updated.hostID = hostID
        if let index = store.snippets.firstIndex(where: { $0.id == updated.id }) {
            store.snippets[index] = updated
        } else {
            store.snippets.append(updated)
        }
        dismiss()
    }
}
