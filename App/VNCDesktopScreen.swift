import Models
import SwiftUI

#if targetEnvironment(macCatalyst)
    struct VNCDesktopScreen: View {
        let host: VNCHostConfig

        var body: some View {
            ContentUnavailableView(
                "VNC unavailable on Mac",
                systemImage: "display.trianglebadge.exclamationmark",
                description: Text("RoyalVNCKit does not support Mac Catalyst yet.")
            )
            .navigationTitle(host.name)
        }
    }
#else
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
                guard phase == .active, let session = holder.session else { return }
                switch session.phase {
                case .disconnected, .failed:
                    session.connect()
                default:
                    break
                }
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
#endif
