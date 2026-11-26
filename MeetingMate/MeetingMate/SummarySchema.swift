import Foundation

/// The final summary (also saved as summary.json).
struct MeetingSummary: Codable, Equatable {
    var title: String
    var overview: String
    var keyPoints: [SummaryItem]
    var decisions: [SummaryItem]
    var actionItems: [ActionItem]
    var openQuestions: [SummaryItem]
    // Phase 4 (only when project context was used):
    var relatedDocs: [RelatedDoc]
    var changesFromBefore: [ChangeFromBefore]
    /// The [S#] sources that were shown to the model (filled in by the app, not by the model).
    var sources: [ContextSource]

    init(title: String, overview: String, keyPoints: [SummaryItem] = [], decisions: [SummaryItem] = [],
         actionItems: [ActionItem] = [], openQuestions: [SummaryItem] = [],
         relatedDocs: [RelatedDoc] = [], changesFromBefore: [ChangeFromBefore] = [], sources: [ContextSource] = []) {
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.relatedDocs = relatedDocs
        self.changesFromBefore = changesFromBefore
        self.sources = sources
    }

    /// title and overview are required; missing lists just mean "nothing found".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        overview = try c.decode(String.self, forKey: .overview)
        keyPoints = try c.decodeIfPresent([SummaryItem].self, forKey: .keyPoints) ?? []
        decisions = try c.decodeIfPresent([SummaryItem].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        openQuestions = try c.decodeIfPresent([SummaryItem].self, forKey: .openQuestions) ?? []
        relatedDocs = try c.decodeIfPresent([RelatedDoc].self, forKey: .relatedDocs) ?? []
        changesFromBefore = try c.decodeIfPresent([ChangeFromBefore].self, forKey: .changesFromBefore) ?? []
        sources = try c.decodeIfPresent([ContextSource].self, forKey: .sources) ?? []
    }
}

/// Pass-1 notes for one ~10-minute part of a long meeting.
struct ChunkNotes: Codable, Equatable {
    var keyPoints: [SummaryItem]
    var decisions: [SummaryItem]
    var actionItems: [ActionItem]
    var openQuestions: [SummaryItem]

    init(keyPoints: [SummaryItem] = [], decisions: [SummaryItem] = [],
         actionItems: [ActionItem] = [], openQuestions: [SummaryItem] = []) {
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyPoints = try c.decodeIfPresent([SummaryItem].self, forKey: .keyPoints) ?? []
        decisions = try c.decodeIfPresent([SummaryItem].self, forKey: .decisions) ?? []
        actionItems = try c.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        openQuestions = try c.decodeIfPresent([SummaryItem].self, forKey: .openQuestions) ?? []
    }
}

struct SummaryItem: Codable, Equatable {
    var text: String
    var timestamp: String
    /// Optional project sources this point relates to, e.g. ["S2"].
    var sourceRefs: [String]?

    init(text: String, timestamp: String = "", sourceRefs: [String]? = nil) {
        self.text = text
        self.timestamp = timestamp
        self.sourceRefs = sourceRefs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        sourceRefs = try c.decodeIfPresent([String].self, forKey: .sourceRefs)
    }
}

/// A project document or past meeting related to this meeting.
struct RelatedDoc: Codable, Equatable {
    var source: String   // "S2"
    var path: String     // filled in by the app from the source list, never trusted from the model
    var reason: String

