import Foundation

/// Talks to Ollama running on this Mac (http://localhost:11434). Plain URLSession, no SDK.
/// API reference: https://docs.ollama.com/api
final class OllamaClient: LLMClient {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        // Max wait between two pieces of data. Loading an 8B model before the first word can take a while.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3 * 60 * 60
        session = URLSession(configuration: config)
    }

    // MARK: - Status

    func isRunning() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "api/version"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func installedModels() async throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        let data = try await send(URLRequest(url: baseURL.appending(path: "api/tags")))
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
    }

    // MARK: - Download a model

    func pull(model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let lines = try await stream(path: "api/pull", body: ["model": model, "stream": true])
        // A model has several files ("layers"); add them up for one overall percentage.
        var layers: [String: (completed: Double, total: Double)] = [:]
        var finished = false
        for try await line in lines {
            guard let json = try Self.parseLine(line) else { continue }
            if let digest = json["digest"] as? String, let total = json["total"] as? Double, total > 0 {
                layers[digest] = ((json["completed"] as? Double) ?? 0, total)
                let done = layers.values.reduce(0) { $0 + $1.completed }
                let all = layers.values.reduce(0) { $0 + $1.total }
                progress(min(0.99, done / all))
            }
            if json["status"] as? String == "success" { finished = true }
        }
        guard finished else { throw LLMError.server("The download stopped before it finished.") }
        progress(1)
    }

    // MARK: - Chat

    func chat(messages: [LLMMessage], options: LLMChatOptions,
              onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        var body: [String: Any] = [
            "model": options.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "think": false, // Qwen3: answer directly, no "thinking" text
            "keep_alive": options.keepAlive,
            "options": ["num_ctx": options.contextLength, "temperature": options.temperature],
        ]
        if let schema = options.jsonSchema {
            body["format"] = schema // structured output: Ollama forces the reply to match this schema
        }

        var reply = ""
        for try await line in try await stream(path: "api/chat", body: body, model: options.model) {
            guard let json = try Self.parseLine(line) else { continue }
            if let message = json["message"] as? [String: Any], let piece = message["content"] as? String {
                reply += piece
                onProgress(reply) // the reply so far, for streaming to the UI
            }
            if json["done"] as? Bool == true { break }
        }
        return reply
    }

    func unload(model: String) async {
        // A request with keep_alive 0 tells Ollama to free the model's memory now.
        var request = URLRequest(url: baseURL.appending(path: "api/generate"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        request.timeoutInterval = 10
        _ = try? await session.data(for: request)
    }

    // MARK: - HTTP helpers

    /// Sends a request and returns the body; turns connection and HTTP errors into LLMError.
    func send(_ request: URLRequest, model: String? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.isConnectionError(error) {
            throw LLMError.notRunning
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 404, let model { throw LLMError.modelMissing(model) }
            throw LLMError.server(Self.errorMessage(in: data) ?? "HTTP \(http.statusCode)")
        }
        return data
    }

    var apiBaseURL: URL { baseURL }

    /// POSTs JSON and returns the reply as lines (Ollama streams one JSON object per line).
    private func stream(path: String, body: [String: Any], model: String? = nil)
        async throws -> AsyncLineSequence<URLSession.AsyncBytes> {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError where Self.isConnectionError(error) {
            throw LLMError.notRunning
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line }
            let message = Self.errorMessage(in: Data(text.utf8)) ?? "HTTP \(http.statusCode)"
            if http.statusCode == 404, let model { throw LLMError.modelMissing(model) }
            throw LLMError.server(message)
        }
        return bytes.lines
    }

    /// Parses one streamed line. Errors can arrive mid-stream as {"error": "..."} even with HTTP 200.
    private static func parseLine(_ line: String) throws -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? String { throw LLMError.server(error) }
        return json
    }

    private static func errorMessage(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    private static func isConnectionError(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet]
            .contains(error.code)
    }
}
