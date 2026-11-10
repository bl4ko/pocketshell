import AVFoundation
import SwiftUI
import VoiceKit

@MainActor
final class MicModeMonitor: NSObject, ObservableObject {
    static let shared = MicModeMonitor()
    static let hintDismissedKey = "pocketshell.micModeHintDismissed"

    @Published private(set) var active = MicMode.standard
    @Published private(set) var preferred = MicMode.standard
    @Published private(set) var hintDismissed: Bool

    override private init() {
        let hintOff = BrainSettings.isUITest && ProcessInfo.processInfo.environment["PS_UI_TEST_MIC_HINT"] != "1"
        hintDismissed = hintOff || UserDefaults.standard.bool(forKey: Self.hintDismissedKey)
        super.init()
        guard !BrainSettings.isUITest else { return }
        for key in ["activeMicrophoneMode", "preferredMicrophoneMode"] {
            (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: key, options: [], context: nil)
        }
        refresh()
    }

    func showPicker() {
        dismissHint()
        guard !BrainSettings.isUITest else {
            active = .voiceIsolation
            preferred = .voiceIsolation
            return
        }
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    func dismissHint() {
        guard !hintDismissed else { return }
        hintDismissed = true
        UserDefaults.standard.set(true, forKey: Self.hintDismissedKey)
    }

    func voiceModeEnded() {
        if MicMode.showsHint(active: active, voiceOn: true, dismissed: hintDismissed) { dismissHint() }
    }

    func refresh() {
        guard !BrainSettings.isUITest else { return }
        active = Self.mode(AVCaptureDevice.activeMicrophoneMode)
        preferred = Self.mode(AVCaptureDevice.preferredMicrophoneMode)
    }

    private static func mode(_ mode: AVCaptureDevice.MicrophoneMode) -> MicMode {
        switch mode {
        case .standard: .standard
        case .wideSpectrum: .wideSpectrum
        case .voiceIsolation: .voiceIsolation
        @unknown default: .standard
        }
    }

    nonisolated override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        Task { @MainActor in self.refresh() }
    }
}

struct MicModeButton: View {
    @ObservedObject var mic = MicModeMonitor.shared

    var body: some View {
        Button {
            mic.showPicker()
        } label: {
            Label(mic.active.label, systemImage: mic.active.symbol)
                .font(.caption)
                .foregroundStyle(PocketshellTheme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(PocketshellTheme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Microphone mode: \(mic.active.label)")
        .accessibilityIdentifier("voice.micMode")
        .onAppear { mic.refresh() }
    }
}

struct MicModeHint: View {
    @ObservedObject var mic = MicModeMonitor.shared

    var body: some View {
        if MicMode.showsHint(active: mic.active, voiceOn: true, dismissed: mic.hintDismissed) {
            HStack(spacing: 8) {
                Image(systemName: MicMode.voiceIsolation.symbol)
                    .foregroundStyle(PocketshellTheme.accent)
                Text(MicMode.hint)
                    .font(.footnote)
                    .foregroundStyle(PocketshellTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("voice.micHint.text")
                Button("Mic Mode") { mic.showPicker() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(PocketshellTheme.accent)
                    .accessibilityIdentifier("voice.micHint.open")
                Button {
                    mic.dismissHint()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote)
                        .foregroundStyle(PocketshellTheme.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss the microphone mode hint")
                .accessibilityIdentifier("voice.micHint.dismiss")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("voice.micHint")
        }
    }
}
