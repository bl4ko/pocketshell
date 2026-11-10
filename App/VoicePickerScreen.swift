import SwiftUI
import VoiceKit

extension BrainSettings {
    static var voiceLibrary: SonioxVoiceLibrary {
        SonioxVoiceLibrary(
            directory: URL.cachesDirectory.appendingPathComponent("SonioxVoices"), apiKey: { BrainSettings.sonioxKey })
    }

    static func cachedVoices() -> [SonioxVoice] {
        guard isUITest else { return voiceLibrary.cached() }
        let stub = ProcessInfo.processInfo.environment["PS_UI_TEST_VOICES"].flatMap {
            try? SonioxVoiceCatalog.page(Data($0.utf8)).voices
        }
        return SonioxVoiceCatalog.ordered(stub ?? SonioxVoiceCatalog.fallback)
    }

    @MainActor
    static func previewOutput() -> VoicePreviewOutput {
        isUITest ? TimedPreviewOutput(seconds: 8) : SystemPreviewOutput()
    }

    static func sonioxPreview(_ voice: String) -> VoicePreviewPlayer.Loader {
        if isUITest { return { .file(URL(fileURLWithPath: "/dev/null")) } }
        let library = voiceLibrary
        return { .file(try await library.preview(voice: voice)) }
    }
}

struct VoicePickerScreen: View {
    let mouth: SpeechProvider
    @StateObject private var player = VoicePreviewPlayer(output: BrainSettings.previewOutput())

    var body: some View {
        Group {
            if mouth == .soniox {
                SonioxVoiceList(player: player)
            } else {
                SystemVoiceList(player: player)
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
        .paperScreen()
    }
}

private struct SonioxVoiceList: View {
    @ObservedObject var player: VoicePreviewPlayer
    @AppStorage(BrainSettings.sonioxVoiceKey) private var selected = SonioxTTS.defaultVoice
    @State private var voices: [SonioxVoice] = []
    @State private var filter = SonioxVoiceFilter()
    @State private var note: String?

    var body: some View {
        let shown = SonioxVoiceCatalog.filter(voices, filter)
        let genders = SonioxVoiceCatalog.genders(voices)
        let accents = SonioxVoiceCatalog.accents(voices)
        List {
            if !genders.isEmpty || !accents.isEmpty {
                Section {
                    if !genders.isEmpty {
                        Picker("Gender", selection: $filter.gender) {
                            Text("All").tag(String?.none)
                            ForEach(genders, id: \.self) { Text(SonioxVoiceCatalog.label($0)).tag(String?.some($0)) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("voices.filter.gender")
                    }
                    if !accents.isEmpty {
                        Picker("Accent", selection: $filter.accent) {
                            Text("English").tag(SonioxVoiceFilter.Accent.english)
                            Text("All accents").tag(SonioxVoiceFilter.Accent.any)
                            ForEach(accents, id: \.self) {
                                Text(SonioxVoiceCatalog.label($0)).tag(SonioxVoiceFilter.Accent.only($0))
                            }
                        }
                        .accessibilityIdentifier("voices.filter.accent")
                    }
                }
            }
            Section {
                ForEach(shown) { voice in
                    VoiceRow(
                        id: voice.id, name: voice.id, detail: voice.description, tags: voice.tags,
                        selected: voice.id == selected, player: player, load: BrainSettings.sonioxPreview(voice.id)
                    ) { selected = voice.id }
                }
                if shown.isEmpty {
                    Text("No voice matches").foregroundStyle(.secondary)
                        .accessibilityIdentifier("voices.empty")
                }
            } header: {
                Text(shown.count == 1 ? "1 voice" : "\(shown.count) voices")
            } footer: {
                Text(note ?? "Tap a voice to select it and hear it. Soniox bills the first preview of each voice.")
                    .accessibilityIdentifier("voices.note")
            }
        }
        .searchable(
            text: $filter.search, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Name, style, or description"
        )
        .autocorrectionDisabled()
        .onAppear { if voices.isEmpty { voices = BrainSettings.cachedVoices() } }
        .task { await refresh() }
    }

    private func refresh() async {
        guard !BrainSettings.isUITest else { return }
        do {
            voices = try await BrainSettings.voiceLibrary.refresh()
            note = nil
        } catch {
            let reason = (error as? SonioxError)?.previewMessage ?? error.localizedDescription
            note = "Showing the saved voice list. \(reason)."
        }
    }
}

private struct SystemVoiceList: View {
    @ObservedObject var player: VoicePreviewPlayer
    @AppStorage(BrainSettings.voiceKey) private var selected = ""
    @State private var voices: [VoiceChoice] = []

    var body: some View {
        let known = voices.contains { $0.id == selected }
        List {
            Section {
                row(id: "", name: "Best installed", detail: "The highest quality English voice", selected: !known)
                ForEach(voices) { voice in
                    row(
                        id: voice.id, name: voice.name, detail: "\(voice.language), \(voice.quality.label)",
                        selected: voice.id == selected)
                }
            } footer: {
                Text("Add voices in iOS Settings, Accessibility, Spoken Content.")
            }
        }
        .onAppear { voices = SpeechVoices.ranked(SpeechVoices.installed()) }
    }

    private func row(id: String, name: String, detail: String, selected isSelected: Bool) -> some View {
        VoiceRow(
            id: id.isEmpty ? "best" : id, name: name, detail: detail, tags: [], selected: isSelected, player: player,
            load: { .speech(text: SonioxVoiceLibrary.sentence, voiceIdentifier: id.isEmpty ? nil : id) }
        ) { selected = id }
    }
}

private struct VoiceRow: View {
    let id: String
    let name: String
    let detail: String
    let tags: [String]
    let selected: Bool
    @ObservedObject var player: VoicePreviewPlayer
    let load: VoicePreviewPlayer.Loader
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    select()
                    player.play(id, load: load)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(PocketshellTheme.ink)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(PocketshellTheme.secondary)
                                .lineLimit(2)
                        }
                        if !tags.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(PocketshellTheme.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(PocketshellTheme.secondarySurface, in: Capsule())
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("voices.row.\(id)")
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                        .accessibilityIdentifier("voices.selected.\(id)")
                }
                Button {
                    player.toggle(id, load: load)
                } label: {
                    Group {
                        if player.state == .loading(id) {
                            ProgressView()
                        } else {
                            Image(systemName: player.state == .playing(id) ? "stop.circle.fill" : "play.circle")
                                .font(.title2)
                        }
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(player.isActive(id) ? "Stop preview of \(name)" : "Play preview of \(name)")
                .accessibilityValue(status)
                .accessibilityIdentifier("voices.play.\(id)")
            }
            if let error = player.error(for: id) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("voices.error")
            }
        }
    }

    private var status: String {
        switch player.state {
        case .loading(id): "Loading"
        case .playing(id): "Playing"
        default: "Stopped"
        }
    }
}
