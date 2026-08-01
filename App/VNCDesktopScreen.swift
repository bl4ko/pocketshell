import Models
import SwiftUI
import VNCKit

struct VNCDesktopScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var store: AppStore
    @StateObject private var holder = SessionHolder()

    let host: VNCHostConfig

    var body: some View {
        Group {
            if let session = holder.session {
                VNCScreenView(session: session)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            holder.session?.appBecameActive()
        }
        .onAppear {
            if holder.session == nil {
                let session = VNCSessionController(
                    hostname: host.hostname,
                    port: host.port,
                    username: host.username,
                    password: store.vncPassword(for: host)
                )
                holder.session = session
                session.connect()
            }
        }
    }

    @MainActor
    final class SessionHolder: ObservableObject {
        @Published var session: VNCSessionController?
    }
}
