import Foundation
import GRDB

/// Shared GRDB conformance: camelCase Swift properties map to snake_case columns.
public protocol LTRecord: Codable, FetchableRecord, PersistableRecord {}

public extension LTRecord {
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
}

public struct User: Identifiable, Equatable, LTRecord {
    public static let databaseTableName = "users"
    public var id: String
    public var displayName: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?
}

public struct Category: Identifiable, Equatable, LTRecord {
    public static let databaseTableName = "categories"
    public var id: String
    public var userId: String?
    public var parentId: String?
    public var name: String
    public var kind: String                 // CategoryKind raw value
    public var colorHex: String?
    public var icon: String?
    public var isDefault: Bool
    public var createdBy: String            // user|auto
    public var sortOrder: Int
    public var isArchived: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?
}

public struct CheckIn: Identifiable, Equatable, LTRecord {
    public static let databaseTableName = "check_ins"
    public var id: String
    public var userId: String?
    public var occurredAt: Int64
    public var timezone: String             // IANA id
    public var rawTranscript: String
    public var audioPath: String?
    public var sttEngine: String
    public var inputMethod: String          // InputMethod raw value
    public var parseStatus: String          // ParseStatus raw value
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?
}

public struct Event: Identifiable, Equatable, LTRecord {
    public static let databaseTableName = "events"
    public var id: String
    public var userId: String?
    public var categoryId: String?
    public var title: String?
    public var notes: String?
    public var startAt: Int64?              // NULL = loose placeholder
    public var endAt: Int64?               // NULL = open block
    public var state: String               // EventState raw value
    public var sequenceHint: Int?          // ordering for loose planned blocks
    public var confidence: Double
    public var source: String              // EventSource raw value
    public var sourceRef: String?          // external id for idempotent import
    public var originCheckInId: String?
    public var isPinned: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        id: String, userId: String?, categoryId: String?, title: String?, notes: String?,
        startAt: Int64?, endAt: Int64?, state: String, sequenceHint: Int?, confidence: Double,
        source: String, sourceRef: String?, originCheckInId: String?, isPinned: Bool,
        createdAt: Int64, updatedAt: Int64, deletedAt: Int64?
    ) {
        self.id = id
        self.userId = userId
        self.categoryId = categoryId
        self.title = title
        self.notes = notes
        self.startAt = startAt
        self.endAt = endAt
        self.state = state
        self.sequenceHint = sequenceHint
        self.confidence = confidence
        self.source = source
        self.sourceRef = sourceRef
        self.originCheckInId = originCheckInId
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct EventRevision: Identifiable, Equatable, LTRecord {
    public static let databaseTableName = "event_revisions"
    public var id: String
    public var eventId: String
    public var checkInId: String?
    public var batchId: String?            // groups one check-in's reconciliation (unit undo)
    public var changeKind: String          // ChangeKind raw value
    public var beforeJson: String?
    public var afterJson: String?
    public var createdAt: Int64
}

public struct ParseRun: Identifiable, Equatable, LTRecord {
    public static let databaseTableName = "parse_runs"
    public var id: String
    public var checkInId: String
    public var parser: String              // foundation_models|cloud_fallback|manual
    public var modelId: String?
    public var promptVersion: String?
    public var rawOutput: String?
    public var succeeded: Bool
    public var error: String?
    public var createdAt: Int64
}
