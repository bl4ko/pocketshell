import MonitorKit
import SwiftUI
import TmuxKit

@MainActor
final class SkipPermissionsFlow: ObservableObject {
    struct Pending {
        let controller: ConnectionController
        let plan: AgentPermissionSwitch.Plan
        let status: () -> AgentStatus?
    }

    @Published var pending: Pending?
    @Published var notice: String?
    private var running = false

    func request(_ controller: ConnectionController, status: @escaping () -> AgentStatus?) {
        guard !running else { return }
        running = true
        Task {
            defer { running = false }
            switch await plan(controller, status: status()) {
            case .success(let plan): pending = Pending(controller: controller, plan: plan, status: status)
            case .failure(let refusal): notice = refusal.message
            }
        }
    }

    func confirm(_ pending: Pending) {
        guard !running else { return }
        running = true
        Task {
            defer { running = false }
            guard case .success(let plan) = await plan(pending.controller, status: pending.status()) else {
                notice = "The session changed or became busy. Nothing was sent."
                return
            }
            guard plan == pending.plan else {
                notice = "The session changed or became busy. Nothing was sent."
                return
            }
            if case .failed(let message) = await pending.controller.skipAgentPermissions(plan) {
                notice = message
            }
        }
    }

    private func plan(_ controller: ConnectionController, status: AgentStatus?) async -> Result<
        AgentPermissionSwitch.Plan, AgentPermissionSwitch.Refusal
    > {
        let process = await controller.agentProbe().flatMap(AgentPermissionSwitch.parseProbe)
        return AgentPermissionSwitch.plan(for: process, status: status)
    }
}

extension View {
    func skipPermissionsAlerts(_ flow: SkipPermissionsFlow) -> some View {
        modifier(SkipPermissionsAlerts(flow: flow))
    }
}

private struct SkipPermissionsAlerts: ViewModifier {
    @ObservedObject var flow: SkipPermissionsFlow

    func body(content: Content) -> some View {
        content
            .alert(
                flow.pending?.plan.title ?? "",
                isPresented: Binding(get: { flow.pending != nil }, set: { if !$0 { flow.pending = nil } }),
                presenting: flow.pending
            ) { pending in
                Button("Cancel", role: .cancel) {}
                Button("Skip Permissions", role: .destructive) { flow.confirm(pending) }
                    .accessibilityIdentifier("skip-permissions-confirm")
            } message: { pending in
                Text(pending.plan.message)
            }
            .alert(
                "Skip Permissions",
                isPresented: Binding(get: { flow.notice != nil }, set: { if !$0 { flow.notice = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(flow.notice ?? "")
            }
    }
}
