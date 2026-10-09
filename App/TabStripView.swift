import Models
import SwiftUI
import TmuxKit

struct TabStripView: View {
    @Binding var tabs: [TerminalTab]
    @Binding var selectedTab: UUID?
    @Binding var collapsedTabGroups: Set<String>
    @Binding var menuTab: UUID?
    @Binding var renamingTab: UUID?
    @Binding var renameText: String
    let tabStatuses: [UUID: AgentStatus]
    let tabLabel: (TerminalTab) -> String
    let isUnseen: (TerminalTab) -> Bool
    let onClose: (UUID) -> Void
    let onPersist: () -> Void
    let onSaveCollapsed: () -> Void
    let onApplyRename: () -> Void

    @State private var tabWidths: [UUID: CGFloat] = [:]
    @State private var tabGroupWidths: [String: CGFloat] = [:]
    @State private var draggingTab: UUID?
    @State private var dragCenterX: CGFloat = 0
    @State private var dragGrabDelta: CGFloat = 0

    private let tabSpacing: CGFloat = 4
    private let tabStripInset: CGFloat = 8
    private let tabStripSpace = "tabstrip"

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
        if collapsedTabGroups.remove(target.group) != nil { onSaveCollapsed() }
        if target.index != from, target.index != from + 1 {
            withAnimation(.snappy(duration: 0.18)) {
                tabs.move(fromOffsets: IndexSet(integer: from), toOffset: target.index)
            }
        }
    }

    private func endDrag() {
        guard draggingTab != nil else { return }
        withAnimation(.snappy(duration: 0.18)) { draggingTab = nil }
        onPersist()
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

    var body: some View {
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
            Button("Save") { onApplyRename() }
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
                    onClose(id)
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
            onSaveCollapsed()
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
            Button("Close Tab", role: .destructive) { onClose(tab.id) }
        }
    }

    private func tabGroupColor(_ group: String) -> Color {
        let colors = ["E8590C", "2563EB", "7C3AED", "15803D", "DB2777", "0891B2"]
        return Color(hexRGB: colors[(tabGroups.firstIndex(of: group) ?? 0) % colors.count])
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

    private func tabAccessibilityLabel(_ tab: TerminalTab) -> String {
        let status = tabStatuses[tab.id]?.label ?? "no status"
        let unseen = isUnseen(tab) ? ", unseen" : ""
        return "\(tabLabel(tab)), \(status)\(unseen)"
    }
}
