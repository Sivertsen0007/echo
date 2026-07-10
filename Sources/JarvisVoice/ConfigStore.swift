import Foundation

/// Available transcription providers. Both are OpenAI-API-compatible Whisper
/// endpoints, so we only have to swap URL + auth + model name.
enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case openai
    case groq

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq: return "Groq"
        }
    }

    var endpoint: URL {
        switch self {
        case .openai: return URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        case .groq: return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        }
    }

    /// Default model per provider. User can override later if we add a picker.
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        }
    }

    /// USD per minute of audio - for the cost dashboard.
    var pricePerMinute: Double {
        switch self {
        case .openai: return 0.003     // gpt-4o-mini-transcribe
        case .groq: return 0.000667    // whisper-large-v3-turbo ($0.04/hr)
        }
    }

    var signupURL: URL {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .groq: return URL(string: "https://console.groq.com/keys")!
        }
    }
}

/// Lives at ~/.jarvis-voice/config.json. Holds API keys + active provider.
///
/// We migrate from the older single-key format on first load: if there's an
/// openai_api_key but no `provider`, we default the provider to OpenAI.
struct ConfigData: Codable {
    var provider: String?
    var openai_api_key: String?
    var groq_api_key: String?
}

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    private let url: URL
    @Published private(set) var data: ConfigData = ConfigData()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis-voice")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("config.json")
        load()
    }

    func load() {
        guard let raw = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode(ConfigData.self, from: raw) {
            data = decoded
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? enc.encode(data) {
            try? encoded.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    var activeProvider: TranscriptionProvider {
        if let p = data.provider, let v = TranscriptionProvider(rawValue: p) { return v }
        return .openai
    }

    func setProvider(_ p: TranscriptionProvider) {
        data.provider = p.rawValue
        save()
    }

    func apiKey(for provider: TranscriptionProvider) -> String? {
        switch provider {
        case .openai:
            if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
            let k = data.openai_api_key
            return (k?.isEmpty == false) ? k : nil
        case .groq:
            if let env = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !env.isEmpty { return env }
            let k = data.groq_api_key
            return (k?.isEmpty == false) ? k : nil
        }
    }

    func setApiKey(_ key: String, for provider: TranscriptionProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .openai: data.openai_api_key = trimmed.isEmpty ? nil : trimmed
        case .groq: data.groq_api_key = trimmed.isEmpty ? nil : trimmed
        }
        save()
    }

    var hasKeyForActiveProvider: Bool {
        apiKey(for: activeProvider) != nil
    }
}
