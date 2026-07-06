import Models
import SwiftUI
import TmuxKit

struct TerminalTab: Identifiable {
    let id = UUID()
    let controller: ConnectionController
}

struct HostTabsScreen: View {
    @EnvironmentObject var store: AppStore
    @State private var tabs: [TerminalTab] = []
    @State private var selectedTab: UUID?
    @State private var showSnippets = false
    @State private var showTmuxJump = false

    let host: HostConfig

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 {
                tabStrip
            }
            ZStack {
                ForEach(tabs) { tab in
                    TerminalScreen(connection: tab.controller, host: host)
                        .opacity(tab.id == selectedTab ? 1 : 0)
                        .allowsHitTesting(tab.id == selectedTab)
                }
            }
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTmuxJump = true
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSnippets = true
                } label: {
                    Image(systemName: "text.badge.plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addTab()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
            }
        }
        .sheet(isPresented: $showSnippets) {
            snippetPicker
        }
        .sheet(isPresented: $showTmuxJump) {
            TmuxJumpSheet(controller: activeController)
        }
        .onAppear {
            if tabs.isEmpty {
                addTab()
            }
        }
        .onDisappear {
            for tab in tabs {
                Task { await tab.controller.stop() }
            }
        }
    }

    private var activeController: ConnectionController? {
        tabs.first { $0.id == selectedTab }?.controller
    }

    private func addTab() {
        let controller = ConnectionController(
            host: host,
            key: (try? store.deviceKey()) ?? .software(.init()),
            knownHosts: store.knownHosts
        )
        let tab = TerminalTab(controller: controller)
        tabs.append(tab)
        selectedTab = tab.id
    }

    private func closeTab(_ tab: TerminalTab) {
        Task { await tab.controller.stop() }
        tabs.removeAll { $0.id == tab.id }
        if selectedTab == tab.id {
            selectedTab = tabs.last?.id
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    HStack(spacing: 4) {
                        Text("\(index + 1)")
                            .font(.footnote.monospaced())
                        Button {
                            closeTab(tab)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        tab.id == selectedTab
                            ? Color.accentColor.opacity(0.35)
                            : Color.secondary.opacity(0.15)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        selectedTab = tab.id
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.thinMaterial)
    }

    private var snippetPicker: some View {
        NavigationStack {
            List(terminalSnippets) { snippet in
                Button {
                    activeController?.sendText(snippet.command + "\n")
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

struct TmuxJumpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [TmuxSession] = []
    @State private var windows: [TmuxWindow] = []
    @State private var loaded = false

    let controller: ConnectionController?

    var body: some View {
        NavigationStack {
            List {
                if !sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(sessions) { session in
                            Button {
                                send(Tmux.switchClientCommand(session: session.name))
                            } label: {
                                HStack {
                                    Text(session.name)
                                    Text("\(session.windows)w")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if session.attached {
                                        Spacer()
                                        Image(systemName: "eye").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if !windows.isEmpty {
                    Section("Windows") {
                        ForEach(windows) { window in
                            Button {
                                send(Tmux.selectWindowCommand(index: window.index))
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
                }
                Section("Panes") {
                    Button("Next pane") {
                        controller?.sendText(Tmux.nextPaneKeys)
                        dismiss()
                    }
                    Button("Zoom pane") {
                        controller?.sendText(Tmux.zoomPaneKeys)
                        dismiss()
                    }
                }
                if loaded && sessions.isEmpty {
                    Text("No tmux sessions found")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("tmux")
            .presentationDetents([.medium, .large])
            .task {
                await load()
            }
        }
    }

    private func send(_ command: String) {
        controller?.sendText(Tmux.promptKeys(command))
        dismiss()
    }

    private func load() async {
        guard let controller else {
            loaded = true
            return
        }
        sessions = await controller.tmuxSessions()
        let current = sessions.first { $0.attached } ?? sessions.first
        if let current {
            windows = await controller.tmuxWindows(session: current.name)
        }
        loaded = true
    }
}