    init(source: String, path: String = "", reason: String) {
        self.source = source
        self.path = path
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// A decision in this meeting that differs from an earlier meeting or document.
struct ChangeFromBefore: Codable, Equatable {
    var text: String
    var previousSource: String // "S4"
    var timestamp: String

    init(text: String, previousSource: String, timestamp: String = "") {
        self.text = text
        self.previousSource = previousSource
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        previousSource = try c.decode(String.self, forKey: .previousSource)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
    }
}

/// One [S#] source shown to the model, saved in summary.json so links can be rebuilt later.
struct ContextSource: Codable, Equatable {
    var label: String      // "S1"
    var path: String       // relative to the project folder
    var location: String   // heading or time range
    var meetingDate: Date?
}

struct ActionItem: Codable, Equatable {
    static let unknown = "Chưa rõ"

    var task: String
    var owner: String
    var deadline: String
    var timestamp: String

    init(task: String, owner: String = unknown, deadline: String = unknown, timestamp: String = "") {
        self.task = task
        self.owner = owner
        self.deadline = deadline
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        task = try c.decode(String.self, forKey: .task)
        owner = Self.orUnknown(try c.decodeIfPresent(String.self, forKey: .owner))
        deadline = Self.orUnknown(try c.decodeIfPresent(String.self, forKey: .deadline))
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
    }

    private static func orUnknown(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? unknown : trimmed
    }
}

// MARK: - JSON Schemas (sent to Ollama's "format" field and shown in the prompt)

enum SummarySchema {
    private static let item: [String: Any] = [
        "type": "object",
        "properties": ["text": ["type": "string"], "timestamp": ["type": "string"]],
        "required": ["text", "timestamp"],
    ]
    private static let action: [String: Any] = [
        "type": "object",
        "properties": [
            "task": ["type": "string"], "owner": ["type": "string"],
            "deadline": ["type": "string"], "timestamp": ["type": "string"],
        ],
        "required": ["task", "owner", "deadline", "timestamp"],
    ]
    private static let lists: [String: Any] = [
        "keyPoints": ["type": "array", "items": item],
        "decisions": ["type": "array", "items": item],
        "actionItems": ["type": "array", "items": action],
        "openQuestions": ["type": "array", "items": item],
    ]

    /// Pass 1: notes for one part.
    static let notes: [String: Any] = [
        "type": "object",
        "properties": lists,
        "required": ["keyPoints", "decisions", "actionItems", "openQuestions"],
    ]

    /// Final summary with project context: adds relatedDocs, changesFromBefore and optional sourceRefs.
    static let summaryWithContext: [String: Any] = {
        let itemWithRefs: [String: Any] = [
            "type": "object",
            "properties": [
                "text": ["type": "string"], "timestamp": ["type": "string"],
                "sourceRefs": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["text", "timestamp"],
        ]
        var properties = lists
        properties["keyPoints"] = ["type": "array", "items": itemWithRefs]
        properties["decisions"] = ["type": "array", "items": itemWithRefs]
        properties["title"] = ["type": "string"]
        properties["overview"] = ["type": "string"]
        properties["relatedDocs"] = ["type": "array", "items": [
            "type": "object",
            "properties": ["source": ["type": "string"], "path": ["type": "string"], "reason": ["type": "string"]],
            "required": ["source", "path", "reason"],
        ] as [String: Any]]
        properties["changesFromBefore"] = ["type": "array", "items": [
            "type": "object",
            "properties": [
                "text": ["type": "string"], "previousSource": ["type": "string"], "timestamp": ["type": "string"],
            ],
            "required": ["text", "previousSource", "timestamp"],
        ] as [String: Any]]
        return [
            "type": "object",
            "properties": properties,
            "required": ["title", "overview", "keyPoints", "decisions", "actionItems", "openQuestions",
                         "relatedDocs", "changesFromBefore"],
        ]
    }()

    /// Final summary (pass 2, or the single pass for short meetings).
    static let summary: [String: Any] = [
        "type": "object",
        "properties": lists.merging(["title": ["type": "string"], "overview": ["type": "string"]]) { a, _ in a },
        "required": ["title", "overview", "keyPoints", "decisions", "actionItems", "openQuestions"],
    ]

    /// The schema as readable text for the prompt.
    static func text(_ schema: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses a model reply into `T`. Accepts stray text or ```json fences around the JSON.
    static func parse<T: Decodable>(_ type: T.Type, from reply: String) throws -> T {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw LLMError.invalidReply("no JSON object found")
        }
        let json = Data(reply[start...end].utf8)
        do {
            return try JSONDecoder().decode(T.self, from: json)
        } catch let DecodingError.keyNotFound(key, _) {
            throw LLMError.invalidReply("missing field \"\(key.stringValue)\"")
        } catch let DecodingError.typeMismatch(_, context) {
            throw LLMError.invalidReply("wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw LLMError.invalidReply("broken JSON")
        }
    }
}
