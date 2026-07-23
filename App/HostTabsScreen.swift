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
    let status: AgentStatus?
    let preview: String
    let selected: Bool
    let session: String?
    let windowIndex: Int?
}

struct HostTabsScreen: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var router = NotificationRouter.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var tabs: [TerminalTab] = []
    @State private var selectedTab: UUID?
    @State private var tabStatuses: [UUID: AgentStatus] = [:]
    @State private var tabQuickReplies: [UUID: [Int]] = [:]
    @State private var tabTracker = AgentActivityTracker()
    @State private var tabResolver = TabStatusResolver()
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
                    TerminalScreen(
                        connection: tab.controller,
                        host: host,
                        isActive: tab.id == selectedTab,
                        quickReplyOptions: tabQuickReplies[tab.id] ?? []
                    )
                    .opacity(tab.id == selectedTab ? 1 : 0)
                    .allowsHitTesting(tab.id == selectedTab)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(PocketshellTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Text(host.name)
                        .font(PocketshellTheme.mono(14, weight: .bold))
                        .foregroundStyle(PocketshellTheme.ink)
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 7, height: 7)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTmuxJump = true
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                }
                #if targetEnvironment(macCatalyst)
                    .keyboardShortcut("k", modifiers: .command)
                #endif
                .accessibilityIdentifier("tmux-sessions")
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
                        .foregroundStyle(PocketshellTheme.accent)
                }
                .accessibilityIdentifier("new-tab")
            }
        }
        .sheet(isPresented: $showSnippets) {
            snippetPicker
        }
        .sheet(isPresented: $showTmuxJump) {
            TmuxJumpSheet(
                controller: activeController,
                tabItems: tabJumpItems,
                hostName: host.name,
                orderKey: host.id.uuidString,
                onSelectTab: { id in selectedTab = id },
                onAddTab: addTab,
                onOpenWindowInNewTab: openWindowInNewTab,
                onRenameSession: renameSessionReferences,
                onRenameTab: { id, name in renameTab(id: id, name: name) },
                onCloseTab: { id in closeTab(id: id) },
                onMoveTab: { from, to in
                    guard from.allSatisfy({ $0 < tabs.count }) else { return }
                    tabs.move(fromOffsets: from, toOffset: min(to, tabs.count))
                    persistTabs()
                }
            )
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
            consumePendingTarget()
        }
        .onChange(of: router.pending) { _, _ in
            consumePendingTarget()
        }
        .onChange(of: selectedTab, initial: true) { _, _ in
            for tab in tabs {
                tab.controller.bridge.setLive(tab.id == selectedTab)
            }
            let focusedElsewhere = tabs.contains { $0.id != selectedTab && $0.controller.bridge.isTerminalFocused }
            if focusedElsewhere {
                tabs.first { $0.id == selectedTab }?.controller.bridge.setTerminalFocused(true)
            }
        }
        .onDisappear {
            for tab in tabs {
                Task { await tab.controller.stop() }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                await pollTabs()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .paperScreen()
    }

    private var activeController: ConnectionController? {
        tabs.first { $0.id == selectedTab }?.controller
    }

    private var tabJumpItems: [TabJumpItem] {
        tabs.enumerated().map { index, tab in
            let text = tab.controller.bridge.visibleText()
            return TabJumpItem(
                id: tab.id,
                label: tab.name ?? "tab \(index + 1)",
                status: tabStatuses[tab.id],
                preview: Tmux.previewLines(text, count: 3),
                selected: tab.id == selectedTab,
                session: tab.controller.tmuxTarget?.session,
                windowIndex: tab.controller.tmuxTarget?.windowIndex
            )
        }
    }

    private func makeController() -> ConnectionController {
        let currentHost = store.hosts.first { $0.id == host.id } ?? host
        return ConnectionController(
            host: currentHost,
            key: (try? store.key(for: currentHost)) ?? .software(.init()),
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

    private func openWindowInNewTab(session: String, windowIndex: Int?, name: String? = nil) {
        let controller = makeController()
        controller.preset(session: session, windowIndex: windowIndex)
        let tab = TerminalTab(controller: controller, name: name)
        controller.onExit = { closeTab(id: tab.id) }
        tabs.append(tab)
        selectedTab = tab.id
        persistTabs()
    }

    private func renameSessionReferences(from oldName: String, to newName: String) {
        for tab in tabs {
            tab.controller.sessionRenamed(from: oldName, to: newName)
        }
        if let index = store.hosts.firstIndex(where: { $0.id == host.id }),
            store.hosts[index].tmuxSession == oldName
        {
            store.hosts[index].tmuxSession = newName
        }
        persistTabs()
    }

    private func restoreTabs() {
        if ProcessInfo.processInfo.environment["PS_UI_TEST"] == "1" {
            let fixtures = [
                ("stable", ProcessInfo.processInfo.environment["PS_TEST_STATUS_STABLE"]),
                ("churn", ProcessInfo.processInfo.environment["PS_TEST_STATUS_CHURN"]),
                ("gap", ProcessInfo.processInfo.environment["PS_TEST_STATUS_GAP"]),
            ].compactMap { name, session in session.map { (name, $0) } }
            if fixtures.count == 3 {
                for (name, session) in fixtures {
                    let controller = makeController()
                    controller.preset(session: session, windowIndex: 0)
                    let tab = TerminalTab(controller: controller, name: name)
                    controller.onExit = { closeTab(id: tab.id) }
                    tabs.append(tab)
                }
                selectedTab = tabs.first?.id
                return
            }
        }
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

    private func consumePendingTarget() {
        guard let target = router.pending, target.hostID == host.id else { return }
        router.pending = nil
        guard let session = target.session else { return }
        if let tab = tabs.first(where: { $0.controller.tmuxTarget?.session == session }) {
            selectedTab = tab.id
            Task { await tab.controller.jump(toSession: session, windowIndex: target.windowIndex) }
        } else {
            let controller = makeController()
            controller.preset(session: session, windowIndex: target.windowIndex)
            let tab = TerminalTab(controller: controller)
            controller.onExit = { closeTab(id: tab.id) }
            tabs.append(tab)
            selectedTab = tab.id
            persistTabs()
        }
    }

    private func closeTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        Task { await tab.controller.stop() }
        tabs.removeAll { $0.id == id }
        tabStatuses[id] = nil
        tabResolver.forget(key: id.uuidString)
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

    private func pollTabs() async {
        var samples: [AgentActivityTracker.Sample] = []
        for (index, tab) in tabs.enumerated() {
            let text: String
            let agentRunning: Bool?
            if tab.controller.isTmuxAttached {
                guard let snapshot = await tab.controller.currentTmuxPaneSnapshot() else { continue }
                text = snapshot.text
                agentRunning = !Tmux.isInteractiveShell(snapshot.command)
            } else {
                text = tab.controller.bridge.visibleText()
                agentRunning = nil
            }
            let status = tabResolver.resolve(key: tab.id.uuidString, text: text, agentRunning: agentRunning)
            tabStatuses[tab.id] = status
            tabQuickReplies[tab.id] = status == .waiting ? AgentQuickReply.options(in: text) : []
            guard let status, !tab.controller.isTmuxAttached else { continue }
            samples.append(
                .init(
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
            content.userInfo = ["hostID": host.id.uuidString]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
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
                        if let status = tabStatuses[tab.id] {
                            Circle()
                                .fill(statusColor(status))
                                .frame(width: 6, height: 6)
                        }
                        Text(tab.name ?? "\(index + 1)")
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        tab.id == selectedTab
                            ? PocketshellTheme.accentTint
                            : PocketshellTheme.surface
                    )
                    .foregroundStyle(
                        tab.id == selectedTab ? PocketshellTheme.accentDark : PocketshellTheme.secondary
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                tab.id == selectedTab ? PocketshellTheme.accentBorder : PocketshellTheme.border
                            )
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(tab.name ?? "tab \(index + 1)"), \(tabStatuses[tab.id]?.label ?? "no status")"
                    )
                    .accessibilityIdentifier("terminal-tab-\(index + 1)")
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
            .padding(.vertical, 6)
        }
        .background(PocketshellTheme.paper)
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

    private func renameTab(id: UUID, name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        tabs[index].name = trimmed.isEmpty ? nil : trimmed
        persistTabs()
    }

    private func applyRename() {
        guard let id = renamingTab,
            let index = tabs.firstIndex(where: { $0.id == id })
        else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        tabs[index].name = trimmed.isEmpty ? nil : trimmed
        renamingTab = nil
        persistTabs()
    }

    private func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .busy: PocketshellTheme.busy
        case .waiting: PocketshellTheme.accent
        case .idle: PocketshellTheme.idle
        }
    }

    private var connectionColor: Color {
        guard let controller = activeController else { return PocketshellTheme.faint }
        switch controller.phase {
        case .attached: return PocketshellTheme.idle
        case .connecting, .reconnecting: return PocketshellTheme.busy
        case .failed, .exited: return .red
        default: return PocketshellTheme.faint
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
    private enum Prompt: Identifiable {
        case newSession
        case renameSession(String)
        case renameWindow(session: String, index: Int)
        case renameTab(UUID)

        var id: String {
            switch self {
            case .newSession: "new"
            case .renameSession(let name): "rs-\(name)"
            case .renameWindow(let session, let index): "rw-\(session)-\(index)"
            case .renameTab(let id): "rt-\(id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case .newSession: "New tmux session"
            case .renameSession: "Rename session"
            case .renameWindow: "Rename window"
            case .renameTab: "Rename tab"
            }
        }
    }

    private enum KillTarget {
        case session(String)
        case window(session: String, index: Int, name: String)
        case tab(id: UUID, label: String)

        var confirmTitle: String {
            switch self {
            case .session(let name):
                "Delete tmux session \(name)? Kills all its windows."
            case .window(_, _, let name):
                "Delete window \(name)? Kills its shell."
            case .tab(_, let label):
                "Close tab \(label)?"
            }
        }
    }

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [TmuxSession] = []
    @State private var windowsBySession: [String: [WindowDashboardItem]] = [:]
    @State private var expandedSessions: Set<String> = []
    @State private var loaded = false
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var killTarget: KillTarget?
    @State private var query = ""
    @State private var searchPresented = false
    @AppStorage(AppSettings.tmuxTabsExpandedKey) private var tabsExpanded = true

    let controller: ConnectionController?
    var tabItems: [TabJumpItem] = []
    var hostName = "host"
    var orderKey: String?
    var onSelectTab: ((UUID) -> Void)?
    var onAddTab: (() -> Void)?
    var onOpenWindowInNewTab: ((String, Int?, String?) -> Void)?
    var onRenameSession: ((String, String) -> Void)?
    var onRenameTab: ((UUID, String) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onMoveTab: ((IndexSet, Int) -> Void)?

    private var attached: Bool {
        controller?.isTmuxAttached ?? false
    }

    private var currentSession: String? {
        controller?.tmuxTarget?.session
    }

    private var expandedSessionsKey: String? {
        orderKey.map { "\(AppSettings.tmuxExpandedSessionsKeyPrefix).\($0)" }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sectionHeader("Tabs", expanded: $tabsExpanded, action: "+ Tab") {
                        onAddTab?()
                        dismiss()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    if tabsExpanded {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(filteredTabItems) { item in
                                    tabCard(item)
                                        .draggable(item.id.uuidString)
                                        .dropDestination(for: String.self) { identifiers, _ in
                                            guard let identifier = identifiers.first,
                                                let sourceID = tabItems.firstIndex(where: {
                                                    $0.id.uuidString == identifier
                                                }),
                                                let targetID = tabItems.firstIndex(where: { $0.id == item.id }),
                                                sourceID != targetID
                                            else { return false }
                                            onMoveTab?(
                                                IndexSet(integer: sourceID),
                                                targetID > sourceID ? targetID + 1 : targetID
                                            )
                                            return true
                                        }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                Section {
                    if filteredSessions.isEmpty, loaded {
                        Text(query.isEmpty ? "No tmux sessions found" : "No matches")
                            .font(PocketshellTheme.mono(11))
                            .foregroundStyle(PocketshellTheme.muted)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(filteredSessions) { session in
                        DisclosureGroup(isExpanded: expandedBinding(session.name)) {
                            ForEach(filteredWindows(in: session)) { item in
                                Button {
                                    jump(toSession: session.name, windowIndex: item.window.index)
                                } label: {
                                    windowRow(item, session: session.name)
                                }
                                .accessibilityIdentifier("tmux-window-\(session.name)-\(item.window.index)")
                                .contextMenu {
                                    Button("Open in New Tab") {
                                        onOpenWindowInNewTab?(session.name, item.window.index, item.window.name)
                                        dismiss()
                                    }
                                    Button("Rename…") {
                                        promptText = item.window.name
                                        prompt = .renameWindow(session: session.name, index: item.window.index)
                                    }
                                    Button("Delete", role: .destructive) {
                                        killTarget = .window(
                                            session: session.name, index: item.window.index, name: item.window.name)
                                    }
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) {
                                        killTarget = .window(
                                            session: session.name, index: item.window.index, name: item.window.name)
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button("Rename") {
                                        promptText = item.window.name
                                        prompt = .renameWindow(session: session.name, index: item.window.index)
                                    }
                                    .tint(.blue)
                                }
                                .listRowBackground(
                                    item.status == .waiting ? PocketshellTheme.accentTint : PocketshellTheme.surface
                                )
                            }
                            .onMove { from, to in
                                moveWindows(session: session.name, from: from, to: to)
                            }
                            if query.isEmpty {
                                Button {
                                    Task {
                                        await controller?.createTmuxWindow(in: session.name)
                                        await load()
                                    }
                                } label: {
                                    Label("new window in \(session.name)", systemImage: "plus")
                                        .font(PocketshellTheme.mono(10, weight: .semibold))
                                        .foregroundStyle(PocketshellTheme.muted)
                                }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Text(session.name)
                                    .font(PocketshellTheme.mono(12.5, weight: .bold))
                                Text("\(session.windows) windows")
                                    .font(PocketshellTheme.mono(9))
                                    .foregroundStyle(PocketshellTheme.muted)
                            }
                            .contextMenu {
                                Button("Attach") {
                                    jump(toSession: session.name, windowIndex: nil)
                                }
                                Button("Rename…") {
                                    promptText = session.name
                                    prompt = .renameSession(session.name)
                                }
                                Button("Delete", role: .destructive) {
                                    killTarget = .session(session.name)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    killTarget = .session(session.name)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Rename") {
                                    promptText = session.name
                                    prompt = .renameSession(session.name)
                                }
                                .tint(.blue)
                            }
                        }
                        .accessibilityIdentifier("tmux-session-\(session.name)")
                        .listRowBackground(PocketshellTheme.secondarySurface)
                    }
                    .onMove { from, to in
                        guard query.isEmpty, from.allSatisfy({ $0 < sessions.count }) else { return }
                        sessions.move(fromOffsets: from, toOffset: min(to, sessions.count))
                        if let orderKey {
                            store.sessionOrder[orderKey] = sessions.map(\.name)
                        }
                    }
                } header: {
                    actionHeader("Tmux · on \(hostLabel)", action: "+ Session") {
                        promptText = ""
                        prompt = .newSession
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Switcher")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                isPresented: $searchPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search tabs, sessions, windows"
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .task {
                await load()
            }
            .onAppear {
                #if targetEnvironment(macCatalyst)
                    searchPresented = true
                #endif
            }
            .alert(prompt?.title ?? "", isPresented: promptShown) {
                TextField("name", text: $promptText)
                Button("OK") { applyPrompt() }
                Button("Cancel", role: .cancel) { prompt = nil }
            }
            .confirmationDialog(
                killTarget?.confirmTitle ?? "",
                isPresented: killShown,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { applyKill() }
                Button("Cancel", role: .cancel) { killTarget = nil }
            }
            .paperScreen()
        }
    }

    private var hostLabel: String {
        hostName
    }

    private var filteredTabItems: [TabJumpItem] {
        guard !query.isEmpty else { return tabItems }
        return tabItems.filter { item in
            [item.label, item.preview, item.session ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var filteredSessions: [TmuxSession] {
        guard !query.isEmpty else { return sessions }
        return sessions.filter { session in
            session.name.localizedCaseInsensitiveContains(query) || !filteredWindows(in: session).isEmpty
        }
    }

    private func filteredWindows(in session: TmuxSession) -> [WindowDashboardItem] {
        let items = windowsBySession[session.name] ?? []
        guard !query.isEmpty, !session.name.localizedCaseInsensitiveContains(query) else { return items }
        return items.filter { item in
            [item.window.name, item.preview, item.status.label]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func sectionHeader(_ title: String, expanded: Binding<Bool>, action: String, perform: @escaping () -> Void)
        -> some View
    {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(PocketshellTheme.mono(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(PocketshellTheme.muted)
            Rectangle().fill(PocketshellTheme.divider).frame(height: 1)
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PocketshellTheme.muted)
            }
            Button(action, action: perform)
                .font(PocketshellTheme.mono(10, weight: .bold))
                .foregroundStyle(PocketshellTheme.accent)
        }
        .textCase(nil)
    }

    private func actionHeader(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(PocketshellTheme.mono(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(PocketshellTheme.muted)
            Rectangle().fill(PocketshellTheme.divider).frame(height: 1)
            Button(action, action: perform)
                .font(PocketshellTheme.mono(10, weight: .bold))
                .foregroundStyle(PocketshellTheme.accent)
        }
        .textCase(nil)
    }

    private func tabCard(_ item: TabJumpItem) -> some View {
        Button {
            onSelectTab?(item.id)
            dismiss()
        } label: {
            VStack(spacing: 0) {
                Text(item.preview.isEmpty ? "plain shell" : item.preview)
                    .font(PocketshellTheme.mono(7.5))
                    .foregroundStyle(Color(hexRGB: "D7DBDF"))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
                    .padding(7)
                    .background(Color(hexRGB: "101214"))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(item.status?.chromeColor ?? PocketshellTheme.faint)
                            .frame(width: 6, height: 6)
                        Text(item.label)
                            .font(PocketshellTheme.mono(10, weight: .bold))
                            .foregroundStyle(PocketshellTheme.ink)
                            .lineLimit(1)
                    }
                    Text(tabAttachment(item))
                        .font(PocketshellTheme.mono(8))
                        .foregroundStyle(PocketshellTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(PocketshellTheme.surface)
            }
            .frame(width: 128)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        item.selected ? PocketshellTheme.accent : PocketshellTheme.border,
                        lineWidth: item.selected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") {
                promptText = item.label
                prompt = .renameTab(item.id)
            }
            Button("Close", role: .destructive) {
                killTarget = .tab(id: item.id, label: item.label)
            }
        }
    }

    private func tabAttachment(_ item: TabJumpItem) -> String {
        guard let session = item.session else { return "plain shell · no tmux" }
        return "⌗ \(session) › \(item.windowIndex.map(String.init) ?? "current")"
    }

    private func windowRow(_ item: WindowDashboardItem, session: String) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(item.status.chromeColor)
                .frame(width: 7, height: 7)
                .shadow(color: item.status == .waiting ? item.status.chromeColor.opacity(0.4) : .clear, radius: 4)
            Text("\(item.window.index): \(item.window.name)")
                .font(PocketshellTheme.mono(12, weight: .semibold))
                .foregroundStyle(PocketshellTheme.body)
                .lineLimit(1)
            Text(item.status.label)
                .font(PocketshellTheme.mono(10))
                .foregroundStyle(item.status.chromeTextColor)
            Spacer()
            if let tab = attachedTab(session: session, windowIndex: item.window.index) {
                Text("IN \"\(tab.label.uppercased())\"")
                    .font(PocketshellTheme.mono(8.5, weight: .bold))
                    .foregroundStyle(item.status == .waiting ? PocketshellTheme.accentDark : PocketshellTheme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(item.status == .waiting ? PocketshellTheme.accentTint : PocketshellTheme.surface)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(
                            item.status == .waiting ? PocketshellTheme.accentBorder : PocketshellTheme.border))
            } else {
                Text("ATTACH ›")
                    .font(PocketshellTheme.mono(9, weight: .bold))
                    .foregroundStyle(PocketshellTheme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func attachedTab(session: String, windowIndex: Int) -> TabJumpItem? {
        tabItems.first { $0.session == session && $0.windowIndex == windowIndex }
    }

    private var promptShown: Binding<Bool> {
        Binding(
            get: { prompt != nil },
            set: { if !$0 { prompt = nil } }
        )
    }

    private var killShown: Binding<Bool> {
        Binding(
            get: { killTarget != nil },
            set: { if !$0 { killTarget = nil } }
        )
    }

    private func applyPrompt() {
        guard let prompt else { return }
        self.prompt = nil
        let name = promptText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let controller = controller
        switch prompt {
        case .newSession:
            Task {
                guard await controller?.createTmuxSession(named: name) == true else { return }
                onOpenWindowInNewTab?(name, nil, name)
                dismiss()
            }
        case .renameSession(let old):
            Task {
                guard await controller?.renameTmuxSession(from: old, to: name) == true else { return }
                if let orderKey, var saved = store.sessionOrder[orderKey], let index = saved.firstIndex(of: old) {
                    saved[index] = name
                    store.sessionOrder[orderKey] = saved
                }
                onRenameSession?(old, name)
                await load()
            }
        case .renameWindow(let session, let index):
            Task {
                await controller?.renameTmuxWindow(session: session, windowIndex: index, name: name)
                await load()
            }
        case .renameTab(let id):
            onRenameTab?(id, name)
        }
    }

    private func applyKill() {
        guard let killTarget else { return }
        self.killTarget = nil
        let controller = controller
        switch killTarget {
        case .session(let name):
            let isCurrent = name == currentSession
            Task {
                await controller?.killTmuxSession(named: name)
                if isCurrent {
                    dismiss()
                } else {
                    await load()
                }
            }
        case .window(let session, let index, _):
            Task {
                await controller?.killTmuxWindow(session: session, windowIndex: index)
                await load()
            }
        case .tab(let id, _):
            onCloseTab?(id)
        }
    }

    private func jump(toSession session: String, windowIndex: Int?) {
        let controller = controller
        Task { await controller?.jump(toSession: session, windowIndex: windowIndex) }
        dismiss()
    }

    private func moveWindows(session: String, from: IndexSet, to: Int) {
        var items = windowsBySession[session] ?? []
        guard let first = from.first, from.count == 1, first < items.count else { return }
        let dest = min(max(to, 0), items.count)
        let indexes = items.map(\.window.index)
        guard dest != first, dest != first + 1 else { return }
        items.move(fromOffsets: from, toOffset: dest)
        windowsBySession[session] = items
        let controller = controller
        Task {
            await controller?.reorderTmuxWindows(session: session, indexes: indexes, fromOffset: first, toOffset: dest)
            await load()
        }
    }

    private func tabStatusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .busy: .orange
        case .waiting: .purple
        case .idle: .green
        }
    }

    private func expandedBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { !query.isEmpty || expandedSessions.contains(name) },
            set: { expanded in
                guard query.isEmpty else { return }
                if expanded {
                    expandedSessions.insert(name)
                } else {
                    expandedSessions.remove(name)
                }
                if let expandedSessionsKey {
                    UserDefaults.standard.set(expandedSessions.sorted(), forKey: expandedSessionsKey)
                }
            }
        )
    }

    private func load() async {
        guard let controller else {
            loaded = true
            return
        }
        var list = await controller.tmuxSessions()
        if let orderKey, let saved = store.sessionOrder[orderKey] {
            list = Tmux.orderSessions(list, by: saved)
        }
        sessions = list
        var map: [String: [WindowDashboardItem]] = [:]
        for session in sessions {
            map[session.name] = await controller.dashboardItems(session: session.name)
        }
        windowsBySession = map
        if let expandedSessionsKey,
            let saved = UserDefaults.standard.stringArray(forKey: expandedSessionsKey)
        {
            expandedSessions = Set(saved)
        } else if expandedSessions.isEmpty {
            let initial = currentSession ?? sessions.first { $0.attached }?.name ?? sessions.first?.name
            if let initial {
                expandedSessions = [initial]
            }
        }
        loaded = true
    }
}
