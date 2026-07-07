import Models
import SwiftUI
import WidgetKit

struct SessionsEntry: TimelineEntry {
    let date: Date
    let snapshot: SessionSnapshot?
}

struct SessionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SessionsEntry {
        SessionsEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SessionsEntry) -> Void) {
        completion(SessionsEntry(date: Date(), snapshot: SnapshotStore.shared.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionsEntry>) -> Void) {
        let entry = SessionsEntry(date: Date(), snapshot: SnapshotStore.shared.load())
        completion(Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: 15 * 60))))
    }
}

struct SessionsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: SessionsEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, !snapshot.windows.isEmpty {
                switch family {
                case .accessoryRectangular:
                    lockScreen(snapshot)
                default:
                    homeScreen(snapshot)
                }
            } else {
                Text("No session data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private func homeScreen(_ snapshot: SessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(snapshot.windows.prefix(rowLimit).enumerated()), id: \.offset) { _, window in
                HStack(spacing: 5) {
                    Circle()
                        .fill(color(window.status))
                        .frame(width: 7, height: 7)
                    Text(window.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(window.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(snapshot.updatedAt, style: .relative)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func lockScreen(_ snapshot: SessionSnapshot) -> some View {
        let busy = snapshot.windows.filter { $0.status == "busy" }.count
        let waiting = snapshot.windows.filter { $0.status == "needs input" }.count
        return VStack(alignment: .leading, spacing: 2) {
            Text("agents")
                .font(.caption2.weight(.semibold))
            Text("\(busy) busy · \(waiting) waiting")
                .font(.caption2)
            Text(snapshot.updatedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var rowLimit: Int {
        family == .systemLarge ? 10 : 4
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "busy": .orange
        case "needs input": .purple
        default: .green
        }
    }
}

@main
struct PocketshellWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "pocketshell-sessions", provider: SessionsProvider()) { entry in
            SessionsWidgetView(entry: entry)
        }
        .configurationDisplayName("Agent sessions")
        .description("Status of Claude agent tmux windows.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}
