import Foundation
import Models

public struct VoiceActivityFeed: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case none
        case start(VoiceActivityState)
        case update(VoiceActivityState)
        case end
    }

    public static let captionInterval: TimeInterval = 1

    private var shown: VoiceActivityState?
    private var updatedAt = -TimeInterval.infinity

    public init() {}

    public static func state(
        mode: VoiceBrain.Mode, phase: TurnTaking.Phase, muted: Bool, interrupted: Bool, caption: VoiceBrain.Caption?
    ) -> VoiceActivityState? {
        let status: VoiceActivityState.Status
        switch mode {
        case .off:
            return nil
        case .starting:
            status = .starting
        case .dictation:
            status = interrupted ? .paused : muted ? .muted : .dictating
        case .conversing:
            if interrupted {
                status = .paused
            } else if muted {
                status = .muted
            } else {
                switch phase {
                case .listening: status = .listening
                case .userSpeaking: status = .hearing
                case .thinking: status = .thinking
                case .speaking: status = .speaking
                }
            }
        }
        return VoiceActivityState(
            status: status, caption: VoiceActivityState.line(caption?.text ?? ""), muted: muted)
    }

    public mutating func step(_ state: VoiceActivityState?, at now: TimeInterval) -> Step {
        guard let state else {
            defer { shown = nil }
            return shown == nil ? .none : .end
        }
        guard let shown else {
            self.shown = state
            updatedAt = now
            return .start(state)
        }
        guard state != shown else { return .none }
        let urgent = state.status != shown.status || state.muted != shown.muted
        guard urgent || now - updatedAt >= Self.captionInterval else { return .none }
        self.shown = state
        updatedAt = now
        return .update(state)
    }
}

extension VoiceBrain {
    public var activityState: VoiceActivityState? {
        VoiceActivityFeed.state(mode: mode, phase: phase, muted: muted, interrupted: interrupted, caption: caption)
    }
}
