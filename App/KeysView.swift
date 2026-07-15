import KeyKit
import SwiftUI

struct KeysView: View {
    @EnvironmentObject var store: AppStore
    @State private var publicKeyLine: String?
    @State private var keyKind = ""
    @State private var error: String?
    @State private var copied = false
    @State private var importing = false

    var body: some View {
        List {
            if let publicKeyLine {
                Section("Device public key (\(keyKind))") {
                    Text(publicKeyLine)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = publicKeyLine
                        copied = true
                    }
                    ShareLink(item: publicKeyLine)
                }
                Section("Install on host") {
                    Text("echo '\(publicKeyLine)' >> ~/.ssh/authorized_keys")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            Section("Imported keys") {
                ForEach(store.importedKeys) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name)
                        Text(key.publicKeyLine)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            store.deleteImportedKey(key)
                        }
                    }
                }
                Button("Import Private Key") { importing = true }
            }
            if let error {
                Section("Error") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Keys")
        .onAppear { loadKey() }
        .sheet(isPresented: $importing) {
            ImportKeyView()
        }
        .themedScreen()
    }

    private func loadKey() {
        do {
            let key = try store.deviceKey()
            publicKeyLine = key.openSSHPublicKeyLine(comment: "pocketshell@iphone")
            switch key {
            case .enclave: keyKind = "Secure Enclave"
            case .software: keyKind = "software, Keychain"
            case .ed25519: keyKind = "ed25519, Keychain"
            }
        } catch {
            self.error = "\(error)"
        }
    }
}

struct ImportKeyView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keyText = ""
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section {
                    TextEditor(text: $keyText)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 180)
                    Button("Paste from clipboard") {
                        keyText = UIPasteboard.general.string ?? keyText
                    }
                } header: {
                    Text("OpenSSH private key")
                } footer: {
                    Text(
                        "ed25519 or ECDSA P-256 key (-----BEGIN OPENSSH PRIVATE KEY-----). RSA keys are not supported.")
                }
                Section {
                    SecureField("Passphrase (if protected)", text: $passphrase)
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }
                        .disabled(name.isEmpty || keyText.isEmpty)
                }
            }
            .themedScreen()
        }
    }

    private func importKey() {
        do {
            _ = try store.importKey(
                name: name,
                privateKeyText: keyText,
                passphrase: passphrase.isEmpty ? nil : passphrase
            )
            dismiss()
        } catch let parseError as OpenSSHPrivateKey.ParseError {
            error =
                switch parseError {
                case .notOpenSSHKey: "not an OpenSSH private key (needs BEGIN OPENSSH PRIVATE KEY)"
                case .encrypted: "key is passphrase-protected — enter the passphrase below"
                case .wrongPassphrase: "wrong passphrase"
                case .unsupportedCipher(let cipher): "unsupported cipher \(cipher)"
                case .unsupportedKeyType(let type): "unsupported key type \(type) — use ed25519 or ECDSA P-256"
                case .malformed: "key data is malformed"
                }
        } catch {
            self.error = "\(error)"
        }
    }
}
