public enum MicMode: String, CaseIterable, Sendable {
    case standard
    case wideSpectrum
    case voiceIsolation

    public var label: String {
        switch self {
        case .standard: "Standard"
        case .wideSpectrum: "Wide Spectrum"
        case .voiceIsolation: "Voice Isolation"
        }
    }

    public var symbol: String {
        switch self {
        case .standard: "mic"
        case .wideSpectrum: "waveform"
        case .voiceIsolation: "person.wave.2"
        }
    }

    public static let hint = "Background voices are filtered better with Voice Isolation."
    public static let explanation =
        "Voice Isolation is an iOS microphone mode that keeps your voice and reduces other voices and noise. "
        + "iOS remembers it per app. Choose it with the Mic Mode button in the full-screen voice view, or in "
        + "Control Center while voice mode is on."

    public static func showsHint(active: MicMode, voiceOn: Bool, dismissed: Bool) -> Bool {
        voiceOn && !dismissed && active != .voiceIsolation
    }
}
