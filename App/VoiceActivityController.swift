#if !targetEnvironment(macCatalyst)
    import ActivityKit
    import BrainKit
    import Combine
    import Models
    import UIKit

    @MainActor
    final class VoiceActivityController {
        private var feed = VoiceActivityFeed()
        private var steps: AsyncStream<VoiceActivityFeed.Step>.Continuation?
        private var observation: AnyCancellable?
        private var ticker: Task<Void, Never>?
        private var termination: NSObjectProtocol?

        func follow(_ brain: VoiceBrain) {
            stop()
            feed = VoiceActivityFeed()
            let (stream, steps) = AsyncStream<VoiceActivityFeed.Step>.makeStream()
            self.steps = steps
            let attributes = VoiceActivityAttributes(hostName: brain.hostName)
            Task.detached { await Self.show(stream, attributes: attributes) }
            VoiceActivityActions.toggleMute = { [weak brain] in
                guard let brain else { return }
                brain.setMuted(!brain.muted)
            }
            VoiceActivityActions.end = { [weak brain] in brain?.end() }
            observation = brain.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self, weak brain] _ in
                MainActor.assumeIsolated { self?.sync(brain) }
            }
            ticker = Task { [weak self, weak brain] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(VoiceActivityFeed.captionInterval))
                    guard let self, let brain else { return }
                    self.sync(brain)
                }
            }
            termination = NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in Self.endAllBeforeExit() }
        }

        nonisolated static func endLeftovers() {
            Task { await VoiceActivityActions.endAll() }
        }

        private func sync(_ brain: VoiceBrain?) {
            let step = feed.step(brain?.activityState, at: ProcessInfo.processInfo.systemUptime)
            guard step != .none else { return }
            steps?.yield(step)
            if step == .end { stop() }
        }

        private func stop() {
            steps?.finish()
            steps = nil
            observation = nil
            ticker?.cancel()
            ticker = nil
            if let termination { NotificationCenter.default.removeObserver(termination) }
            termination = nil
            VoiceActivityActions.toggleMute = nil
            VoiceActivityActions.end = nil
        }

        nonisolated private static func show(
            _ steps: AsyncStream<VoiceActivityFeed.Step>, attributes: VoiceActivityAttributes
        ) async {
            var activity: Activity<VoiceActivityAttributes>?
            for await step in steps {
                switch step {
                case .none:
                    break
                case .start(let state):
                    guard ActivityAuthorizationInfo().areActivitiesEnabled else { break }
                    activity = try? Activity.request(
                        attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
                case .update(let state):
                    await activity?.update(ActivityContent(state: state, staleDate: nil))
                case .end:
                    await activity?.end(nil, dismissalPolicy: .immediate)
                    activity = nil
                }
            }
            await activity?.end(nil, dismissalPolicy: .immediate)
        }

        nonisolated private static func endAllBeforeExit() {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await VoiceActivityActions.endAll()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 2)
        }
    }
#endif
