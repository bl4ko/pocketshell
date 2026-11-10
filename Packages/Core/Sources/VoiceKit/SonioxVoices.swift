import CryptoKit
import Foundation

public struct SonioxVoice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var description: String
    public var gender: String
    public var age: String
    public var accent: String
    public var useCases: [String]
    public var styles: [String]

    public init(
        id: String, description: String = "", gender: String = "", age: String = "", accent: String = "",
        useCases: [String] = [], styles: [String] = []
    ) {
        self.id = id
        self.description = description
        self.gender = gender
        self.age = age
        self.accent = accent
        self.useCases = useCases
        self.styles = styles
    }

    enum CodingKeys: String, CodingKey {
        case id, description, gender, age, accent
        case useCases = "use_case"
        case styles = "style"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        gender = try container.decodeIfPresent(String.self, forKey: .gender) ?? ""
        age = try container.decodeIfPresent(String.self, forKey: .age) ?? ""
        accent = try container.decodeIfPresent(String.self, forKey: .accent) ?? ""
        useCases = try container.decodeIfPresent([String].self, forKey: .useCases) ?? []
        styles = try container.decodeIfPresent([String].self, forKey: .styles) ?? []
    }

    public var tags: [String] {
        ([gender, accent] + styles.prefix(2)).filter { !$0.isEmpty }.map(SonioxVoiceCatalog.label)
    }
}

public struct SonioxVoiceFilter: Equatable, Sendable {
    public enum Accent: Hashable, Sendable {
        case english
        case any
        case only(String)
    }

    public var gender: String?
    public var accent: Accent
    public var search: String

    public init(gender: String? = nil, accent: Accent = .english, search: String = "") {
        self.gender = gender
        self.accent = accent
        self.search = search
    }

    func matches(_ voice: SonioxVoice) -> Bool {
        if let gender, voice.gender != gender { return false }
        switch accent {
        case .english: if !voice.accent.isEmpty, !SonioxVoiceCatalog.isEnglish(voice.accent) { return false }
        case .only(let accent): if voice.accent != accent { return false }
        case .any: break
        }
        let text = ([voice.id, voice.description, voice.accent] + voice.styles).joined(separator: " ")
        return search.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedStandardContains($0) }
    }
}

public enum SonioxVoiceCatalog {
    public static let url = URL(string: "https://api.soniox.com/v1/shared-voices")!
    public static let englishAccents = ["american", "british", "australian"]
    public static let fallback = SonioxTTS.voices.map { SonioxVoice(id: $0) }

    public struct Page: Decodable, Equatable, Sendable {
        public var voices: [SonioxVoice]
        public var cursor: String?

        enum CodingKeys: String, CodingKey {
            case voices
            case cursor = "next_page_cursor"
        }
    }

    public static func isEnglish(_ accent: String) -> Bool { englishAccents.contains(accent) }

    public static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public static func page(_ data: Data) throws -> Page {
        try JSONDecoder().decode(Page.self, from: data)
    }

    public static func request(apiKey: String, model: String = SonioxTTS.model, cursor: String? = nil) -> URLRequest {
        var items = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "limit", value: "200")]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        var request = URLRequest(url: url.appending(queryItems: items))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func ordered(_ voices: [SonioxVoice]) -> [SonioxVoice] {
        func rank(_ voice: SonioxVoice) -> (Int, Int, Int) {
            (
                SonioxTTS.voices.firstIndex(of: voice.id) ?? Int.max, isEnglish(voice.accent) ? 0 : 1,
                voice.useCases.contains("conversational") ? 0 : 1
            )
        }
        return voices.sorted { a, b in
            let (left, right) = (rank(a), rank(b))
            return left != right ? left < right : a.id < b.id
        }
    }

    public static func filter(_ voices: [SonioxVoice], _ filter: SonioxVoiceFilter) -> [SonioxVoice] {
        voices.filter(filter.matches)
    }

    public static func accents(_ voices: [SonioxVoice]) -> [String] {
        let all = Set(voices.map(\.accent).filter { !$0.isEmpty })
        return englishAccents.filter(all.contains) + all.filter { !isEnglish($0) }.sorted()
    }

    public static func genders(_ voices: [SonioxVoice]) -> [String] {
        Set(voices.map(\.gender).filter { !$0.isEmpty }).sorted()
    }
}

