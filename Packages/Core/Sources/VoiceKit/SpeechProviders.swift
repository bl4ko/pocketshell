import Foundation

public enum SpeechProvider: String, CaseIterable, Identifiable, Sendable {
    case iphone
    case soniox

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .iphone: "On device"
        case .soniox: "Soniox"
        }
    }
}

public struct SpeechSelection: Equatable, Sendable {
    public var ears: SpeechProvider
    public var mouth: SpeechProvider
    public var notice: String?

    public init(ears: SpeechProvider, mouth: SpeechProvider, notice: String? = nil) {
        self.ears = ears
        self.mouth = mouth
        self.notice = notice
    }

    public static func defaultProvider(hasSonioxKey: Bool) -> SpeechProvider {
        hasSonioxKey ? .soniox : .iphone
    }

    public static func resolve(ears: String?, mouth: String?, hasSonioxKey: Bool) -> SpeechSelection {
        let wantedEars = ears.flatMap(SpeechProvider.init(rawValue:)) ?? defaultProvider(hasSonioxKey: hasSonioxKey)
        let wantedMouth = mouth.flatMap(SpeechProvider.init(rawValue:)) ?? defaultProvider(hasSonioxKey: hasSonioxKey)
        guard !hasSonioxKey, wantedEars == .soniox || wantedMouth == .soniox else {
            return SpeechSelection(ears: wantedEars, mouth: wantedMouth)
        }
        return SpeechSelection(ears: .iphone, mouth: .iphone, notice: "No Soniox key, using on-device speech")
    }
}

@MainActor
public final class FallbackMouth: VoiceMouth {
    public var onEvent: ((MouthEvent) -> Void)?
    public var onNotice: ((String) -> Void)?
    public private(set) var isSpeaking = false
    public private(set) var failures = 0
    public private(set) var disabled = false
    private let primary: ProviderMouth
    private let fallback: VoiceMouth
    private let clock: @MainActor () -> TimeInterval
    private let cooldown: TimeInterval
    private var fallingBack = false
    private var failedAt: TimeInterval?

    public init(
        primary: ProviderMouth, fallback: VoiceMouth, cooldown: TimeInterval = 20,
        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.primary = primary
        self.fallback = fallback
        self.cooldown = cooldown
        self.clock = clock
        primary.onEvent = { [weak self] in self?.forward($0) }
        fallback.onEvent = { [weak self] in self?.forward($0) }
        primary.onFailure = { [weak self] error, unspoken, open in self?.primaryFailed(error, unspoken, open) }
    }

    public var usingFallback: Bool {
        disabled || fallingBack || failedAt.map { clock() < $0 + cooldown } == true
    }

    public func speak(_ text: String) {
        if usingFallback {
            fallback.speak(text)
        } else {
            primary.speak(text)
        }
    }

    public func stream(_ delta: String, reply: Int) {
        if usingFallback {
            fallback.stream(delta, reply: reply)
        } else {
            primary.stream(delta, reply: reply)
        }
    }

    public func finish() {
        primary.finish()
        fallback.finish()
    }

    public func stop() {
        primary.stop()
        fallback.stop()
        fallingBack = false
        settle()
    }

    private func primaryFailed(_ error: SonioxError, _ unspoken: [Utterance], _ open: Int?) {
        failures += 1
        fallingBack = true
        failedAt = clock()
        if error.kind == .auth { disabled = true }
        onNotice?(error.notice + ", using on-device voice")
        for (index, item) in unspoken.enumerated() {
            guard let reply = item.reply else {
                fallback.speak(item.text)
                continue
            }
            fallback.stream(item.text, reply: reply)
            if index < unspoken.count - 1 || open != reply { fallback.finish() }
        }
    }

    private func forward(_ event: MouthEvent) {
        switch event {
        case .started, .idle:
            settle()
        case .upcoming, .heard, .level:
            onEvent?(event)
        }
    }

    private func settle() {
        let speaking = primary.isSpeaking || fallback.isSpeaking
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        if !speaking { fallingBack = false }
        onEvent?(speaking ? .started : .idle)
    }
}

@MainActor
public final class FallbackEars: VoiceEars {
    public var onEvent: ((EarsEvent) -> Void)?
    public var onNotice: ((String) -> Void)?
    public var muted = false {
        didSet { active.muted = muted }
    }
    public private(set) var usingFallback = false
    private let primary: VoiceEars
    private let makeFallback: @MainActor () -> VoiceEars
    private var active: VoiceEars
    private var running = false

    public init(primary: VoiceEars, fallback: @escaping @MainActor () -> VoiceEars) {
        self.primary = primary
        makeFallback = fallback
        active = primary
        primary.onEvent = { [weak self] event in
            guard let self, !self.usingFallback else { return }
            if case .failed(let message) = event {
                Task { await self.switchToFallback(message) }
            } else {
                self.onEvent?(event)
            }
        }
    }

    public func start() async throws {
        running = true
        primary.muted = muted
        do {
            try await primary.start()
        } catch {
            await switchToFallback(error.localizedDescription)
        }
    }

    public func stop() {
        running = false
        active.stop()
    }

    public func agentSaid(_ text: String, end: Bool) {
        active.agentSaid(text, end: end)
    }

    private func switchToFallback(_ message: String) async {
        guard running, !usingFallback else { return }
        usingFallback = true
        primary.stop()
        onNotice?(message + ", using on-device speech recognition")
        let fallback = makeFallback()
        fallback.onEvent = { [weak self] in self?.onEvent?($0) }
        fallback.muted = muted
        active = fallback
        do {
            try await fallback.start()
        } catch {
            onEvent?(.failed(error.localizedDescription))
        }
    }
}
