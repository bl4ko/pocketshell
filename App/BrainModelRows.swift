import BrainKit
import KeyKit
import SwiftUI

extension BrainSettings {
    static func model(_ stored: String?) -> String {
        let model = (stored ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? defaultModel : model
    }

    static var connection: (url: URL, key: String)? {
        let env = ProcessInfo.processInfo.environment
        if isUITest, let url = env["PS_UI_TEST_BRAIN_URL"].flatMap(URL.init(string:)) {
            return (url, env["PS_UI_TEST_BRAIN_KEY"] ?? "")
        }
        let raw = (UserDefaults.standard.string(forKey: baseURLKey) ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme != nil, url.host != nil else { return nil }
        return (url, PasswordVault.get(account: apiKeyAccount) ?? "")
    }

    static func client(model: String) -> OpenAIChatClient? {
        connection.map { OpenAIChatClient(baseURL: $0.url, apiKey: $0.key, model: model) }
    }
}

struct BrainModelRows: View {
    var endpoint: String
    var keySaved: Bool
    @AppStorage(BrainSettings.modelKey) private var stored = BrainSettings.defaultModel
    @State private var models: [String] = []
    @State private var listNote: String?
    @State private var ready = false
    @State private var custom = false
    @State private var draft = ""
    @State private var check: ModelCheck?
    @State private var checking = false
    @State private var checkRun = 0

    private var current: String { BrainSettings.model(stored) }

    private var selection: Binding<String> {
        Binding(
            get: { custom ? "" : current },
            set: { picked in
                custom = picked.isEmpty
                draft = ""
                if !custom { use(picked) }
            })
    }

    var body: some View {
        Picker("Model", selection: selection) {
            ForEach(BrainModelList.choices(models, current: current), id: \.self) { Text($0).tag($0) }
            Text("Custom…").tag("")
        }
        .accessibilityIdentifier("settings.brain.model")
        if custom {
            LabeledContent("Model id") {
                TextField("Type an id", text: $draft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        custom = false
                        let id = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !id.isEmpty { use(id) }
                    }
                    .accessibilityIdentifier("settings.brain.model.custom")
            }
        }
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let listNote {
                    Text(listNote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.brain.model.list")
                }
                if ready {
                    Text(checking ? "Testing \(current)…" : check?.note ?? "Not tested")
                        .foregroundStyle(checkColor)
                        .accessibilityIdentifier("settings.brain.model.check")
                }
            }
            .font(.footnote)
            Spacer()
            Button("Test") { checkRun += 1 }
                .buttonStyle(.borderless)
                .disabled(checking || !ready)
                .accessibilityIdentifier("settings.brain.model.test")
        }
        .task(id: [endpoint, String(keySaved)]) { await reload() }
        .task(id: checkRun) { await runCheck() }
        .onChange(of: [endpoint, String(keySaved)]) { check = nil }
    }

    private var checkColor: Color {
        if checking { return .secondary }
        switch check {
        case .works: return .green
        case .failed: return .red
        case nil: return .secondary
        }
    }

    private func use(_ model: String) {
        stored = model
        checkRun += 1
    }

    private func reload() async {
        guard let connection = BrainSettings.connection else {
            ready = false
            models = []
            listNote = BrainError.notConfigured.note
            return
        }
        let cache = BrainModelCache()
        ready = true
        models = cache.models(for: connection.url)
        listNote = "Loading models…"
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let client = OpenAIChatClient(baseURL: connection.url, apiKey: connection.key, model: current)
            models = try await client.models()
            cache.save(models, for: connection.url)
            listNote = models.isEmpty ? "The endpoint lists no chat models" : nil
        } catch {
            if let error = error as? BrainError { listNote = error.note }
        }
    }

    private func runCheck() async {
        guard checkRun > 0, let client = BrainSettings.client(model: current) else { return }
        checking = true
        let result = await client.check()
        guard !Task.isCancelled else { return }
        check = result
        checking = false
    }
}
