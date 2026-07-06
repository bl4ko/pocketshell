import Models
import SwiftUI
import TerminalUI
import TmuxKit
import ToolbarUI

struct TerminalScreen: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var connection: ConnectionController
    @State private var showSnippets = false

    let host: HostConfig

    init(host: HostConfig, controller: @autoclosure @escaping () -> ConnectionController) {
        self.host = host
        _connection = StateObject(wrappedValue: controller())
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBanner
            SSHTerminalView(bridge: connection.bridge)
            TerminalToolbar(
                keys: store.toolbarKeys,
                ctrlActive: Binding(
                    get: { connection.bridge.ctrlActive },
                    set: { connection.bridge.ctrlActive = $0 }
                ),
                onKey: { connection.bridge.handleToolbar($0) }
            )
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSnippets = true
                } label: {
                    Image(systemName: "text.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showSnippets) {
            snippetPicker
        }
        .sheet(isPresented: windowPickerShown) {
            windowPicker
        }
        .task {
            await connection.start()
        }
        .onDisappear {
            Task { await connection.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                connection.appForegrounded()
            }
        }
    }

    private var statusBanner: some View {
        Group {
            switch connection.phase {
            case .connecting:
                banner("connecting…", color: .blue, icon: "bolt.horizontal")
            case .reconnecting(let message):
                banner(message, color: .orange, icon: "arrow.clockwise")
            case .failed(let message):
                banner(message, color: .red, icon: "exclamationmark.triangle.fill")
            default:
                EmptyView()
            }
        }
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .padding(.top, 1)
            Text(text)
                .font(.caption.monospaced())
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.15))
    }

    private var windowPickerShown: Binding<Bool> {
        Binding(
            get: {
                if case .pickingWindow = connection.phase { return true }
                return false
            },
            set: { shown in
                if !shown, case .pickingWindow = connection.phase {
                    Task { await connection.openPlainShell() }
                }
            }
        )
    }

    private var windowPicker: some View {
        NavigationStack {
            List {
                if case .pickingWindow(let windows) = connection.phase {
                    ForEach(windows) { window in
                        Button {
                            Task { await connection.selectWindow(window) }
                        } label: {
                            HStack {
                                Text("\(window.index): \(window.name)")
                                if window.active {
                                    Spacer()
                                    Image(systemName: "eye").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Button("Plain shell") {
                    Task { await connection.openPlainShell() }
                }
            }
            .navigationTitle("tmux windows")
            .presentationDetents([.medium])
        }
    }

    private var snippetPicker: some View {
        NavigationStack {
            List(terminalSnippets) { snippet in
                Button {
                    connection.sendText(snippet.command + "\n")
                    showSnippets = false
                } label: {
                    VStack(alignment: .leading) {
                        Text(snippet.name)
                        Text(snippet.command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .navigationTitle("Snippets")
            .presentationDetents([.medium])
        }
    }

    private var terminalSnippets: [Snippet] {
        store.snippets.filter {
            $0.runMode == .typeIntoTerminal && ($0.hostID == nil || $0.hostID == host.id)
        }
    }
}
