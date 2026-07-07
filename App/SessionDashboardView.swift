import SwiftUI
import TmuxKit

struct WindowDashboardItem: Identifiable {
    let window: TmuxWindow
    let preview: String
    let status: AgentStatus
    var id: Int { window.index }
}

struct DashboardRow: View {
    let item: WindowDashboardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("\(item.window.index): \(item.window.name)")
                    .font(.subheadline.weight(.medium))
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                if item.window.active {
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
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch item.status {
        case .busy: .orange
        case .waiting: .purple
        case .idle: .green
        }
    }

    private var statusLabel: String {
        switch item.status {
        case .busy: "busy"
        case .waiting: "needs input"
        case .idle: "idle"
        }
    }
}
