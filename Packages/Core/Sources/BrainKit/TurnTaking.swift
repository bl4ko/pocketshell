import Foundation

public struct TurnTaking: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case listening
        case userSpeaking
        case thinking
        case speaking
    }

    public enum Input: Equatable, Sendable {
        case userPartial(String)
        case userPhrase(String)
        case mouthStarted
        case mouthIdle
        case brainDone
        case eventQueued
        case tick
        case muted(Bool)
        case interrupted(Bool)
    }

    public enum Effect: Equatable, Sendable {
        case stopMouth
        case cancelBrain
        case respond(String)
        case playFiller
        case announce
    }

    public static let fillerDelay: TimeInterval = 2.0
    public static let proactiveSilence: TimeInterval = 1.5

    public private(set) var phase: Phase = .listening
    public private(set) var muted = false
    public private(set) var interrupted = false
    private var lastActivity: TimeInterval
    private var thinkingSince: TimeInterval = 0
    private var audioStarted = false
    private var fillerPlayed = false
    private var brainDone = true
    private var mouthBusy = false
    private var eventsPending = false

    public init(now: TimeInterval) {
        lastActivity = now
    }

    public mutating func handle(_ input: Input, at now: TimeInterval) -> [Effect] {
        switch input {
        case .userPartial(let text):
            guard !muted, !interrupted else { return [] }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if phase == .userSpeaking { phase = .listening }
                lastActivity = now
                return []
            }
            lastActivity = now
            switch phase {
            case .listening:
                phase = .userSpeaking
                return []
            case .userSpeaking:
                return []
            case .thinking, .speaking:
                phase = .userSpeaking
                brainDone = true
                mouthBusy = false
                return [.stopMouth, .cancelBrain]
            }
        case .userPhrase(let text):
            guard !muted, !interrupted, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return []
            }
            var effects: [Effect] = []
            if phase == .thinking || phase == .speaking || mouthBusy { effects = [.stopMouth, .cancelBrain] }
            phase = .thinking
            thinkingSince = now
            audioStarted = false
            fillerPlayed = false
            brainDone = false
            mouthBusy = false
            lastActivity = now
            return effects + [.respond(text)]
        case .mouthStarted:
            mouthBusy = true
            audioStarted = true
            if phase == .thinking || phase == .listening { phase = .speaking }
            return []
        case .mouthIdle:
            mouthBusy = false
            lastActivity = now
            if phase == .speaking { phase = brainDone ? .listening : .thinking }
            return []
        case .brainDone:
            brainDone = true
            if phase == .thinking, !mouthBusy {
                phase = .listening
                lastActivity = now
            }
            return []
        case .eventQueued:
            eventsPending = true
            return announceIfQuiet(now)
        case .tick:
            if phase == .thinking, !audioStarted, !fillerPlayed, !brainDone, now - thinkingSince >= Self.fillerDelay {
                fillerPlayed = true
                return [.playFiller]
            }
            return announceIfQuiet(now)
        case .muted(let on):
            muted = on
            if on, phase == .userSpeaking {
                phase = .listening
                lastActivity = now
            }
            return []
        case .interrupted(let on):
            interrupted = on
            lastActivity = now
            guard on else { return [] }
            let busy = phase == .thinking || phase == .speaking || mouthBusy
            phase = .listening
            brainDone = true
            mouthBusy = false
            return busy ? [.stopMouth, .cancelBrain] : []
        }
    }

    public mutating func startTurn(at now: TimeInterval) {
        phase = .thinking
        thinkingSince = now
        audioStarted = false
        fillerPlayed = true
        brainDone = false
    }

    private mutating func announceIfQuiet(_ now: TimeInterval) -> [Effect] {
        guard eventsPending, !interrupted, phase == .listening, !mouthBusy,
            now - lastActivity >= Self.proactiveSilence
        else { return [] }
        eventsPending = false
        brainDone = true
        return [.announce]
    }
}
