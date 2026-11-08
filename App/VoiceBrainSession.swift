import BrainKit
import Foundation
import KeyKit
import Models
import VoiceKit

enum BrainSettings {
    static let baseURLKey = "pocketshell.brainBaseURL"
    static let modelKey = "pocketshell.brainModel"
    static let voiceKey = "pocketshell.brainVoice"
    static let apiKeyAccount = "pocketshell.brain.apiKey"
    static let defaultModel = "gpt-6-luna"

    static var isUITest: Bool { ProcessInfo.processInfo.environment["PS_UI_TEST"] == "1" }

    static func client() -> BrainModel? {
        let env = ProcessInfo.processInfo.environment
        if isUITest, let url = env["PS_UI_TEST_BRAIN_URL"].flatMap(URL.init(string:)) {
            return OpenAIChatClient(baseURL: url, apiKey: env["PS_UI_TEST_BRAIN_KEY"] ?? "", model: defaultModel)
        }
        let defaults = UserDefaults.standard
        let raw = (defaults.string(forKey: baseURLKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else { return nil }
        let model = (defaults.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAIChatClient(
            baseURL: url, apiKey: PasswordVault.get(account: apiKeyAccount) ?? "",
            model: model.isEmpty ? defaultModel : model)
    }
}

@MainActor
final class VoiceBrainSession: ObservableObject {
    @Published private(set) var brain: VoiceBrain?
    private(set) var testEars: TextEars?
    private var audio: DuplexAudio?

    var isOn: Bool { brain?.isOn == true }

    var report: String {
        guard let brain else { return "never started" }
        return "mode=\(brain.mode) phase=\(brain.phase) muted=\(brain.muted) audio=\(audio?.report ?? "-")"
    }

    func start(host: HostConfig, io: AgentToolbox.IO, onDictation: @escaping (String) -> Void) {
        guard !isOn else { return }
        var io = io
        let exec = io.exec
        io.unsentPrompt = { agent in
            await exec(AgentControl.boxCommand(agent)).flatMap(AgentControl.unsentPrompt(fromBox:))
        }
        let ears: VoiceEars
        let mouth: VoiceMouth
        let lifecycle: VoiceBrain.Audio
        if BrainSettings.isUITest {
            let text = TextEars()
            testEars = text
            ears = text
            mouth = TimedMouth()
            lifecycle = .none
        } else {
            #if os(iOS) && !targetEnvironment(macCatalyst)
                let audio = DuplexAudio()
                self.audio = audio
                ears = OnDeviceEars(audio: audio)
                mouth = SystemMouth(
                    audio: audio, voiceIdentifier: UserDefaults.standard.string(forKey: BrainSettings.voiceKey))
                lifecycle = VoiceBrain.Audio(start: { try audio.start() }, stop: { audio.stop() })
            #else
                return
            #endif
        }
        let directory = URL.applicationSupportDirectory.appendingPathComponent("VoiceBrain")
        let brain = VoiceBrain(
            hostID: host.id.uuidString, hostName: host.name, ears: ears, mouth: mouth, model: BrainSettings.client(),
            toolbox: AgentToolbox(io: io), store: ConversationStore(directory: directory), audio: lifecycle)
        brain.onDictation = onDictation
        audio?.onInterruption = { [weak brain] began in brain?.audioInterrupted(began) }
        self.brain = brain
        Task { await brain.start() }
    }

    func end() {
        brain?.end()
    }
}
