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
    @AppStorage(AppSettings.uiScaleKey) private var uiScale = 1.0
    @StateObject private var store: AppStore
    @StateObject private var lock = AppLockController()
    @StateObject private var monitor: SessionMonitor
    private let keepAlive = BackgroundKeepAlive()

    init() {
        if ProcessInfo.processInfo.environment["PS_UI_TEST"] == "1" {
            UIView.setAnimationsEnabled(false)
        }
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
                .environment(\.dynamicTypeSize, dynamicTypeSize)
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
                store.refreshCloudConfig()
                monitor.startPolling()
            case .background:
                keepAlive.begin()
                store.saveConfigToCloud()
                store.saveCredentialsToCloud()
                #if targetEnvironment(macCatalyst)
                    monitor.startPolling()
                #else
                    monitor.stopPolling()
                    if monitor.enabled {
                        SessionMonitor.scheduleBackgroundRefresh()
                    }
                #endif
            default:
                break
            }
        }
        #if targetEnvironment(macCatalyst)
            .commands {
                CommandGroup(after: .toolbar) {
                    Button("Zoom In") { uiScale = min(1.6, uiScale + 0.1) }
                    .keyboardShortcut("+", modifiers: .command)
                    Button("Zoom Out") { uiScale = max(0.8, uiScale - 0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                    Button("Actual Size") { uiScale = 1 }
                    .keyboardShortcut("0", modifiers: .command)
                }
            }
        #endif
    }

    private var dynamicTypeSize: DynamicTypeSize {
        switch uiScale {
        case ..<0.9: .medium
        case 1.2...: .xxLarge
        case 1.1...: .xLarge
        default: .large
        }
    }
}
