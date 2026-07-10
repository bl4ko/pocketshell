import BackgroundTasks
import SwiftUI
import UIKit

@MainActor
final class BackgroundKeepAlive {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        end()
        taskID = UIApplication.shared.beginBackgroundTask(withName: "pocketshell-connections") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}

@main
struct PocketshellApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: AppStore
    @StateObject private var lock = AppLockController()
    @StateObject private var monitor: SessionMonitor
    private let keepAlive = BackgroundKeepAlive()

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
                keepAlive.end()
                monitor.startPolling()
            case .background:
                keepAlive.begin()
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
