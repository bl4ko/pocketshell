import BackgroundTasks
import SwiftUI

@main
struct PocketshellApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: AppStore
    @StateObject private var lock = AppLockController()
    @StateObject private var monitor: SessionMonitor

    init() {
        let store = AppStore()
        let monitor = SessionMonitor(store: store)
        _store = StateObject(wrappedValue: store)
        _monitor = StateObject(wrappedValue: monitor)
        WatchRelay.shared.activate(store: store)
        UNUserNotificationCenter.current().delegate = ForegroundNotificationDelegate.shared
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SessionMonitor.refreshTaskID,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                monitor.handleBackgroundRefresh(refresh)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            HostsListView()
                .environmentObject(store)
                .environmentObject(monitor)
                .overlay { AppLockOverlay(lock: lock) }
                .onAppear {
                    if lock.isLocked {
                        lock.authenticate()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            lock.scenePhaseChanged(phase)
            switch phase {
            case .active:
                monitor.startPolling()
            case .background:
                monitor.stopPolling()
                if monitor.enabled {
                    SessionMonitor.scheduleBackgroundRefresh()
                }
            default:
                break
            }
        }
    }
}
