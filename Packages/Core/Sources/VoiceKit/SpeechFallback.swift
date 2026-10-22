public struct SpeechFailure: Equatable, Sendable {
    public var domain: String
    public var code: Int
    public var message: String

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }

    var isSilence: Bool {
        domain == "kAFAssistantErrorDomain" && code == 1110
    }
}

public struct SpeechFallback: Sendable {
    public private(set) var onDevice: Bool

    public init(onDeviceAvailable: Bool) {
        onDevice = onDeviceAvailable
    }

    public mutating func phraseEnded(heardSpeech: Bool, failure: SpeechFailure?) -> String? {
        guard !heardSpeech, let failure, !failure.isSilence else { return nil }
        guard !onDevice else {
            onDevice = false
            return nil
        }
        return failure.message
    }
}
