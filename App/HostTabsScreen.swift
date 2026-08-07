import Models
import MonitorKit
import SwiftUI
import TmuxKit
import UserNotifications

struct TerminalTab: Identifiable {
    let id = UUID()
    let controller: ConnectionController
    var name: String?
    var tmuxWindowName: String?
    var group: String
    let number: Int
}

struct TabJumpItem: Identifiable {
    let id: UUID
    let label: String
    let status: AgentStatus?
    let preview: String
    let selected: Bool
    let session: String?
    let windowIndex: Int?
    let windowID: String?
    let group: String
}

struct TabJumpGroup: Identifiable {
    var id: String { name }
    let name: String
    let items: [TabJumpItem]
}

struct HostTabsScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var monitor: SessionMonitor
    @ObservedObject private var router = NotificationRouter.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var tabs: [TerminalTab] = []
    @State private var selectedTab: UUID?
    @State private var tabStatuses: [UUID: AgentStatus] = [:]
    @State private var unseenFinished: Set<UUID> = []
    @State private var lastTabStatus: [UUID: AgentStatus] = [:]
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
    @State private var menuTab: UUID?
    @State private var tabWidths: [UUID: CGFloat] = [:]
    @State private var tabGroupWidths: [String: CGFloat] = [:]
    @State private var collapsedTabGroups: Set<String> = []
    @State private var loadedCollapsedTabGroups = false
    @State private var draggingTab: UUID?
    @State private var dragCenterX: CGFloat = 0
    @State private var dragGrabDelta: CGFloat = 0

    let host: HostConfig
    var onSwitchHost: ((HostConfig) -> Void)?

    private let tabSpacing: CGFloat = 4
    private let tabStripInset: CGFloat = 8
    private let tabStripSpace = "tabstrip"

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
                        quickReplyOptions: tabQuickReplies[tab.id] ?? [],
                        onQuickReply: { tabQuickReplies[tab.id] = [] }
                    )
                    .opacity(tab.id == selectedTab ? 1 : 0)
                    .allowsHitTesting(tab.id == selectedTab)
                }
            }
        }
        .background(tabShortcuts)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hidesSystemBackButton)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(PocketshellTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            #if targetEnvironment(macCatalyst)
                ToolbarItem(placement: .principal) {
                    hostSwitcher
                }
            #else
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                        hostSwitcher
                            .frame(width: 90, alignment: .leading)
                    }
                }
            #endif
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
            // Exactly three trailing items: a fourth lands in the system
            // overflow menu, which iOS 26 renders but does not open reliably.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        activeController?.findVisible = true
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    Button {
                        showSnippets = true
                    } label: {
                        Label("Snippets", systemImage: "text.badge.plus")
                    }
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
                    addTab()
                } label: {
                    Image(systemName: "plus.square.on.square")
                        .foregroundStyle(PocketshellTheme.accent)
                }
                .keyboardShortcut("t", modifiers: .command)
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
                onSelectTab: selectTab,
                onAddTab: addTab,
                onOpenWindowInNewTab: openWindowInNewTab,
                onRenameSession: renameSessionReferences,
                onRenameTab: { id, name in renameTab(id: id, name: name) },
                onCloseTab: { id in closeTab(id: id) },
                onMoveTab: moveTab
            )
        }
        .sheet(isPresented: $showFiles) {
            FileBrowserView(controller: activeController)
        }
        .sheet(isPresented: $showForward) {
            PortForwardSheet(controller: activeController)
        }
        .onAppear {
            loadCollapsedTabGroups()
            if tabs.isEmpty {
                if !(store.savedTabs[host.id.uuidString] ?? []).isEmpty {
                    restoreTabs()
                    consumePendingTarget()
                }
                Task {
                    await monitor.syncWorkspaceNow(for: host)
                    if tabs.isEmpty {
                        restoreTabs()
                    }
                    consumePendingTarget()
                }
            } else {
                consumePendingTarget()
            }
        }
        .onChange(of: router.pending) { _, _ in
            consumePendingTarget()
        }
        .onChange(of: store.savedTabs[host.id.uuidString]) { _, _ in
            reconcileTabs()
        }
        .onChange(of: monitor.unseenFinished) { old, new in
            for tab in tabs where tab.id != selectedTab {
                if let key = tmuxKey(tab), new.contains(key), !old.contains(key) {
                    promoteTab(id: tab.id)
                }
            }
        }
        .onChange(of: selectedTab, initial: true) { _, _ in
            if let tab = tabs.first(where: { $0.id == selectedTab }) {
                clearUnseen(tab)
            }
            monitor.visibleWindowKey = tabs.first { $0.id == selectedTab }.flatMap(tmuxKey)
            for tab in tabs {
                tab.controller.bridge.setLive(tab.id == selectedTab)
            }
            let focusedElsewhere = tabs.contains { $0.id != selectedTab && $0.controller.bridge.isTerminalFocused }
            if focusedElsewhere {
                tabs.first { $0.id == selectedTab }?.controller.bridge.setTerminalFocused(true)
            }
            activeController?.nudgeTmuxSizing()
        }
        .onDisappear {
            monitor.visibleWindowKey = nil
            for tab in tabs {
                Task { await tab.controller.stop() }
            }
            Task { await monitor.syncWorkspaceNow(for: host) }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                monitor.visibleWindowKey = nil
                return
            }
            monitor.visibleWindowKey = tabs.first { $0.id == selectedTab }.flatMap(tmuxKey)
            activeController?.nudgeTmuxSizing()
            try? await Task.sleep(for: .seconds(1))
            var tick = 0
            while !Task.isCancelled {
                if tick % 3 == 0 {
                    await pollTabs()
                } else {
                    await pollSelectedTab()
                }
                if tick % 9 == 0 {
                    await monitor.syncWorkspaceNow(for: host)
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1.7))
            }
        }
        .paperScreen()
    }

    private var activeController: ConnectionController? {
        tabs.first { $0.id == selectedTab }?.controller
    }

    private var hidesSystemBackButton: Bool {
        #if targetEnvironment(macCatalyst)
            false
        #else
            true
        #endif
    }

    private var hostSwitcher: some View {
        Menu {
            ForEach(store.hosts.filter { $0.id != host.id }) { candidate in
                Button(candidate.name) {
                    onSwitchHost?(candidate)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(host.name)
                    .lineLimit(1)
                    .font(PocketshellTheme.mono(14, weight: .bold))
                    .foregroundStyle(PocketshellTheme.ink)
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(PocketshellTheme.muted)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("host-switcher")
    }

    private var tabJumpItems: [TabJumpItem] {
        tabs.map { tab in
            let text = tab.controller.bridge.visibleText()
            return TabJumpItem(
                id: tab.id,
                label: tabLabel(tab),
                status: tabStatuses[tab.id],
                preview: Tmux.previewLines(text, count: 3),
                selected: tab.id == selectedTab,
                session: tab.controller.tmuxTarget?.session,
                windowIndex: tab.controller.tmuxTarget?.windowIndex,
                windowID: tab.controller.tmuxTarget?.windowID,
                group: tab.group
            )
        }
    }

    private func makeController() -> ConnectionController {
        let currentHost = store.hosts.first { $0.id == host.id } ?? host
        return ConnectionController(
            host: currentHost,
            key: (try? store.key(for: currentHost)) ?? .software(.init()),
            knownHosts: store.knownHosts,
            hops: store.hops(for: currentHost)
        )
    }

    private func addTab() {
        let controller = makeController()
        let tab = TerminalTab(controller: controller, group: "Shells", number: nextTabNumber)
        controller.onExit = { closeTab(id: tab.id) }
        insertTab(tab)
        selectedTab = tab.id
        persistTabs()
    }

    private func openWindowInNewTab(session: String, windowIndex: Int?, windowID: String? = nil, name: String? = nil) {
        let controller = makeController()
        controller.preset(session: session, windowIndex: windowIndex, windowID: windowID)
        let tab = TerminalTab(controller: controller, tmuxWindowName: name, group: session, number: nextTabNumber)
        controller.onExit = { closeTab(id: tab.id) }
        insertTab(tab)
        selectedTab = tab.id
        persistTabs()
    }

    private func selectTab(_ id: UUID, windowName: String? = nil) {
        if let windowName, let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].tmuxWindowName = windowName
            persistTabs()
        }
        selectedTab = id
    }

    private func renameSessionReferences(from oldName: String, to newName: String) {
        for tab in tabs {
            tab.controller.sessionRenamed(from: oldName, to: newName)
        }
        for index in tabs.indices where tabs[index].group == oldName {
            tabs[index].group = newName
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
            if let session = ProcessInfo.processInfo.environment["PS_TEST_FLICKER"] {
                openWindowInNewTab(session: session, windowIndex: 0)
                return
            }
            let fixtures = [
                ("stable", ProcessInfo.processInfo.environment["PS_TEST_STATUS_STABLE"]),
                ("churn", ProcessInfo.processInfo.environment["PS_TEST_STATUS_CHURN"]),
                ("gap", ProcessInfo.processInfo.environment["PS_TEST_STATUS_GAP"]),
            ].compactMap { name, session in session.map { (name, $0) } }
            if fixtures.count == 3 {
                for (name, session) in fixtures {
                    let controller = makeController()
                    controller.preset(session: session, windowIndex: 0)
                    let tab = TerminalTab(controller: controller, name: name, group: session, number: nextTabNumber)
                    controller.onExit = { closeTab(id: tab.id) }
                    insertTab(tab)
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
        for record in TabRecord.grouped(records) {
            tabs.append(makeTab(from: record))
        }
        selectedTab = tabs.first?.id
        persistTabs()
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
            let tab = TerminalTab(controller: controller, group: session, number: nextTabNumber)
            controller.onExit = { closeTab(id: tab.id) }
            insertTab(tab)
            selectedTab = tab.id
            persistTabs()
        }
    }

    private func closeTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        Task { await tab.controller.stop() }
        tabs.removeAll { $0.id == id }
        tabStatuses[id] = nil
        lastTabStatus[id] = nil
        unseenFinished.remove(id)
        tabResolver.forget(key: id.uuidString)
        if selectedTab == id {
            selectedTab = tabs.last?.id
        }
        persistTabs()
        if tabs.isEmpty {
            dismiss()
        }
    }

    private func insertTab(_ tab: TerminalTab) {
        let index = tabs.lastIndex { $0.group == tab.group }.map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(tab, at: index)
    }

    private func moveTab(_ id: UUID, _ group: String, _ after: UUID?) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs.remove(at: source)
        tab.group = group
        let destination =
            after.flatMap { target in tabs.firstIndex(where: { $0.id == target }).map { $0 + 1 } }
            ?? tabs.lastIndex(where: { $0.group == group }).map { $0 + 1 }
            ?? tabs.endIndex
        tabs.insert(tab, at: destination)
        persistTabs()
    }

    private var currentRecords: [TabRecord] {
        tabs.map { tab in
            let target = tab.controller.tmuxTarget
            return TabRecord(
                name: tab.name,
                tmuxSession: target?.session,
                windowIndex: target?.windowIndex,
                number: tab.number,
                windowName: tab.tmuxWindowName,
                windowID: target?.windowID,
                tabGroup: tab.group
            )
        }
    }

    private func persistTabs() {
        let records = currentRecords
        if store.savedTabs[host.id.uuidString] != records {
            store.savedTabs[host.id.uuidString] = records
        }
    }

    private func makeTab(from record: TabRecord) -> TerminalTab {
        let controller = makeController()
        if let session = record.tmuxSession {
            controller.preset(session: session, windowIndex: record.windowIndex, windowID: record.windowID)
        } else {
            controller.presetPlain()
        }
        let tab = TerminalTab(
            controller: controller,
            name: record.name,
            tmuxWindowName: record.windowName,
            group: record.groupName,
            number: record.number ?? nextTabNumber
        )
        controller.onExit = { closeTab(id: tab.id) }
        return tab
    }

    private func reconcileTabs() {
        let records = TabRecord.grouped(store.savedTabs[host.id.uuidString] ?? [])
        guard !tabs.isEmpty, !records.isEmpty, records != currentRecords else { return }
        var remaining = tabs
        var reconciled: [TerminalTab] = []
        for record in records {
            if let index = remaining.firstIndex(where: { tabMatches($0, record) }) {
                var tab = remaining.remove(at: index)
                tab.name = record.name
                if tab.tmuxWindowName == nil { tab.tmuxWindowName = record.windowName }
                tab.group = record.groupName
                reconciled.append(tab)
            } else {
                reconciled.append(makeTab(from: record))
            }
        }
        for tab in remaining {
            Task { await tab.controller.stop() }
            tabStatuses[tab.id] = nil
            lastTabStatus[tab.id] = nil
            unseenFinished.remove(tab.id)
            tabResolver.forget(key: tab.id.uuidString)
        }
        tabs = reconciled
        if !tabs.contains(where: { $0.id == selectedTab }) {
            selectedTab = tabs.first?.id
        }
    }

    private func tabMatches(_ tab: TerminalTab, _ record: TabRecord) -> Bool {
        let target = tab.controller.tmuxTarget
        if let session = record.tmuxSession {
            guard target?.session == session else { return false }
            if let id = record.windowID, let targetID = target?.windowID { return id == targetID }
            return target?.windowIndex == record.windowIndex
        }
        guard let number = record.number else { return false }
        return target == nil && tab.number == number
    }

    private func pollTabs() async {
        var samples: [AgentActivityTracker.Sample] = []
        for tab in tabs {
            guard let sample = await pollTab(tab) else { continue }
            samples.append(sample)
        }
        let transitions = tabTracker.update(samples)
        persistTabs()
        guard UserDefaults.standard.bool(forKey: AppSettings.agentNotifyKey) else { return }
        for transition in transitions {
            if let selectedTab, transition.key == "tab-\(selectedTab.uuidString)" { continue }
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

    private func pollSelectedTab() async {
        guard let tab = tabs.first(where: { $0.id == selectedTab }) else { return }
        _ = await pollTab(tab)
    }

    private func pollTab(_ tab: TerminalTab) async -> AgentActivityTracker.Sample? {
        let text: String
        let agentRunning: Bool?
        if tab.controller.isTmuxAttached {
            guard let snapshot = await tab.controller.currentTmuxPaneSnapshot() else { return nil }
            if let currentIndex = tabs.firstIndex(where: { $0.id == tab.id }),
                !Tmux.isPlaceholderWindowName(snapshot.windowName)
            {
                tabs[currentIndex].tmuxWindowName = snapshot.windowName
            }
            text = snapshot.text
            agentRunning = !Tmux.isInteractiveShell(snapshot.command)
        } else {
            text = tab.controller.bridge.visibleText()
            agentRunning = nil
        }
        let previous = lastTabStatus[tab.id]
        let status = tabResolver.resolve(key: tab.id.uuidString, text: text, agentRunning: agentRunning)
        tabStatuses[tab.id] = status
        if let status { lastTabStatus[tab.id] = status }
        if tab.id == selectedTab {
            clearUnseen(tab)
            monitor.visibleWindowKey = tmuxKey(tab)
        } else if status == .idle, previous == .busy || previous == .waiting {
            markUnseen(tab)
        }
        if status == .waiting, previous != .waiting, tab.id != selectedTab, tab.controller.isTmuxAttached,
            UserDefaults.standard.bool(forKey: AppSettings.agentNotifyKey),
            let key = tmuxKey(tab), monitor.shouldNotify(key: key)
        {
            notifyNeedsInput(tab)
        }
        tabQuickReplies[tab.id] = status == .waiting ? AgentQuickReply.options(in: text) : []
        guard let status, !tab.controller.isTmuxAttached else { return nil }
        return .init(
            key: "tab-\(tab.id.uuidString)",
            title: "\(host.name) \(tabLabel(tab))",
            status: status
        )
    }

    private func notifyNeedsInput(_ tab: TerminalTab) {
        guard let target = tab.controller.tmuxTarget else { return }
        let content = UNMutableNotificationContent()
        content.title = "Agent needs input"
        content.body = "\(host.name) \(tabLabel(tab))"
        content.sound = .default
        var info: [String: Any] = ["hostID": host.id.uuidString, "session": target.session]
        if let windowIndex = target.windowIndex { info["windowIndex"] = windowIndex }
        content.userInfo = info
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "needs-input-\(tab.id)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            ))
    }

    private var tabShortcuts: some View {
        ZStack {
            ForEach(Array(tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
                Button("") { selectedTab = tab.id }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { if let selectedTab { closeTab(id: selectedTab) } }
                .keyboardShortcut("w", modifiers: .command)
            Button("") { activeController?.findVisible = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { cycleTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("") { cycleTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func cycleTab(by delta: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTab }) else { return }
        selectedTab = tabs[(index + delta + tabs.count) % tabs.count].id
    }

    private func slotMidX(_ index: Int) -> CGFloat {
        guard tabs.indices.contains(index) else { return 0 }
        var edge = tabStripInset
        for group in tabGroups {
            edge += (tabGroupWidths[group] ?? 0) + tabSpacing
            guard !collapsedTabGroups.contains(group) else { continue }
            for tab in tabs where tab.group == group {
                let width = tabWidths[tab.id] ?? 0
                if tab.id == tabs[index].id { return edge + width / 2 }
                edge += width + tabSpacing
            }
        }
        return edge
    }

    private func dropTarget(forX x: CGFloat) -> (index: Int, group: String) {
        var edge = tabStripInset
        for group in tabGroups {
            let groupWidth = tabGroupWidths[group] ?? 0
            let first = tabs.firstIndex { $0.group == group } ?? tabs.endIndex
            if x < edge + groupWidth { return (first, group) }
            edge += groupWidth + tabSpacing
            guard !collapsedTabGroups.contains(group) else { continue }
            for (index, tab) in tabs.enumerated() where tab.group == group {
                let width = tabWidths[tab.id] ?? 0
                if x < edge + width / 2 { return (index, group) }
                edge += width + tabSpacing
            }
        }
        return (tabs.count, tabGroups.last ?? "Shells")
    }

    private func applyDrag(id: UUID, start: CGPoint, location: CGPoint) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        if draggingTab != id {
            draggingTab = id
            dragGrabDelta = start.x - slotMidX(from)
        }
        dragCenterX = location.x - dragGrabDelta
        let target = dropTarget(forX: dragCenterX)
        guard target.index != from || target.group != tabs[from].group else { return }
        tabs[from].group = target.group
        if collapsedTabGroups.remove(target.group) != nil { saveCollapsedTabGroups() }
        if target.index != from, target.index != from + 1 {
            withAnimation(.snappy(duration: 0.18)) {
                tabs.move(fromOffsets: IndexSet(integer: from), toOffset: target.index)
            }
        }
    }

    private func endDrag() {
        guard draggingTab != nil else { return }
        withAnimation(.snappy(duration: 0.18)) { draggingTab = nil }
        persistTabs()
    }

    private func reorderGesture(for id: UUID) -> some Gesture {
        let drag = DragGesture(minimumDistance: 4, coordinateSpace: .named(tabStripSpace))
            .onChanged { applyDrag(id: id, start: $0.startLocation, location: $0.location) }
            .onEnded { _ in endDrag() }
        #if targetEnvironment(macCatalyst)
            return drag
        #else
            // Long press first so the strip still scrolls with a plain swipe.
            return LongPressGesture(minimumDuration: 0.28).sequenced(before: drag)
        #endif
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: tabSpacing) {
                ForEach(tabGroups, id: \.self) { group in
                    HStack(spacing: tabSpacing) {
                        tabGroupButton(group)
                        if !collapsedTabGroups.contains(group) {
                            ForEach(tabs.filter { $0.group == group }) { tab in
                                tabButton(tab)
                            }
                        }
                    }
                    .background(tabGroupColor(group).opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(tabGroupColor(group), lineWidth: 1.5))
                }
            }
            .padding(.horizontal, tabStripInset)
            .padding(.vertical, 6)
            .coordinateSpace(.named(tabStripSpace))
        }
        .scrollDisabled(draggingTab != nil)
        .background(PocketshellTheme.paper)
        .alert("Rename tab", isPresented: renameAlertShown) {
            TextField("name", text: $renameText)
            Button("Save") { applyRename() }
            Button("Cancel", role: .cancel) { renamingTab = nil }
        }
        .confirmationDialog("Tab", isPresented: tabMenuShown) {
            Button("Rename Tab") {
                if let id = menuTab, let tab = tabs.first(where: { $0.id == id }) {
                    renameText = tab.name ?? ""
                    renamingTab = id
                }
                menuTab = nil
            }
            Button("Close Tab", role: .destructive) {
                if let id = menuTab {
                    closeTab(id: id)
                }
                menuTab = nil
            }
            Button("Cancel", role: .cancel) { menuTab = nil }
        }
    }

    private var tabGroups: [String] {
        tabs.reduce(into: []) { groups, tab in
            if !groups.contains(tab.group) { groups.append(tab.group) }
        }
    }

    private func tabGroupButton(_ group: String) -> some View {
        let collapsed = collapsedTabGroups.contains(group)
        let color = tabGroupColor(group)
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                if collapsed { collapsedTabGroups.remove(group) } else { collapsedTabGroups.insert(group) }
            }
            saveCollapsedTabGroups()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                Text(group.uppercased())
            }
            .font(PocketshellTheme.mono(8, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group) tab group, \(collapsed ? "collapsed" : "expanded")")
        .accessibilityIdentifier("tab-strip-group-\(group)")
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { tabGroupWidths[group] = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in tabGroupWidths[group] = width }
            }
        }
    }

    private func tabButton(_ tab: TerminalTab) -> some View {
        let index = tabs.firstIndex { $0.id == tab.id } ?? 0
        return HStack(spacing: 5) {
            statusDotView(for: tab)
            Text(tabLabel(tab))
                .font(.footnote.monospaced())
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(tab.id == selectedTab ? PocketshellTheme.accentTint : PocketshellTheme.surface)
        .foregroundStyle(tab.id == selectedTab ? PocketshellTheme.accentDark : PocketshellTheme.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            if tab.id == selectedTab {
                RoundedRectangle(cornerRadius: 8).stroke(PocketshellTheme.accent, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tabAccessibilityLabel(tab))
        .accessibilityIdentifier("terminal-tab-\(tab.number)")
        .accessibilityAddTraits(tab.id == selectedTab ? .isSelected : [])
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { tabWidths[tab.id] = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in tabWidths[tab.id] = width }
            }
        }
        .scaleEffect(draggingTab == tab.id ? 1.06 : 1)
        .shadow(color: .black.opacity(draggingTab == tab.id ? 0.25 : 0), radius: 6, y: 2)
        .offset(x: draggingTab == tab.id ? dragCenterX - slotMidX(index) : 0)
        .zIndex(draggingTab == tab.id ? 1 : 0)
        .transaction { transaction in
            if draggingTab == tab.id { transaction.animation = nil }
        }
        .onTapGesture { selectedTab = tab.id }
        .gesture(reorderGesture(for: tab.id))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.55)
                .onEnded { _ in
                    guard draggingTab == nil else { return }
                    menuTab = tab.id
                }
        )
        .contextMenu {
            Button("Rename Tab") {
                renameText = tab.name ?? ""
                renamingTab = tab.id
            }
            Button("Close Tab", role: .destructive) { closeTab(id: tab.id) }
        }
    }

    private func tabGroupColor(_ group: String) -> Color {
        let colors = ["E8590C", "2563EB", "7C3AED", "15803D", "DB2777", "0891B2"]
        return Color(hexRGB: colors[(tabGroups.firstIndex(of: group) ?? 0) % colors.count])
    }

    private var collapsedTabGroupsKey: String {
        "\(AppSettings.collapsedTabGroupsKeyPrefix).\(host.id.uuidString)"
    }

    private func loadCollapsedTabGroups() {
        guard !loadedCollapsedTabGroups else { return }
        loadedCollapsedTabGroups = true
        collapsedTabGroups = Set(UserDefaults.standard.stringArray(forKey: collapsedTabGroupsKey) ?? [])
    }

    private func saveCollapsedTabGroups() {
        UserDefaults.standard.set(collapsedTabGroups.sorted(), forKey: collapsedTabGroupsKey)
    }

    private var tabMenuShown: Binding<Bool> {
        Binding(
            get: { menuTab != nil },
            set: { if !$0 { menuTab = nil } }
        )
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

    private var nextTabNumber: Int {
        (tabs.map(\.number).max() ?? 0) + 1
    }

    private func tabLabel(_ tab: TerminalTab) -> String {
        tab.name ?? tab.tmuxWindowName ?? "\(tab.number)"
    }

    private func tabAccessibilityLabel(_ tab: TerminalTab) -> String {
        let status = tabStatuses[tab.id]?.label ?? "no status"
        let unseen = isUnseen(tab) ? ", unseen" : ""
        return "\(tabLabel(tab)), \(status)\(unseen)"
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

    private func tmuxKey(_ tab: TerminalTab) -> String? {
        guard let target = tab.controller.tmuxTarget, let index = target.windowIndex else { return nil }
        return SessionMonitor.windowKey(hostID: host.id, session: target.session, windowIndex: index)
    }

    private func isUnseen(_ tab: TerminalTab) -> Bool {
        if unseenFinished.contains(tab.id) { return true }
        guard let key = tmuxKey(tab) else { return false }
        return monitor.unseenFinished.contains(key)
    }

    private func markUnseen(_ tab: TerminalTab) {
        if let target = tab.controller.tmuxTarget, let index = target.windowIndex {
            monitor.markFinished(hostID: host.id, session: target.session, windowIndex: index)
        } else {
            unseenFinished.insert(tab.id)
        }
        promoteTab(id: tab.id)
    }

    private func clearUnseen(_ tab: TerminalTab) {
        unseenFinished.remove(tab.id)
        if let target = tab.controller.tmuxTarget, let index = target.windowIndex {
            monitor.markSeen(hostID: host.id, session: target.session, windowIndex: index)
        }
    }

    private func promoteTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            let first = tabs.firstIndex(where: { $0.group == tabs[index].group }), index > first
        else { return }
        tabs.move(fromOffsets: IndexSet(integer: index), toOffset: first)
        persistTabs()
    }

    @ViewBuilder
    private func statusDotView(for tab: TerminalTab) -> some View {
        if let status = tabStatuses[tab.id] {
            let unseen = status == .idle && isUnseen(tab)
            Circle()
                .fill(unseen ? Color.blue : statusColor(status))
                .frame(width: unseen ? 7 : 6, height: unseen ? 7 : 6)
                .shadow(color: unseen ? Color.blue.opacity(0.6) : Color.clear, radius: 3)
        }
    }

    private func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .busy: PocketshellTheme.busy
        case .waiting: PocketshellTheme.waiting
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

        var confirmTitle: String {
            switch self {
            case .session(let name):
                "Delete tmux session \(name)? Kills all its windows."
            case .window(_, _, let name):
                "Delete window \(name)? Kills its shell."
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
    var onSelectTab: ((UUID, String?) -> Void)?
    var onAddTab: (() -> Void)?
    var onOpenWindowInNewTab: ((String, Int?, String?, String?) -> Void)?
    var onRenameSession: ((String, String) -> Void)?
    var onRenameTab: ((UUID, String) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onMoveTab: ((UUID, String, UUID?) -> Void)?

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
            VStack(spacing: 0) {
                tabsPanel
                List {
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
                                        selectOrOpenWindow(item, session: session.name)
                                    } label: {
                                        windowRow(item, session: session.name)
                                    }
                                    .accessibilityIdentifier("tmux-window-\(session.name)-\(item.window.index)")
                                    .contextMenu {
                                        Button("Open in New Tab") {
                                            onOpenWindowInNewTab?(
                                                session.name, item.window.index, item.window.windowID,
                                                item.window.name)
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
                                        jump(toSession: session.name, windowIndex: nil, windowID: nil)
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
                            if query.isEmpty, expandedSessions.contains(session.name) {
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
                                .buttonStyle(.plain)
                                .padding(.leading, 20)
                            }
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
            }
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

    private var tabsPanel: some View {
        VStack(spacing: 4) {
            sectionHeader("Tabs", expanded: $tabsExpanded, action: "+ Tab") {
                onAddTab?()
                dismiss()
            }
            if tabsExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(filteredTabGroups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(group.name.uppercased())
                                    .font(PocketshellTheme.mono(8, weight: .bold))
                                    .foregroundStyle(PocketshellTheme.muted)
                                    .accessibilityIdentifier("tab-group-\(group.name)")
                                HStack(spacing: 10) {
                                    ForEach(group.items) { item in
                                        tabCard(item)
                                            .draggable(item.id.uuidString)
                                            .dropDestination(for: String.self) { identifiers, _ in
                                                guard let source = identifiers.first.flatMap(UUID.init(uuidString:)),
                                                    source != item.id
                                                else { return false }
                                                onMoveTab?(source, group.name, item.id)
                                                return true
                                            }
                                            .contextMenu {
                                                Button("Rename…") {
                                                    promptText = item.label
                                                    prompt = .renameTab(item.id)
                                                }
                                                Button("Close", role: .destructive) {
                                                    onCloseTab?(item.id)
                                                }
                                            }
                                    }
                                }
                                .padding(6)
                                .background(PocketshellTheme.secondarySurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .dropDestination(for: String.self) { identifiers, _ in
                                    guard let source = identifiers.first.flatMap(UUID.init(uuidString:)) else {
                                        return false
                                    }
                                    onMoveTab?(source, group.name, nil)
                                    return true
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, tabsExpanded ? 0 : 16)
        .padding(.vertical, 8)
    }

    private var hostLabel: String {
        hostName
    }

    private var filteredTabItems: [TabJumpItem] {
        guard !query.isEmpty else { return tabItems }
        return tabItems.filter { item in
            [item.label, item.preview, item.session ?? "", item.group]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var filteredTabGroups: [TabJumpGroup] {
        var groups: [TabJumpGroup] = []
        for item in filteredTabItems {
            if let index = groups.firstIndex(where: { $0.name == item.group }) {
                groups[index] = TabJumpGroup(name: item.group, items: groups[index].items + [item])
            } else {
                groups.append(TabJumpGroup(name: item.group, items: [item]))
            }
        }
        return groups
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
            .buttonStyle(.borderless)
            .accessibilityIdentifier("toggle-tabs")
            Button(action, action: perform)
                .font(PocketshellTheme.mono(10, weight: .bold))
                .foregroundStyle(PocketshellTheme.accent)
                .buttonStyle(.borderless)
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
            onSelectTab?(item.id, nil)
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
        .accessibilityIdentifier("switcher-tab-\(item.label)")
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
            if let tab = attachedTab(
                session: session, windowIndex: item.window.index, windowID: item.window.windowID)
            {
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

    private func attachedTab(session: String, windowIndex: Int, windowID: String?) -> TabJumpItem? {
        tabItems.first {
            guard $0.session == session else { return false }
            if let windowID, let tabWindowID = $0.windowID { return tabWindowID == windowID }
            return $0.windowIndex == windowIndex
        }
    }

    private func selectOrOpenWindow(_ item: WindowDashboardItem, session: String) {
        if let tab = attachedTab(
            session: session, windowIndex: item.window.index, windowID: item.window.windowID)
        {
            onSelectTab?(tab.id, item.window.name)
        } else {
            onOpenWindowInNewTab?(session, item.window.index, item.window.windowID, item.window.name)
        }
        dismiss()
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
                onOpenWindowInNewTab?(name, nil, nil, name)
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
        }
    }

    private func jump(toSession session: String, windowIndex: Int?, windowID: String? = nil) {
        let controller = controller
        Task { await controller?.jump(toSession: session, windowIndex: windowIndex, windowID: windowID) }
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
        case .busy: PocketshellTheme.busy
        case .waiting: PocketshellTheme.waiting
        case .idle: PocketshellTheme.idle
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
