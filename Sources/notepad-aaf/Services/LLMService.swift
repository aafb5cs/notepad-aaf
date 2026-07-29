import Foundation

/// One turn in the chat we send to the model. `system` context (the note) is
/// passed separately — it isn't part of this history.
struct ChatTurn {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

enum LLMError: LocalizedError {
    case notConfigured
    case badURL
    case http(status: Int, message: String)
    case emptyResponse
    case decoding
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No API key set. Open Settings → AI and add your key."
        case .badURL:
            return "The API base URL is invalid."
        case .http(let status, let message):
            return "Request failed (HTTP \(status)): \(message)"
        case .emptyResponse:
            return "The model returned an empty response."
        case .decoding:
            return "Couldn't understand the response from the API."
        case .transport(let message):
            return "Network error: \(message)"
        }
    }
}

/// Sends a chat completion to the configured provider and returns the assistant
/// text. Non-streaming; `max_tokens` is kept modest so requests finish well
/// within the default URLSession timeout.
struct LLMService {
    private let maxTokens = 4096

    func complete(config: LLMConfig, system: String, history: [ChatTurn]) async throws -> String {
        guard config.isConfigured else { throw LLMError.notConfigured }
        switch config.provider {
        case .anthropic:
            return try await sendAnthropic(config: config, system: system, history: history)
        case .openAICompatible:
            return try await sendOpenAI(config: config, system: system, history: history)
        }
    }

    // MARK: - Anthropic (Messages API)

    private func sendAnthropic(config: LLMConfig, system: String, history: [ChatTurn]) async throws -> String {
        guard let url = URL(string: config.baseURL + "/v1/messages") else { throw LLMError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = AnthropicRequest(
            model: config.model,
            max_tokens: maxTokens,
            system: system,
            messages: history.map { .init(role: $0.role.rawValue, content: $0.text) })
        request.httpBody = try JSONEncoder().encode(body)

        let (data, http) = try await send(request)
        guard http.statusCode == 200 else {
            throw LLMError.http(status: http.statusCode, message: extractError(data))
        }
        guard let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: data) else {
            throw LLMError.decoding
        }
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    // MARK: - OpenAI-compatible (Chat Completions)

    private func sendOpenAI(config: LLMConfig, system: String, history: [ChatTurn]) async throws -> String {
        guard let url = URL(string: config.baseURL + "/chat/completions") else { throw LLMError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        var messages = [OpenAIRequest.Msg(role: "system", content: system)]
        messages += history.map { .init(role: $0.role.rawValue, content: $0.text) }
        let body = OpenAIRequest(model: config.model, max_tokens: maxTokens, messages: messages)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, http) = try await send(request)
        guard http.statusCode == 200 else {
            throw LLMError.http(status: http.statusCode, message: extractError(data))
        }
        guard let decoded = try? JSONDecoder().decode(OpenAIResponse.self, from: data),
              let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        return text
    }

    // MARK: - Transport

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.transport("no response") }
            return (data, http)
        } catch let error as LLMError {
            throw error
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
    }

    /// Both providers wrap errors as `{"error": {"message": ...}}`; fall back to
    /// the raw body if that shape isn't present.
    private func extractError(_ data: Data) -> String {
        if let wrapped = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return wrapped.error.message
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "unknown error" : String(raw.prefix(300))
    }
}

// MARK: - Wire types

private struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [Msg]
    struct Msg: Encodable { let role: String; let content: String }
}

private struct AnthropicResponse: Decodable {
    let content: [Block]
    struct Block: Decodable { let type: String; let text: String? }
}

private struct OpenAIRequest: Encodable {
    let model: String
    let max_tokens: Int
    let messages: [Msg]
    struct Msg: Encodable { let role: String; let content: String }
}

private struct OpenAIResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable { let message: Msg }
    struct Msg: Decodable { let content: String }
}

private struct APIErrorEnvelope: Decodable {
    let error: Body
    struct Body: Decodable { let message: String }
}
