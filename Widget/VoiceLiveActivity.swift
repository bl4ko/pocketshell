#if !targetEnvironment(macCatalyst)
    import ActivityKit
    import AppIntents
    import Models
    import SwiftUI
    import WidgetKit

    struct VoiceLiveActivity: Widget {
        static let accent = Color(red: 0.91, green: 0.35, blue: 0.05)

        var body: some WidgetConfiguration {
            ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        VoiceGlyph(status: context.state.status)
                            .font(.title2)
                            .frame(width: 32)
                        VoiceHeadline(host: context.attributes.hostName, status: context.state.status)
                        Spacer(minLength: 8)
                        VoiceActivityButtons(muted: context.state.muted)
                    }
                    VoiceCaption(text: context.state.caption)
                }
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
            } dynamicIsland: { context in
                DynamicIsland {
                    DynamicIslandExpandedRegion(.leading) {
                        VoiceGlyph(status: context.state.status)
                            .font(.title2)
                            .frame(maxHeight: .infinity)
                    }
                    DynamicIslandExpandedRegion(.center) {
                        VoiceHeadline(host: context.attributes.hostName, status: context.state.status)
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        VoiceActivityButtons(muted: context.state.muted)
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        VoiceCaption(text: context.state.caption)
                    }
                } compactLeading: {
                    VoiceGlyph(status: context.state.status)
                } compactTrailing: {
                    Image(systemName: "waveform")
                        .foregroundStyle(Self.accent)
                } minimal: {
                    VoiceGlyph(status: context.state.status)
                }
                .keylineTint(Self.accent)
            }
        }
    }

    private struct VoiceGlyph: View {
        let status: VoiceActivityState.Status

        var body: some View {
            Image(systemName: status.symbol)
                .foregroundStyle(status == .muted || status == .paused ? Color.secondary : VoiceLiveActivity.accent)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(status.label)
        }
    }

    private struct VoiceHeadline: View {
        let host: String
        let status: VoiceActivityState.Status

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(host)
                    .font(.headline)
                    .lineLimit(1)
                Text(status.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
        }
    }

    private struct VoiceCaption: View {
        let text: String

        var body: some View {
            if !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private struct VoiceActivityButtons: View {
        let muted: Bool

        var body: some View {
            HStack(spacing: 10) {
                Button(intent: VoiceMuteIntent()) {
                    Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 22, height: 22)
                }
                .tint(muted ? VoiceLiveActivity.accent : .gray)
                .accessibilityLabel(muted ? "Unmute" : "Mute")
                Button(intent: VoiceEndIntent()) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .tint(.red)
                .accessibilityLabel("End voice mode")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
        }
    }
#endif
