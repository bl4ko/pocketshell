import KeyKit
import SwiftUI

struct KeysView: View {
    @EnvironmentObject var store: AppStore
    @State private var publicKeyLine: String?
    @State private var keyKind = ""
    @State private var error: String?
    @State private var copied = false

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
            if let error {
                Section("Error") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Keys")
        .onAppear { loadKey() }
    }

    private func loadKey() {
        do {
            let key = try store.deviceKey()
            publicKeyLine = key.openSSHPublicKeyLine(comment: "pocketshell@iphone")
            switch key {
            case .enclave: keyKind = "Secure Enclave"
            case .software: keyKind = "software, Keychain"
            }
        } catch {
            self.error = "\(error)"
        }
    }
}
