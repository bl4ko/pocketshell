import BrainKit
import Foundation
import KeyKit
import Models
import SSHKit
import VoiceKit

#if os(iOS)
    import AVFoundation
#endif

enum BrainSettings {
    static let baseURLKey = "pocketshell.brainBaseURL"
    static let modelKey = "pocketshell.brainModel"
    static let voiceKey = "pocketshell.brainVoice"
    static let apiKeyAccount = "pocketshell.brain.apiKey"
    static let defaultModel = "claude-opus-5-5"
    static let earsKey = "pocketshell.speechEars"
    static let mouthKey = "pocketshell.speechMouth"
    static let sonioxVoiceKey = "pocketshell.sonioxVoice"
    static let turnEndKey = "pocketshell.speechTurnEnd"
    static let sonioxKeyAccount = "pocketshell.soniox.apiKey"
    static let saveAudioKey = "pocketshell.benchmarkSaveAudio"

    static var isUITest: Bool { ProcessInfo.processInfo.environment["PS_UI_TEST"] == "1" }

    static var benchmarkDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("VoiceBenchmark")
    }

    static var benchmarkLog: BenchmarkLog { BenchmarkLog(directory: benchmarkDirectory) }

    static var audioArchive: TurnAudioArchive {
        TurnAudioArchive(directory: benchmarkDirectory.appendingPathComponent("audio"))
    }

    static var sonioxKey: String? {
        PasswordVault.get(account: sonioxKeyAccount).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var sonioxVoice: String {
        let voice = UserDefaults.standard.string(forKey: sonioxVoiceKey) ?? ""
        return voice.isEmpty ? SonioxTTS.defaultVoice : voice
    }

    static var turnEnd: TurnEnd {
        UserDefaults.standard.string(forKey: turnEndKey).flatMap(TurnEnd.init(rawValue:)) ?? .balanced
    }

    static func selection() -> SpeechSelection {
        let defaults = UserDefaults.standard
        return SpeechSelection.resolve(
            ears: defaults.string(forKey: earsKey), mouth: defaults.string(forKey: mouthKey),
            hasSonioxKey: sonioxKey != nil)
    }

    static var modelName: String { model(UserDefaults.standard.string(forKey: modelKey)) }

    static func client() -> BrainModel? {
        client(model: isUITest ? defaultModel : modelName)
    }

    static func providers(_ selection: SpeechSelection) -> BenchmarkProviders {
        BenchmarkProviders(
            ears: selection.ears == .soniox ? "soniox:\(SonioxSTT.model)" : "iphone",
            mouth: selection.mouth == .soniox ? "soniox:\(SonioxTTS.model):\(sonioxVoice)" : "iphone",
            model: modelName)
    }
}

@MainActor
final class VoiceBrainSession: ObservableObject {
    @Published private(set) var brain: VoiceBrain?
    private(set) var testEars: TextEars?
    private var audio: AnyObject?
    private var report_: () -> String = { "-" }
    #if !targetEnvironment(macCatalyst)
        private let activity = VoiceActivityController()
    #endif

    static let execDeadline = 20.0

    static func bounded(
        _ exec: @escaping @MainActor (String) async -> String?, seconds: Double = execDeadline
    ) -> @MainActor (String) async -> String? {
        { command in try? await withDeadline(seconds: seconds) { await exec(command) } }
    }

    var isOn: Bool { brain?.isOn == true }

    var report: String {
        guard let brain else { return "never started" }
        let timing = brain.lastTiming.map { " last=\($0.summary)" } ?? ""
        return "mode=\(brain.mode) phase=\(brain.phase) muted=\(brain.muted) providers=\(brain.providers.ears),"
            + "\(brain.providers.mouth) audio=\(report_())\(timing)"
    }

