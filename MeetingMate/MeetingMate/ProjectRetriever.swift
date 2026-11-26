import Accelerate
import Foundation

/// One search result.
struct RetrievedChunk: Equatable, Identifiable {
    let id: Int64
    let path: String
    let sourceType: SourceType
    let location: String
    let text: String
    let meetingDate: Date?
    let score: Double
}

/// What to search in: which kinds of sources, and (for meetings) which dates.
struct SearchFilter: Equatable {
    /// nil = everything.
    var sourceTypes: Set<SourceType>?
    /// Meetings outside [from, to) are skipped; documents are not affected by dates.
    var meetingsFrom: Date?
    var meetingsTo: Date?

    func allows(_ type: SourceType, meetingDate: Double?) -> Bool {
        if let sourceTypes, !sourceTypes.contains(type) { return false }
        guard let meetingDate else { return true }
        if let meetingsFrom, meetingDate < meetingsFrom.timeIntervalSince1970 { return false }
        if let meetingsTo, meetingDate >= meetingsTo.timeIntervalSince1970 { return false }
        return true
    }
}

/// Search results plus how confident the best match is (for the "not found" check).
struct SearchOutcome {
    var chunks: [RetrievedChunk]
    /// Highest cosine similarity among allowed chunks (nil if vector search wasn't available).
    var bestSimilarity: Float?
    /// How many chunks matched by keyword.
    var keywordHits: Int
}

/// Hybrid search over the project index: vectors (meaning) + FTS5 (exact words, names, codes).
/// Phase 5 (Ask window) reuses `search(query:limit:)` and `searchDetailed`.
final class ProjectRetriever {
    /// How many candidates each method contributes before fusion.
    static let candidatesPerMethod = 50
    static let maxChunksPerFile = 2

    private let store: IndexStore
    private let embedder: EmbeddingClient?
    private let model: String

    // Cached vector matrix, reloaded when the index changes.
    private typealias Vectors = (ids: [Int64], meta: [IndexStore.ChunkMeta], dimensions: Int, matrix: [Float])
    private var cache: (counter: Int, vectors: Vectors)?
    private let lock = NSLock()

    init(store: IndexStore, embedder: EmbeddingClient?, model: String) {
        self.store = store
        self.embedder = embedder
        self.model = model
    }

    /// Best `limit` chunks for one query.
    /// - Parameter excludingPathPrefix: skip chunks under this path (e.g. the meeting being summarized).
    func search(query: String, limit: Int = 8, excludingPathPrefix: String? = nil) async throws -> [RetrievedChunk] {
        try await search(queries: [query], limit: limit, excludingPathPrefix: excludingPathPrefix)
    }

    /// Several queries at once (used by summaries): every query's lists are fused together.
    func search(queries: [String], limit: Int = 8, excludingPathPrefix: String? = nil,
                now: Date = Date()) async throws -> [RetrievedChunk] {
        try await searchDetailed(queries: queries, limit: limit, excludingPathPrefix: excludingPathPrefix, now: now).chunks
    }

