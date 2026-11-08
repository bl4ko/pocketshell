import Foundation

#if !os(watchOS)
    @preconcurrency import AVFoundation
#endif

public struct VoiceChoice: Equatable, Sendable, Identifiable {
    public enum Quality: Int, Comparable, Sendable {
        case standard = 1
        case enhanced = 2
        case premium = 3

        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .standard: "Default"
            case .enhanced: "Enhanced"
            case .premium: "Premium"
            }
        }
    }

    public var id: String
    public var name: String
    public var language: String
    public var quality: Quality

    public init(id: String, name: String, language: String, quality: Quality) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }

    public var label: String { "\(name) (\(language), \(quality.label))" }
}

public enum SpeechVoices {
    public static func ranked(_ voices: [VoiceChoice], preferredLanguage: String = "en-US") -> [VoiceChoice] {
        voices.filter { $0.language.lowercased().hasPrefix("en") }.sorted { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            let aPreferred = a.language == preferredLanguage
            let bPreferred = b.language == preferredLanguage
            if aPreferred != bPreferred { return aPreferred }
            return a.name < b.name
        }
    }

    public static func choose(_ identifier: String?, from voices: [VoiceChoice]) -> VoiceChoice? {
        let ranked = ranked(voices)
        return ranked.first { $0.id == identifier } ?? ranked.first
    }

    #if !os(watchOS)
        public static func installed() -> [VoiceChoice] {
            AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
                guard !voice.voiceTraits.contains(.isNoveltyVoice) else { return nil }
                let quality: VoiceChoice.Quality =
                    switch voice.quality {
                    case .premium: .premium
                    case .enhanced: .enhanced
                    default: .standard
                    }
                return VoiceChoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
            }
        }
    #endif
}
