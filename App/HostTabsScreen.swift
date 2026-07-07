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
    @State private var showFiles = false
    @State private var showForward = false
    @State private var addingSnippet = false
    @State private var editingSnippet: Snippet?

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
                Menu {
                    Button {
                        showFiles = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    Button {
                        showForward = true
                    } label: {
                        Label("Port forward", systemImage: "network")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
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
        .sheet(isPresented: $showFiles) {
            FileBrowserView(controller: activeController)
        }
        .sheet(isPresented: $showForward) {
            PortForwardSheet(controller: activeController)
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
        .themedScreen()
    }

    private var activeController: ConnectionController? {
        tabs.first { $0.id == selectedTab }?.controller
    }

    private func addTab() {
        let controller = ConnectionController(
            host: host,
            key: (try? store.key(for: host)) ?? .software(.init()),
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
                    Text("\(index + 1)")
                        .font(.footnote.monospaced())
                        .padding(.horizontal, 14)
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
                        .contextMenu {
                            Button("Close Tab", role: .destructive) {
                                closeTab(tab)
                            }
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
            List {
                ForEach(terminalSnippets) { snippet in
                    Button {
                        activeController?.sendText(snippet.command + "\n")
                        showSnippets = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.name)
                                .foregroundStyle(.primary)
                            Text(snippet.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            store.snippets.removeAll { $0.id == snippet.id }
                        }
                        Button("Edit") {
                            editingSnippet = snippet
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button("Edit") { editingSnippet = snippet }
                        Button("Delete", role: .destructive) {
                            store.snippets.removeAll { $0.id == snippet.id }
                        }
                    }
                }
            }
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addingSnippet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay {
                if terminalSnippets.isEmpty {
                    ContentUnavailableView {
                        Label("No snippets", systemImage: "text.badge.plus")
                    } description: {
                        Text("Tap + to save a command. Tapping a snippet types it into the terminal.")
                    } actions: {
                        Button("Add Snippet") { addingSnippet = true }
                    }
                }
            }
            .sheet(isPresented: $addingSnippet) {
                SnippetFormView(snippet: nil)
            }
            .sheet(item: $editingSnippet) { snippet in
                SnippetFormView(snippet: snippet)
            }
            .themedScreen()
        }
        .presentationDetents([.medium, .large])
    }

    private var terminalSnippets: [Snippet] {
        store.snippets
            .filter { $0.runMode == .typeIntoTerminal && ($0.hostID == nil || $0.hostID == host.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }
}

struct TmuxJumpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [TmuxSession] = []
    @State private var windows: [WindowDashboardItem] = []
    @State private var windowsSession: String?
    @State private var loaded = false

    let controller: ConnectionController?

    private var attached: Bool {
        controller?.isTmuxAttached ?? false
    }

    var body: some View {
        NavigationStack {
            List {
                if !sessions.isEmpty {
                    Section {
                        ForEach(sessions) { session in
                            Button {
                                jump(toSession: session.name)
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
                    } header: {
                        Text("Sessions")
                    } footer: {
                        Text("Tapping re-attaches this tab to the target.")
                    }
                }
                if !windows.isEmpty {
                    Section("Windows") {
                        ForEach(windows) { item in
                            Button {
                                jump(toWindow: item.window.index)
                            } label: {
                                DashboardRow(item: item)
                            }
                        }
                    }
                }
                if attached {
                    Section("Quick") {
                        Button("Next window") {
                            controller?.sendText(Tmux.nextWindowKeys)
                            dismiss()
                        }
                        Button("Previous window") {
                            controller?.sendText(Tmux.previousWindowKeys)
                            dismiss()
                        }
                        Button("Next pane") {
                            controller?.sendText(Tmux.nextPaneKeys)
                            dismiss()
                        }
                        Button("Zoom pane") {
                            controller?.sendText(Tmux.zoomPaneKeys)
                            dismiss()
                        }
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
            .themedScreen()
        }
    }

    private func jump(toSession session: String) {
        let controller = controller
        Task { await controller?.jump(toSession: session) }
        dismiss()
    }

    private func jump(toWindow index: Int) {
        guard let windowsSession else { return }
        let controller = controller
        Task { await controller?.jump(toSession: windowsSession, windowIndex: index) }
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
            windows = await controller.dashboardItems(session: current.name)
            windowsSession = current.name
        }
        loaded = true
    }
}