public typealias SonioxHTTP = @Sendable (URLRequest) async throws -> (Data, URLResponse)

extension SonioxError {
    public static let missingKey = SonioxError(.auth, message: "Add a Soniox key in Settings to hear Soniox voices")

    public var previewMessage: String { self == .missingKey ? message : notice }

    static func http(status: Int, body: Data) -> SonioxError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let type = object["error_type"] as? String
        let message = object["error_message"] as? String ?? object["message"] as? String ?? "HTTP \(status)"
        let auth = status == 401 || status == 403 || type == "unauthenticated"
        return SonioxError(auth ? .auth : .server, code: status, type: type, message: message)
    }

    static func transport(_ error: Error) -> SonioxError {
        if let error = error as? SonioxError { return error }
        let timedOut = (error as? URLError)?.code == .timedOut
        return SonioxError(timedOut ? .timeout : .network, message: error.localizedDescription)
    }
}

public struct SonioxVoiceLibrary: Sendable {
    public static let sentence = "Hi, I'm your PocketShell voice. Claude just finished and all tests pass."
    public static let speechURL = URL(string: "https://tts-rt.soniox.com/tts")!

    public let directory: URL
    private let apiKey: @Sendable () -> String?
    private let http: SonioxHTTP

    public init(
        directory: URL, apiKey: @escaping @Sendable () -> String?,
        http: @escaping SonioxHTTP = { try await URLSession.shared.data(for: $0) }
    ) {
        self.directory = directory
        self.apiKey = apiKey
        self.http = http
    }

    public func cached(model: String = SonioxTTS.model) -> [SonioxVoice] {
        guard let data = try? Data(contentsOf: catalogFile(model)),
            let voices = try? JSONDecoder().decode([SonioxVoice].self, from: data), !voices.isEmpty
        else { return SonioxVoiceCatalog.fallback }
        return SonioxVoiceCatalog.ordered(voices)
    }

    public func refresh(model: String = SonioxTTS.model) async throws -> [SonioxVoice] {
        let key = try key()
        var voices: [SonioxVoice] = []
        var cursor: String?
        repeat {
            let data = try await send(SonioxVoiceCatalog.request(apiKey: key, model: model, cursor: cursor))
            guard let page = try? SonioxVoiceCatalog.page(data) else {
                throw SonioxError(.server, message: "Unreadable voice list")
            }
            voices += page.voices
            cursor = page.cursor.flatMap { $0.isEmpty ? nil : $0 }
        } while cursor != nil && voices.count < 2000
        guard !voices.isEmpty else { throw SonioxError(.server, message: "Soniox returned no voices") }
        write(try? JSONEncoder().encode(voices), to: catalogFile(model))
        return SonioxVoiceCatalog.ordered(voices)
    }

    public func previewFile(voice: String, model: String = SonioxTTS.model) -> URL {
        let digest = SHA256.hash(data: Data("\(model)|\(voice)|\(Self.sentence)".utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("preview-\(name).wav")
    }

    #if !os(watchOS)
        public func preview(voice: String, model: String = SonioxTTS.model) async throws -> URL {
            let file = previewFile(voice: voice, model: model)
            if FileManager.default.fileExists(atPath: file.path) { return file }
            let pcm = try await send(Self.speechRequest(apiKey: try key(), voice: voice, model: model))
            guard pcm.count > 1 else { throw SonioxError(.server, message: "Soniox returned no audio") }
            write(PCM.wav(s16le: pcm, sampleRate: SonioxTTS.sampleRate), to: file)
            return file
        }
    #endif

    public static func speechRequest(apiKey: String, voice: String, model: String = SonioxTTS.model) -> URLRequest {
        var request = URLRequest(url: speechURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            SonioxJSON.string([
                "model": model, "language": "en", "voice": voice, "audio_format": "pcm_s16le",
                "sample_rate": SonioxTTS.sampleRate, "text": sentence,
            ]).utf8)
        return request
    }

    private func key() throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw SonioxError.missingKey }
        return key
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http(request)
        } catch {
            throw SonioxError.transport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SonioxError.http(status: status, body: data) }
        return data
    }

    private func catalogFile(_ model: String) -> URL {
        let safe = model.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("voices-\(safe).json")
    }

    private func write(_ data: Data?, to file: URL) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
