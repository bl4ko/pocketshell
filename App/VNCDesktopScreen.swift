import Models
import SwiftUI
import VNCKit

struct VNCDesktopScreen: View {
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
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
