import LocalAuthentication
import LockKit
import SwiftUI

@MainActor
final class AppLockController: ObservableObject {
    @Published var isLocked = false
    private var gate: AppLockGate
    private var authenticating = false

    init() {
        let enabled = UserDefaults.standard.bool(forKey: AppSettings.appLockKey)
        gate = AppLockGate(enabled: enabled, gracePeriod: 30)
        gate.appLaunched()
        isLocked = gate.isLocked
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            gate.appBackgrounded(at: Date())
        case .active:
            gate.appActivated(at: Date())
            isLocked = gate.isLocked
            if isLocked {
                authenticate()
            }
        default:
            break
        }
    }

    func authenticate() {
        guard !authenticating else { return }
        authenticating = true
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            gate.unlock()
            isLocked = false
            authenticating = false
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock pocketshell"
        ) { [weak self] success, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authenticating = false
                if success {
                    self.gate.unlock()
                    self.isLocked = false
                }
            }
        }
    }
}

struct AppLockOverlay: View {
    @ObservedObject var lock: AppLockController

    var body: some View {
        if lock.isLocked {
            ZStack {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40))
                    Button("Unlock") { lock.authenticate() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
