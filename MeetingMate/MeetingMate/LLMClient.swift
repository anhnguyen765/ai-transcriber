import Foundation

/// One chat message ("system", "user" or "assistant").
struct LLMMessage: Equatable {
    var role: String
    var content: String

    static func system(_ text: String) -> LLMMessage { LLMMessage(role: "system", content: text) }
    static func user(_ text: String) -> LLMMessage { LLMMessage(role: "user", content: text) }
    static func assistant(_ text: String) -> LLMMessage { LLMMessage(role: "assistant", content: text) }
}

struct LLMChatOptions {
    var model: String
    /// JSON Schema the reply must follow (structured output). nil = free text.
    var jsonSchema: [String: Any]?
    var contextLength = 8192
    var temperature = 0.3
    /// How long the model stays in memory after the request ("30s" frees memory soon after).
    var keepAlive = "30s"
}

enum LLMError: LocalizedError {
    case notRunning
    case modelMissing(String)
    case server(String)
    case invalidReply(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Ollama chưa chạy"
        case .modelMissing(let model): "Model \(model) chưa được tải về"
        case .server(let message): "Ollama: \(message)"
        case .invalidReply(let message): "The model's reply was not valid: \(message)"
        }
    }
}

/// Anything that can run a chat model. Today: Ollama on this Mac. Later: other providers.
protocol LLMClient: AnyObject {
    /// Is the server reachable?
    func isRunning() async -> Bool
    /// Names of the models that are installed (e.g. "qwen3:8b").
    func installedModels() async throws -> [String]
    /// Downloads a model, reporting 0…1.
    func pull(model: String, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Sends a chat and returns the full reply. `onProgress` gets the reply received so far (for streaming).
    func chat(messages: [LLMMessage], options: LLMChatOptions,
              onProgress: @escaping @Sendable (String) -> Void) async throws -> String
    /// Frees the model's memory right away.
    func unload(model: String) async
}

/// Makes sure only one big model is in memory at a time:
/// WhisperKit (~1.5 GB) and the LLM (~6 GB) never run together.
actor HeavyWorkLock {
    static let shared = HeavyWorkLock()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume() // hand the lock straight to the next waiter
        }
    }
}