    func start(
        host: HostConfig, io: AgentToolbox.IO, sessions: SessionToolbox.IO? = nil,
        onDictation: @escaping (String) -> Void
    ) {
        guard !isOn else { return }
        var io = io
        let exec = Self.bounded(io.exec)
        io.exec = exec
        let toolbox = AgentToolbox(io: io)
        if var sessions {
            sessions.exec = exec
            toolbox.sessions = SessionToolbox(io: sessions)
        }
        io.unsentPrompt = { agent in
            await exec(AgentControl.boxCommand(agent)).flatMap(AgentControl.unsentPrompt(fromBox:))
        }
        let selection =
            BrainSettings.isUITest ? SpeechSelection(ears: .iphone, mouth: .iphone) : BrainSettings.selection()
        let parts: Parts
        if BrainSettings.isUITest {
            let text = TextEars()
            testEars = text
            parts = Parts(ears: text, mouth: TimedMouth(), lifecycle: .none)
        } else {
            guard let live = makeLiveParts(selection) else { return }
            parts = live
        }
        let directory = URL.applicationSupportDirectory.appendingPathComponent("VoiceBrain")
        let brain = VoiceBrain(
            hostID: host.id.uuidString, hostName: host.name, ears: parts.ears, mouth: parts.mouth,
            model: BrainSettings.client(),
            toolbox: toolbox, store: ConversationStore(directory: directory), audio: parts.lifecycle)
        let providers = BrainSettings.providers(selection)
        brain.providers = providers
        brain.onDictation = onDictation
        let log = BrainSettings.benchmarkLog
        brain.onTurnTimed = { timing in Task.detached { log.append(timing) } }
        let fallbackMouth = parts.fallbackMouth
        let onUserTurn = parts.onUserTurn
        brain.onUserTurn = { [weak brain, weak fallbackMouth] turn in
            if let brain, let fallbackMouth, !fallbackMouth.usingFallback { brain.providers.mouth = providers.mouth }
            onUserTurn?(turn)
        }
        parts.fallbackEars?.onNotice = { [weak brain] notice in
            brain?.notice(notice)
            brain?.providers.ears = "iphone-fallback"
        }
        fallbackMouth?.onNotice = { [weak brain] notice in
            brain?.notice(notice)
            brain?.providers.mouth = "iphone-fallback"
        }
        parts.interruptions? { [weak brain] began in brain?.audioInterrupted(began) }
        brain.onEnded = { MicModeMonitor.shared.voiceModeEnded() }
        self.brain = brain
        #if !targetEnvironment(macCatalyst)
            activity.follow(brain)
        #endif
        Task {
            await brain.start()
            if let notice = selection.notice { brain.notice(notice) }
        }
    }

    func end() {
        brain?.end()
    }

    struct Parts {
        var ears: VoiceEars
        var mouth: VoiceMouth
        var lifecycle: VoiceBrain.Audio
        var fallbackEars: FallbackEars?
        var fallbackMouth: FallbackMouth?
        var onUserTurn: ((UserTurn) -> Void)?
        var interruptions: ((@escaping (Bool) -> Void) -> Void)?
    }

    private func makeLiveParts(_ selection: SpeechSelection) -> Parts? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
            let audio = DuplexAudio()
            self.audio = audio
            report_ = { [weak audio] in audio?.report ?? "-" }
            let key = BrainSettings.sonioxKey ?? ""
            let onDevice: @MainActor () -> VoiceEars = { OnDeviceEars(audio: audio) }
            let system = SystemMouth(
                audio: audio, voiceIdentifier: UserDefaults.standard.string(forKey: BrainSettings.voiceKey))
            var parts = Parts(ears: TextEars(), mouth: system, lifecycle: .none)
            if selection.ears == .soniox {
                let soniox = SonioxEars(
                    apiKey: key, microphone: audio, turnEnd: BrainSettings.turnEnd,
                    permission: { await AVAudioApplication.requestRecordPermission() })
                let wrapped = FallbackEars(primary: soniox, fallback: onDevice)
                parts.fallbackEars = wrapped
                parts.ears = wrapped
            } else {
                parts.ears = onDevice()
            }
            var soniox: SonioxMouth?
            if selection.mouth == .soniox {
                let primary = SonioxMouth(apiKey: key, voice: BrainSettings.sonioxVoice) { [weak audio] in audio?.line }
                soniox = primary
                let wrapped = FallbackMouth(primary: primary, fallback: system)
                parts.fallbackMouth = wrapped
                parts.mouth = wrapped
            }
            let archive =
                UserDefaults.standard.bool(forKey: BrainSettings.saveAudioKey) ? BrainSettings.audioArchive : nil
            parts.lifecycle = VoiceBrain.Audio(
                start: {
                    try audio.start()
                    soniox?.prepare()
                    guard let archive else { return }
                    let resampler = PCM16Resampler()
                    audio.setRecorder { buffer in
                        if let pcm = resampler.convert(buffer) {
                            archive.append(pcm, at: ProcessInfo.processInfo.systemUptime)
                        }
                    }
                },
                stop: {
                    soniox?.shutdown()
                    audio.stop()
                })
            if let archive {
                parts.onUserTurn = { turn in
                    guard let start = turn.speechStart else { return }
                    Task.detached {
                        try? archive.save(
                            turn: turn.turn, text: turn.text, speechStart: start, speechEnd: turn.speechEnd,
                            ears: turn.providers.ears, mouth: turn.providers.mouth, model: turn.providers.model)
                    }
                }
            }
            parts.interruptions = { handler in audio.onInterruption = handler }
            return parts
        #else
            return nil
        #endif
    }
}
