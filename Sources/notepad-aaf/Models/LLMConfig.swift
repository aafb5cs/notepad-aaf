import Foundation

/// Which LLM backend "Ask AI" talks to. Both are reached over raw HTTPS — there
/// is no official Swift SDK — so the provider only decides the endpoint shape,
/// auth header, and request/response JSON.
enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    /// Model used when the user leaves the model field blank.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-4-8"
        case .openAICompatible: return "gpt-4o"
        }
    }

    /// Base URL used when the user leaves the base-URL field blank.
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAICompatible: return "https://api.openai.com/v1"
        }
    }
}

/// A resolved snapshot of the AI settings, ready to hand to `LLMService`.
/// Blank model / base URL fall back to the provider defaults here so the rest of
/// the code never has to.
struct LLMConfig {
    let provider: LLMProvider
    let apiKey: String
    let model: String
    let baseURL: String

    init(provider: LLMProvider, apiKey: String, model: String, baseURL: String) {
        self.provider = provider
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = m.isEmpty ? provider.defaultModel : m
        let b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = (b.isEmpty ? provider.defaultBaseURL : b)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var isConfigured: Bool { !apiKey.isEmpty }
}
