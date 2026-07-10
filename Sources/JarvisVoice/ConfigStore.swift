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

    /// Chat-completions endpoint (OpenAI-compatible on both) - used for the
    /// fast style post-processing pass.
    var chatEndpoint: URL {
        switch self {
        case .openai: return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .groq: return URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        }
    }

    /// Model for style post-processing. Groq's llama-3.3-70b cleans text in
    /// ~0.3s; gpt-4o-mini is OpenAI's fast, cheap equivalent.
    var defaultStyleModel: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .groq: return "llama-3.3-70b-versatile"
        }
    }

    /// Default model per provider (used when the user hasn't picked one).
    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini-transcribe"
        case .groq: return "whisper-large-v3-turbo"
        }
    }

    /// One selectable model. `usdPerMinute` feeds the cost dashboard; update the
    /// rates here if OpenAI/Groq change their published prices.
    struct ModelOption: Identifiable, Hashable {
        let id: String       // API model name
        let label: String    // shown in the Settings picker
        let usdPerMinute: Double
    }

    /// Models the user can choose between per provider. First entry = default.
    var availableModels: [ModelOption] {
        switch self {
        case .openai:
            return [
                ModelOption(id: "gpt-4o-mini-transcribe", label: "gpt-4o-mini-transcribe - fast, cheap", usdPerMinute: 0.003),
                ModelOption(id: "gpt-4o-transcribe", label: "gpt-4o-transcribe - most accurate", usdPerMinute: 0.006),
                ModelOption(id: "whisper-1", label: "whisper-1 - classic Whisper", usdPerMinute: 0.006)
            ]
        case .groq:
            return [
                ModelOption(id: "whisper-large-v3-turbo", label: "whisper-large-v3-turbo - fastest", usdPerMinute: 0.000667),
                ModelOption(id: "whisper-large-v3", label: "whisper-large-v3 - most accurate", usdPerMinute: 0.00185)
            ]
        }
    }

    /// USD per minute for a specific model, falling back to the default rate.
    func price(forModel model: String) -> Double {
        availableModels.first { $0.id == model }?.usdPerMinute ?? pricePerMinute
    }

    /// USD per minute for the provider's default model - for legacy displays.
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
    var openai_model: String?
    var groq_model: String?
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

    /// The model to use for a provider: the user's saved choice if it's still a
    /// valid option, otherwise the provider default.
    func model(for provider: TranscriptionProvider) -> String {
        let saved: String?
        switch provider {
        case .openai: saved = data.openai_model
        case .groq: saved = data.groq_model
        }
        if let m = saved, !m.isEmpty,
           provider.availableModels.contains(where: { $0.id == m }) {
            return m
        }
        return provider.defaultModel
    }

    func setModel(_ model: String, for provider: TranscriptionProvider) {
        switch provider {
        case .openai: data.openai_model = model
        case .groq: data.groq_model = model
        }
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

    /// Provider used for the style post-processing chat call. Prefers Groq for
    /// speed (~0.3s), else the active transcription provider, else OpenAI -
    /// whichever has a usable key. Nil means no API styling is possible.
    var styleProvider: TranscriptionProvider? {
        if apiKey(for: .groq) != nil { return .groq }
        if apiKey(for: activeProvider) != nil { return activeProvider }
        if apiKey(for: .openai) != nil { return .openai }
        return nil
    }
}
