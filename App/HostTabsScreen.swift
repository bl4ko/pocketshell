import Models
import MonitorKit
import SwiftUI
import TmuxKit
import UserNotifications

struct TerminalTab: Identifiable {
    let id = UUID()
    let controller: ConnectionController
    var name: String?
}

struct TabJumpItem: Identifiable {
    let id: UUID
    let label: String
    let status: AgentStatus
    let preview: String
    let selected: Bool
}

struct HostTabsScreen: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var tabs: [TerminalTab] = []
    @State private var selectedTab: UUID?
    @State private var tabStatuses: [UUID: AgentStatus] = [:]
    @State private var tabTracker = AgentActivityTracker()
    @State private var showSnippets = false
    @State private var showTmuxJump = false
    @State private var showFiles = false
    @State private var showForward = false
    @State private var addingSnippet = false
    @State private var editingSnippet: Snippet?
    @State private var renamingTab: UUID?
    @State private var renameText = ""

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
            TmuxJumpSheet(controller: activeController, tabItems: tabJumpItems) { id in
                selectedTab = id
            }
        }
        .sheet(isPresented: $showFiles) {
            FileBrowserView(controller: activeController)
        }
        .sheet(isPresented: $showForward) {
            PortForwardSheet(controller: activeController)
        }
        .onAppear {
            if tabs.isEmpty {
                restoreTabs()
            }
        }
        .onDisappear {
            for tab in tabs {
                Task { await tab.controller.stop() }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                pollTabs()
            }
        }
        .themedScreen()
    }

    private var activeController: ConnectionController? {
        tabs.first { $0.id == selectedTab }?.controller
    }

    private var tabJumpItems: [TabJumpItem] {
        tabs.enumerated().map { index, tab in
            TabJumpItem(
                id: tab.id,
                label: tab.name ?? "tab \(index + 1)",
                status: tabStatuses[tab.id] ?? .idle,
                preview: Tmux.previewLines(tab.controller.bridge.visibleText(), count: 1),
                selected: tab.id == selectedTab
            )
        }
    }

    private func makeController() -> ConnectionController {
        ConnectionController(
            host: host,
            key: (try? store.key(for: host)) ?? .software(.init()),
            knownHosts: store.knownHosts
        )
    }

    private func addTab() {
        let controller = makeController()
        let tab = TerminalTab(controller: controller)
        controller.onExit = { closeTab(id: tab.id) }
        tabs.append(tab)
        selectedTab = tab.id
        persistTabs()
    }

    private func restoreTabs() {
        let records = store.savedTabs[host.id.uuidString] ?? []
        guard !records.isEmpty else {
            addTab()
            return
        }
        for record in records {
            let controller = makeController()
            if let session = record.tmuxSession {
                controller.preset(session: session, windowIndex: record.windowIndex)
            } else {
                controller.presetPlain()
            }
            let tab = TerminalTab(controller: controller, name: record.name)
            controller.onExit = { closeTab(id: tab.id) }
            tabs.append(tab)
        }
        selectedTab = tabs.first?.id
    }

    private func closeTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        Task { await tab.controller.stop() }
        tabs.removeAll { $0.id == id }
        tabStatuses[id] = nil
        if selectedTab == id {
            selectedTab = tabs.last?.id
        }
        persistTabs()
        if tabs.isEmpty {
            dismiss()
        }
    }

    private func persistTabs() {
        let records = tabs.map { tab in
            let target = tab.controller.tmuxTarget
            return TabRecord(name: tab.name, tmuxSession: target?.session, windowIndex: target?.windowIndex)
        }
        if store.savedTabs[host.id.uuidString] != records {
            store.savedTabs[host.id.uuidString] = records
        }
    }

    private func pollTabs() {
        var samples: [AgentActivityTracker.Sample] = []
        for (index, tab) in tabs.enumerated() {
            let status = AgentStatus.classify(tab.controller.bridge.visibleText())
            tabStatuses[tab.id] = status
            guard !tab.controller.isTmuxAttached else { continue }
            samples.append(.init(
                key: "tab-\(tab.id.uuidString)",
                title: "\(host.name) \(tab.name ?? "tab \(index + 1)")",
                status: status
            ))
        }
        let transitions = tabTracker.update(samples)
        persistTabs()
        guard UserDefaults.standard.bool(forKey: AppSettings.agentNotifyKey) else { return }
        for transition in transitions {
            let content = UNMutableNotificationContent()
            content.title = transition.status == .waiting ? "Agent needs input" : "Agent finished"
            content.body = transition.title
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "\(transition.key)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            ))
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor(tabStatuses[tab.id] ?? .idle))
                            .frame(width: 6, height: 6)
                        Text(tab.name ?? "\(index + 1)")
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
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
                        Button("Rename Tab") {
                            renameText = tab.name ?? ""
                            renamingTab = tab.id
                        }
                        Button("Close Tab", role: .destructive) {
                            closeTab(id: tab.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.thinMaterial)
        .alert("Rename tab", isPresented: renameAlertShown) {
            TextField("name", text: $renameText)
            Button("Save") { applyRename() }
            Button("Cancel", role: .cancel) { renamingTab = nil }
        }
    }

    private var renameAlertShown: Binding<Bool> {
        Binding(
            get: { renamingTab != nil },
            set: { if !$0 { renamingTab = nil } }
        )
    }

    private func applyRename() {
        guard let id = renamingTab,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        tabs[index].name = trimmed.isEmpty ? nil : trimmed
        renamingTab = nil
        persistTabs()
    }

    private func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .busy: .orange
        case .waiting: .purple
        case .idle: .green
        }
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
    @State private var namingSession = false
    @State private var newSessionName = ""

    let controller: ConnectionController?
    var tabItems: [TabJumpItem] = []
    var onSelectTab: ((UUID) -> Void)?

    private var attached: Bool {
        controller?.isTmuxAttached ?? false
    }

    var body: some View {
        NavigationStack {
            List {
                if tabItems.count > 1 {
                    Section("Tabs") {
                        ForEach(tabItems) { item in
                            Button {
                                onSelectTab?(item.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(tabStatusColor(item.status))
                                            .frame(width: 8, height: 8)
                                        Text(item.label)
                                            .font(.subheadline.weight(.medium))
                                        Text(item.status.label)
                                            .font(.caption2)
                                            .foregroundStyle(tabStatusColor(item.status))
                                        if item.selected {
                                            Spacer()
                                            Image(systemName: "eye")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if !item.preview.isEmpty {
                                        Text(item.preview)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
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
                        Button("New window") {
                            controller?.sendText(Tmux.newWindowKeys)
                            dismiss()
                        }
                        Button("Split side by side") {
                            controller?.sendText(Tmux.splitHorizontalKeys)
                            dismiss()
                        }
                        Button("Split stacked") {
                            controller?.sendText(Tmux.splitVerticalKeys)
                            dismiss()
                        }
                    }
                }
                Section {
                    Button("New session…") {
                        newSessionName = ""
                        namingSession = true
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
            .alert("New tmux session", isPresented: $namingSession) {
                TextField("name", text: $newSessionName)
                Button("Create") {
                    let name = newSessionName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let controller = controller
                    Task { await controller?.createTmuxSession(named: name) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
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

    private func tabStatusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .busy: .orange
        case .waiting: .purple
        case .idle: .green
        }
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
