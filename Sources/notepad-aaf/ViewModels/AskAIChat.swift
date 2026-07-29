import Foundation

/// Backing state for one "Ask AI" conversation. The note is captured once, when
/// the chat opens, and sent as system context; follow-up turns keep the running
/// conversation. Errors surface as an assistant bubble marked `isError`.
@MainActor
final class AskAIChat: ObservableObject {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var isError = false
    }

    @Published var messages: [Message] = []
    @Published var input: String = ""
    @Published var isSending = false

    let fileName: String
    let isConfigured: Bool

    /// Insert the given text into the editor at the cursor / over the selection.
    let onInsert: (String) -> Void
    /// Open the app Settings (used by the "not configured" banner).
    let onOpenSettings: () -> Void

    private let systemPrompt: String
    private let config: LLMConfig
    private let service = LLMService()

    init(fileName: String,
         noteText: String,
         config: LLMConfig,
         onInsert: @escaping (String) -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.fileName = fileName
        self.config = config
        self.isConfigured = config.isConfigured
        self.onInsert = onInsert
        self.onOpenSettings = onOpenSettings

        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "(the file is currently empty)" : noteText
        self.systemPrompt = """
        You are an assistant embedded inside a plain-text editor. The user is \
        editing a file named "\(fileName)". Help them with its content — answer \
        questions, explain, rewrite, generate, or fix as asked. When you output \
        code or file content that is meant to be inserted, return just that \
        content without surrounding prose.

        Current contents of the file:
        ---
        \(body)
        ---
        """
    }

    var canSubmit: Bool {
        isConfigured && !isSending &&
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConfigured, !isSending, !prompt.isEmpty else { return }

        input = ""
        messages.append(Message(role: .user, text: prompt))
        isSending = true

        // Send only the real conversation (skip prior error bubbles).
        let history = messages
            .filter { !$0.isError }
            .map { ChatTurn(role: $0.role == .user ? .user : .assistant, text: $0.text) }
        let system = systemPrompt

        Task {
            do {
                let reply = try await service.complete(config: config, system: system, history: history)
                messages.append(Message(role: .assistant, text: reply))
            } catch {
                messages.append(Message(role: .assistant, text: error.localizedDescription, isError: true))
            }
            isSending = false
        }
    }
}
