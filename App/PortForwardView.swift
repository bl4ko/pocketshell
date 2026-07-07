import SSHKit
import SwiftUI
import WebKit

struct PortForwardSheet: View {
    @State private var remotePort = "3000"
    @State private var remoteHost = "127.0.0.1"
    @State private var handle: PortForwardHandle?
    @State private var errorMessage: String?
    @State private var showWeb = false

    let controller: ConnectionController?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Remote host", text: $remoteHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Remote port", text: $remotePort)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Tunnels 127.0.0.1:<local> on this device to the host's network over SSH.")
                }
                if let handle {
                    Section {
                        LabeledContent("Local URL", value: "http://127.0.0.1:\(handle.localPort)")
                        Button("Open in browser") { showWeb = true }
                        Button("Stop tunnel", role: .destructive) { stop() }
                    }
                } else {
                    Button("Start tunnel") { start() }
                        .disabled(Int(remotePort) == nil || remoteHost.isEmpty)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Port forward")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showWeb) {
                if let handle {
                    TunnelWebView(url: URL(string: "http://127.0.0.1:\(handle.localPort)")!)
                }
            }
            .onDisappear {
                stop()
            }
            .themedScreen()
        }
        .presentationDetents([.medium])
    }

    private func start() {
        guard let controller, let port = Int(remotePort) else { return }
        errorMessage = nil
        let host = remoteHost
        Task {
            do {
                handle = try await controller.forwardPort(remoteHost: host, remotePort: port)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    private func stop() {
        let handle = handle
        self.handle = nil
        Task { await handle?.stop() }
    }
}

struct TunnelWebView: View {
    @Environment(\.dismiss) private var dismiss

    let url: URL

    var body: some View {
        NavigationStack {
            WebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.absoluteString)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
