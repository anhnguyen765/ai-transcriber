import Accelerate
import Foundation

/// Turns texts into vectors (embeddings) for semantic search. Today: Ollama with bge-m3.
protocol EmbeddingClient: AnyObject {
    /// One unit-length vector per text, in the same order.
    func embed(_ texts: [String], model: String) async throws -> [[Float]]
}

extension OllamaClient: EmbeddingClient {
    /// POST /api/embed with several texts at once (https://docs.ollama.com/api/embed).
    func embed(_ texts: [String], model: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        struct Reply: Decodable { let embeddings: [[Float]] }

        var request = URLRequest(url: apiBaseURL.appending(path: "api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": texts,
            "truncate": true,      // cut texts longer than the model's context instead of failing
            "keep_alive": "30s",   // free the model's memory soon after indexing
        ])
        let data = try await send(request, model: model)
        let vectors = try JSONDecoder().decode(Reply.self, from: data).embeddings
        guard vectors.count == texts.count else {
            throw LLMError.server("Expected \(texts.count) embeddings, got \(vectors.count).")
        }
        // Ollama already returns unit-length vectors; normalizing again is cheap and makes sure.
        return vectors.map(Vector.normalized)
    }
}

/// Small vector helpers (Accelerate).
enum Vector {
    static func normalized(_ v: [Float]) -> [Float] {
        var length: Float = 0
        vDSP_svesq(v, 1, &length, vDSP_Length(v.count)) // sum of squares
        length = length.squareRoot()
        guard length > 0 else { return v }
        return vDSP.divide(v, length)
    }

    /// Float32 bytes for storing in SQLite.
    static func data(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
