#if !targetEnvironment(macCatalyst)
    import ActivityKit
    import AppIntents
    import Models

    @MainActor
    enum VoiceActivityActions {
        static var toggleMute: (() -> Void)?
        static var end: (() -> Void)?

        nonisolated static func endAll() async {
            for activity in Activity<VoiceActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    struct VoiceMuteIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "Mute or Unmute Voice Mode"
        static let isDiscoverable = false

        func perform() async throws -> some IntentResult {
            await MainActor.run { VoiceActivityActions.toggleMute?() }
            return .result()
        }
    }

    struct VoiceEndIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "End Voice Mode"
        static let isDiscoverable = false

        func perform() async throws -> some IntentResult {
            let ended = await MainActor.run { () -> Bool in
                guard let end = VoiceActivityActions.end else { return false }
                end()
                return true
            }
            if !ended { await VoiceActivityActions.endAll() }
            return .result()
        }
    }
#endif
