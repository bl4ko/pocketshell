import BrainKit
import KeyKit
import SwiftUI
import VoiceKit

struct VoiceSettingsSections: View {
    var developerMode: Bool
    @AppStorage(BrainSettings.baseURLKey) private var brainURL = ""
    @AppStorage(BrainSettings.modelKey) private var brainModel = BrainSettings.defaultModel
    @AppStorage(BrainSettings.voiceKey) private var systemVoice = ""
    @AppStorage(BrainSettings.sonioxVoiceKey) private var sonioxVoice = SonioxTTS.defaultVoice
    @AppStorage(BrainSettings.earsKey) private var earsRaw = SpeechProvider.iphone.rawValue
    @AppStorage(BrainSettings.mouthKey) private var mouthRaw = ""
    @AppStorage(BrainSettings.saveAudioKey) private var saveAudio = false
    @State private var brainKeySaved = PasswordVault.get(account: BrainSettings.apiKeyAccount) != nil
    @State private var sonioxKeySaved = BrainSettings.sonioxKey != nil
    @State private var systemVoices: [VoiceChoice] = []
    @State private var sonioxVoices = SonioxTTS.voices
    @State private var lastTurn: TurnTiming?
    @State private var shared: SharedFile?
    @State private var exportError: String?

    var body: some View {
        Group {
            brainSection
            speechSection
            benchmarkSection
        }
        .onAppear {
            systemVoices = SpeechVoices.ranked(SpeechVoices.installed())
            lastTurn = BrainSettings.benchmarkLog.last
        }
        .task(id: sonioxKeySaved) { await loadSonioxVoices() }
        .sheet(item: $shared) { file in ActivitySheet(url: file.url) }
    }

    private var ears: Binding<SpeechProvider> {
        Binding(
            get: { SpeechProvider(rawValue: earsRaw) ?? .iphone },
            set: { earsRaw = $0.rawValue })
    }

    private var mouth: Binding<SpeechProvider> {
        Binding(
            get: { SpeechProvider(rawValue: mouthRaw) ?? SpeechSelection.defaultMouth(hasSonioxKey: sonioxKeySaved) },
            set: { mouthRaw = $0.rawValue })
    }

    private var brainSection: some View {
        Section {
            LabeledContent("Endpoint") {
                TextField("https://…/v1", text: $brainURL)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("settings.brain.endpoint")
            }
            KeychainKeyRow(
                title: "API key", account: BrainSettings.apiKeyAccount, saved: $brainKeySaved, id: "settings.brain.key")
            LabeledContent("Model") {
                TextField(BrainSettings.defaultModel, text: $brainModel)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.brain.model")
            }
        } header: {
            Text("Voice brain")
        } footer: {
            Text("Any OpenAI-compatible Chat Completions endpoint. Keys stay in this device's Keychain.")
        }
    }

    private var speechSection: some View {
        Section {
            Picker("Ears", selection: ears) {
                ForEach(SpeechProvider.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.speech.ears")
            Picker("Mouth", selection: mouth) {
                ForEach(SpeechProvider.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("settings.speech.mouth")
            if mouth.wrappedValue == .soniox {
                Picker("Voice", selection: $sonioxVoice) {
                    ForEach(sonioxVoices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("settings.speech.voice")
            } else {
                Picker("Voice", selection: $systemVoice) {
                    Text("Best installed").tag("")
                    ForEach(systemVoices) { Text($0.label).tag($0.id) }
                }
                .accessibilityIdentifier("settings.speech.voice")
            }
            KeychainKeyRow(
                title: "Soniox key", account: BrainSettings.sonioxKeyAccount, saved: $sonioxKeySaved,
                id: "settings.speech.sonioxKey")
        } header: {
            Text("Speech")
        } footer: {
            Text(
                mouth.wrappedValue == .soniox || ears.wrappedValue == .soniox
                    ? "Soniox streams audio to soniox.com and bills per use. Without a key, iPhone speech is used."
                    : "iPhone speech runs on this device. Add voices in iOS Settings, Accessibility, Spoken Content.")
        }
    }

    private var benchmarkSection: some View {
        Section {
            Toggle("Save audio for benchmark", isOn: $saveAudio)
                .accessibilityIdentifier("settings.benchmark.saveAudio")
            if developerMode {
                LabeledContent("Last turn", value: lastTurn?.summary ?? "No turn yet")
                    .accessibilityIdentifier("settings.benchmark.lastTurn")
            }
            Button("Export timings (CSV)") { share(BenchmarkExport.timings) }
                .accessibilityIdentifier("settings.benchmark.exportTimings")
            Button("Export saved audio") { share(BenchmarkExport.audio) }
                .accessibilityIdentifier("settings.benchmark.exportAudio")
            Button("Delete benchmark data", role: .destructive) {
                BrainSettings.benchmarkLog.clear()
                BrainSettings.audioArchive.clear()
                lastTurn = nil
            }
            .accessibilityIdentifier("settings.benchmark.clear")
        } header: {
            Text("Benchmark")
        } footer: {
            if let exportError {
                Text(exportError).foregroundStyle(.red)
            } else {
                Text("Times each voice turn. Saved audio stays on this device until you export it.")
            }
        }
    }

    private func share(_ make: () throws -> URL) {
        do {
            shared = SharedFile(url: try make())
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func loadSonioxVoices() async {
        guard sonioxKeySaved, let key = BrainSettings.sonioxKey else { return }
        let fetched = await SonioxTTS.fetchVoices(apiKey: key)
        if !fetched.isEmpty { sonioxVoices = fetched }
    }
}

struct KeychainKeyRow: View {
    var title: String
    var account: String
    @Binding var saved: Bool
    var id: String
    @State private var draft = ""

    var body: some View {
        LabeledContent(title) {
            if saved {
                HStack(spacing: 12) {
                    Text("Saved").foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(id).saved")
                    Button("Remove", role: .destructive) {
                        PasswordVault.delete(account: account)
                        saved = false
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("\(id).remove")
                }
            } else {
                HStack(spacing: 12) {
                    SecureField("Paste key", text: $draft)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .onSubmit(save)
                        .accessibilityIdentifier(id)
                    if !draft.isEmpty {
                        Button("Save", action: save)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("\(id).save")
                    }
                }
            }
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        PasswordVault.set(key, account: account)
        draft = ""
        saved = true
    }
}

struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum BenchmarkExport {
    struct Empty: LocalizedError {
        var errorDescription: String? { "Nothing recorded yet" }
    }

    static func timings() throws -> URL {
        let log = BrainSettings.benchmarkLog
        guard log.hasTimings else { throw Empty() }
        let target = exportDirectory().appendingPathComponent("pocketshell-voice-timings.csv")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: log.csvURL, to: target)
        return target
    }

    static func audio() throws -> URL {
        let archive = BrainSettings.audioArchive
        guard !archive.entries.isEmpty else { throw Empty() }
        let target = exportDirectory().appendingPathComponent("pocketshell-voice-audio.zip")
        try? FileManager.default.removeItem(at: target)
        var coordinated: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: archive.directory, options: .forUploading, error: &coordinated) {
            zip in
            do {
                try FileManager.default.copyItem(at: zip, to: target)
            } catch {
                copyError = error
            }
        }
        if let error = copyError ?? coordinated { throw error }
        return target
    }

    private static func exportDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBenchmarkExport")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