    /// Like `search`, with a scope/date filter and the scores needed to decide "not found".
    func searchDetailed(queries: [String], limit: Int = 8, filter: SearchFilter = SearchFilter(),
                        excludingPathPrefix: String? = nil, now: Date = Date()) async throws -> SearchOutcome {
        let queries = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !queries.isEmpty else { return SearchOutcome(chunks: [], bestSimilarity: nil, keywordHits: 0) }

        var rankedLists: [[Int64]] = []
        var bestSimilarity: Float?

        // 1. Vector search (skipped if Ollama/the model isn't available: keyword search still works).
        if let embedder, let queryVectors = try? await embedder.embed(queries, model: model) {
            let vectors = try loadVectors()
            if vectors.dimensions > 0 {
                for query in queryVectors where query.count == vectors.dimensions {
                    var scores = Ranking.cosineScores(matrix: vectors.matrix, dimensions: vectors.dimensions,
                                                      query: query)
                    for i in scores.indices
                    where !filter.allows(vectors.meta[i].sourceType, meetingDate: vectors.meta[i].meetingDate) {
                        scores[i] = -.infinity // outside the chosen scope
                    }
                    let top = Ranking.topIndices(scores, count: Self.candidatesPerMethod).filter { scores[$0] > -.infinity }
                    if let first = top.first { bestSimilarity = max(bestSimilarity ?? -1, scores[first]) }
                    rankedLists.append(top.map { vectors.ids[$0] })
                }
            }
        }

        // 2. Keyword search (bm25).
        var keywordHits = 0
        for query in queries {
            let hits = try store.keywordSearch(query, limit: Self.candidatesPerMethod, filter: filter)
            keywordHits += hits.count
            rankedLists.append(hits)
        }

        // 3. Reciprocal rank fusion, then a small bonus for recent meetings.
        let fused = Ranking.reciprocalRankFusion(rankedLists)
        let candidateIDs = fused.sorted { $0.value > $1.value }.prefix(limit * 6).map(\.key)
        let records = try store.chunks(ids: Array(candidateIDs))
        let candidates: [RetrievedChunk] = records.compactMap { record in
            guard let id = record.id, let base = fused[id] else { return nil }
            if let prefix = excludingPathPrefix, record.path.hasPrefix(prefix) { return nil }
            let meetingDate = record.meetingDate.map { Date(timeIntervalSince1970: $0) }
            return RetrievedChunk(id: id, path: record.path, sourceType: record.sourceType,
                                  location: record.location, text: record.text, meetingDate: meetingDate,
                                  score: base + Ranking.recencyBonus(meetingDate: meetingDate, now: now))
        }

        // 4. Best first, at most 2 chunks per file.
        let chunks = Ranking.diversify(candidates.sorted { $0.score > $1.score },
                                       perFile: Self.maxChunksPerFile, limit: limit)
        return SearchOutcome(chunks: chunks, bestSimilarity: bestSimilarity, keywordHits: keywordHits)
    }

    private func loadVectors() throws -> Vectors {
        let counter = store.currentChangeCounter
        if let cache = lock.withLock({ self.cache }), cache.counter == counter {
            return cache.vectors
        }
        let loaded = try store.vectorMatrix()
        lock.withLock { cache = (counter, loaded) }
        return loaded
    }
}

// MARK: - Ranking math (pure functions, unit-tested)

enum Ranking {
    /// RRF constant: 60 is the usual choice; it keeps any single list from dominating.
    static let rrfK = 60.0
    /// Up to this much extra score for a meeting from today, fading over ~2 months.
    /// (The top RRF score from one list is 1/61 ≈ 0.016, so this only breaks near-ties.)
    static let maxRecencyBonus = 0.002
    static let recencyDays = 60.0

    /// Cosine similarity of the query with every row (vectors are unit length, so a dot product is enough).
    static func cosineScores(matrix: [Float], dimensions: Int, query: [Float]) -> [Float] {
        let rows = matrix.count / dimensions
        guard rows > 0, query.count == dimensions else { return [] }
        var scores = [Float](repeating: 0, count: rows)
        // (rows × dims) · (dims × 1) = rows × 1
        vDSP_mmul(matrix, 1, query, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(dimensions))
        return scores
    }

    /// Indices of the `count` highest scores, best first.
    static func topIndices(_ scores: [Float], count: Int) -> [Int] {
        Array(scores.indices.sorted { scores[$0] > scores[$1] }.prefix(count))
    }

    /// Reciprocal rank fusion: each list adds 1 / (k + rank) for every item in it.
    static func reciprocalRankFusion(_ lists: [[Int64]]) -> [Int64: Double] {
        var scores: [Int64: Double] = [:]
        for list in lists {
            for (rank, id) in list.enumerated() {
                scores[id, default: 0] += 1 / (rrfK + Double(rank + 1))
            }
        }
        return scores
    }

    static func recencyBonus(meetingDate: Date?, now: Date) -> Double {
        guard let meetingDate else { return 0 }
        let days = max(0, now.timeIntervalSince(meetingDate) / 86_400)
        return maxRecencyBonus * exp(-days / recencyDays)
    }

    /// Keeps the order, but at most `perFile` chunks from the same file.
    static func diversify(_ sorted: [RetrievedChunk], perFile: Int, limit: Int) -> [RetrievedChunk] {
        var perPath: [String: Int] = [:]
        var result: [RetrievedChunk] = []
        for chunk in sorted where result.count < limit {
            guard perPath[chunk.path, default: 0] < perFile else { continue }
            perPath[chunk.path, default: 0] += 1
            result.append(chunk)
        }
        return result
    }
}
