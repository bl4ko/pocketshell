import KeyKit
import Models
import SwiftUI

struct HostsListView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var monitor: SessionMonitor
    @AppStorage(AppSettings.terminalThemeKey) private var themeName = TerminalTheme.defaultTheme.name
    @ObservedObject private var router = NotificationRouter.shared
    @State private var path = NavigationPath()
    @State private var editingHost: HostConfig?
    @State private var addingHost = false
    @State private var addingVNCHost = false
    @State private var editingVNCHost: VNCHostConfig?
    @State private var runningSnippet: SnippetRun?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    header
                    if let snapshot = monitor.snapshot, !snapshot.windows.isEmpty {
                        agentSummary(snapshot.windows)
                    }
                    ForEach(groupedHosts, id: \.0) { group, hosts in
                        VStack(alignment: .leading, spacing: 8) {
                            if let group {
                                sectionLabel(group)
                            }
                            ForEach(hosts) { host in
                                hostRow(host)
                            }
                        }
                    }
                    if !store.vncHosts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("Desktops")
                            ForEach(store.vncHosts) { host in
                                vncHostRow(host)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .id(themeName)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HostConfig.self) { host in
                HostTabsScreen(host: host)
            }
            .navigationDestination(for: VNCHostConfig.self) { host in
                VNCDesktopScreen(host: host)
            }
            .sheet(isPresented: $addingHost) { HostFormView(host: nil) }
            .sheet(item: $editingHost) { host in HostFormView(host: host) }
            .sheet(isPresented: $addingVNCHost) { VNCHostFormView(host: nil) }
            .sheet(item: $editingVNCHost) { host in VNCHostFormView(host: host) }
            .sheet(item: $runningSnippet) { run in
                SnippetRunView(host: run.host, snippet: run.snippet)
            }
            .overlay {
                if store.hosts.isEmpty, store.vncHosts.isEmpty {
                    ContentUnavailableView(
                        "No hosts",
                        systemImage: "server.rack",
                        description: Text("Add a host, then install the device key from the Keys screen.")
                    )
                }
            }
            .paperScreen()
        }
        .onChange(of: router.pending) { _, target in
            guard let target, let host = store.hosts.first(where: { $0.id == target.hostID }) else { return }
            path = NavigationPath()
            path.append(host)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            brand
            Spacer(minLength: 4)
            NavigationLink {
                KeysView()
            } label: {
                headerButton("key")
            }
            .accessibilityLabel("Keys")
            NavigationLink {
                SettingsView()
            } label: {
                headerButton("gearshape")
            }
            .accessibilityLabel("Settings")
            Menu {
                Button("SSH Host") { addingHost = true }
                Button("VNC Desktop") { addingVNCHost = true }
                Divider()
                NavigationLink {
                    SnippetsView()
                } label: {
                    Label("Snippets", systemImage: "text.badge.plus")
                }
            } label: {
                headerButton("plus", accent: true)
            }
            .accessibilityIdentifier("plus")
        }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PocketshellTheme.accent)
                    .shadow(color: PocketshellTheme.accent.opacity(0.27), radius: 3, y: 2)
                HStack(spacing: 2) {
                    Text("❯")
                        .font(PocketshellTheme.mono(17, weight: .bold))
                    Rectangle().frame(width: 5, height: 2)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            HStack(spacing: 0) {
                Text("pocket").foregroundStyle(PocketshellTheme.ink)
                Text("shell").foregroundStyle(PocketshellTheme.accent)
            }
            .font(PocketshellTheme.mono(21, weight: .bold))
        }
    }

    private func headerButton(_ icon: String, accent: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(accent ? .white : PocketshellTheme.secondary)
            .frame(width: 38, height: 38)
            .background(accent ? PocketshellTheme.accent : PocketshellTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                if !accent {
                    RoundedRectangle(cornerRadius: 10).stroke(PocketshellTheme.border)
                }
            }
            .shadow(color: accent ? PocketshellTheme.accent.opacity(0.27) : .clear, radius: 3, y: 2)
    }

    private func agentSummary(_ windows: [SessionSnapshot.Window]) -> some View {
        HStack(spacing: 14) {
            Text("AGENTS")
                .font(PocketshellTheme.mono(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(PocketshellTheme.muted)
            Spacer()
            summaryItem(windows, status: "busy", color: PocketshellTheme.busy)
            summaryItem(windows, status: "needs input", color: PocketshellTheme.accent, glow: true)
            summaryItem(windows, status: "idle", color: PocketshellTheme.idle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(PocketshellTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(PocketshellTheme.border))
    }

    private func summaryItem(_ windows: [SessionSnapshot.Window], status: String, color: Color, glow: Bool = false)
        -> some View
    {
        let count = windows.count { $0.status == status }
        return HStack(spacing: 4) {
            statusDot(color, glow: glow)
            Text("\(count) \(status)")
                .font(PocketshellTheme.mono(9, weight: .semibold))
                .foregroundStyle(PocketshellTheme.secondary)
        }
    }

    private var groupedHosts: [(String?, [HostConfig])] {
        let grouped = Dictionary(grouping: store.hosts) { $0.group }
        var result: [(String?, [HostConfig])] = []
        if let ungrouped = grouped[nil] { result.append((nil, ungrouped)) }
        for group in grouped.keys.compactMap({ $0 }).sorted() {
            result.append((group, grouped[group] ?? []))
        }
        return result
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .font(PocketshellTheme.mono(10, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(PocketshellTheme.muted)
            .padding(.top, 2)
    }

    private func hostRow(_ host: HostConfig) -> some View {
        let windows = monitor.snapshot?.windows.filter { $0.host == host.name } ?? []
        let records = store.savedTabs[host.id.uuidString] ?? []
        let matchedWindows = records.compactMap { record in
            windows.first { $0.session == record.tmuxSession && $0.index == record.windowIndex }
        }
        let needsInput = matchedWindows.contains { $0.status == "needs input" }
        return NavigationLink(value: host) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name)
                            .font(PocketshellTheme.mono(16, weight: .bold))
                            .foregroundStyle(PocketshellTheme.ink)
                        Text("\(host.username)@\(host.hostname):\(String(host.port))")
                            .font(PocketshellTheme.mono(11))
                            .foregroundStyle(PocketshellTheme.muted)
                    }
                    Spacer()
                    if !records.isEmpty {
                        Text("\(records.count) TABS OPEN")
                            .font(PocketshellTheme.mono(10, weight: .bold))
                            .foregroundStyle(PocketshellTheme.accentDark)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(PocketshellTheme.accentTint)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(PocketshellTheme.accentBorder))
                    }
                }
                if records.isEmpty {
                    HStack {
                        let sessions = store.tmuxSessions(for: host)
                        Text(
                            sessions.isEmpty
                                ? "… · no tmux" : "\(sessions.joined(separator: ", ")) · waiting for status")
                        Spacer()
                        Text("—")
                    }
                    .font(PocketshellTheme.mono(10))
                    .foregroundStyle(PocketshellTheme.faint)
                } else {
                    ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                        let window = windows.first {
                            $0.session == record.tmuxSession && $0.index == record.windowIndex
                        }
                        tabRow(record, index: index, window: window, updatedAt: monitor.snapshot?.updatedAt)
                    }
                }
            }
            .padding(14)
            .background(needsInput ? PocketshellTheme.accentTint : PocketshellTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(needsInput ? PocketshellTheme.accentBorder : PocketshellTheme.border)
            }
            .shadow(color: PocketshellTheme.ink.opacity(0.06), radius: 1, y: 1)
            .shadow(color: needsInput ? PocketshellTheme.accent.opacity(0.08) : .clear, radius: 0, x: 0, y: 0)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { editingHost = host }
            ForEach(execSnippets(for: host)) { snippet in
                Button(snippet.name) { runningSnippet = SnippetRun(host: host, snippet: snippet) }
            }
            Button("Delete", role: .destructive) { store.hosts.removeAll { $0.id == host.id } }
        }
    }

    private func tabRow(_ record: TabRecord, index: Int, window: SessionSnapshot.Window?, updatedAt: Date?) -> some View
    {
        let status = window?.status
        let label = record.name ?? window.map(windowName) ?? "tab \(index + 1)"
        return HStack(spacing: 6) {
            if let status {
                statusDot(statusColor(status), glow: status == "needs input")
            }
            Text(label)
                .font(PocketshellTheme.mono(12, weight: .semibold))
                .foregroundStyle(status == "idle" ? PocketshellTheme.muted : PocketshellTheme.body)
                .lineLimit(1)
            if let status {
                Text(status)
                    .font(PocketshellTheme.mono(10))
                    .foregroundStyle(statusTextColor(status))
            }
            Spacer()
            if status != nil, let updatedAt {
                Text(age(updatedAt))
                    .font(PocketshellTheme.mono(10))
                    .foregroundStyle(PocketshellTheme.faint)
            }
        }
    }

    private func windowName(_ window: SessionSnapshot.Window) -> String {
        window.name.split(separator: ":", maxSplits: 1).last.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? window.name
    }

    private func vncHostRow(_ host: VNCHostConfig) -> some View {
        NavigationLink(value: host) {
            HStack(spacing: 12) {
                Image(systemName: "display")
                    .foregroundStyle(PocketshellTheme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name)
                        .font(PocketshellTheme.mono(14, weight: .bold))
                        .foregroundStyle(PocketshellTheme.ink)
                    Text("vnc://\(host.hostname):\(String(host.port))")
                        .font(PocketshellTheme.mono(11))
                        .foregroundStyle(PocketshellTheme.muted)
                }
                Spacer()
            }
            .padding(14)
            .background(PocketshellTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(PocketshellTheme.border))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { editingVNCHost = host }
            Button("Delete", role: .destructive) { store.deleteVNCHost(host) }
        }
    }

    private func statusDot(_ color: Color, glow: Bool = false) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: glow ? color.opacity(0.4) : .clear, radius: 4)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "busy": PocketshellTheme.busy
        case "needs input": PocketshellTheme.accent
        default: PocketshellTheme.idle
        }
    }

    private func statusTextColor(_ status: String) -> Color {
        switch status {
        case "busy": PocketshellTheme.busyText
        case "needs input": PocketshellTheme.accentDark
        default: PocketshellTheme.idleText
        }
    }

    private func age(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    private func execSnippets(for host: HostConfig) -> [Snippet] {
        store.snippets.filter {
            $0.runMode == .execAndShowOutput && ($0.hostID == nil || $0.hostID == host.id)
        }
    }
}

struct SnippetRun: Identifiable {
    let host: HostConfig
    let snippet: Snippet
    var id: UUID { snippet.id }
}
