import SwiftUI

@main
struct PocketshellApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppStore()
    @StateObject private var lock = AppLockController()

    var body: some Scene {
        WindowGroup {
            HostsListView()
                .environmentObject(store)
                .overlay { AppLockOverlay(lock: lock) }
                .onAppear {
                    if lock.isLocked {
                        lock.authenticate()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            lock.scenePhaseChanged(phase)
        }
    }
}
