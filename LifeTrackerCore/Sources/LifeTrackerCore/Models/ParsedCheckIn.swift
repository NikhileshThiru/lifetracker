import Foundation

/// Plain-Swift mirror of the on-device parser's `@Generable` output (the
/// `@Generable` types live in the app's Parsing module; this is what crosses
/// into Core so `TimelineService` has no FoundationModels dependency).
///
/// The model reports STRUCTURE and STATED times only — it never computes
/// absolute dates, picks DB rows, or applies changes (hybrid contract, spec §5).
public struct ParsedCheckIn: Codable, Sendable, Equatable {
    public var blocks: [ParsedBlock]
    public var anchors: [ParsedAnchor]

    public init(blocks: [ParsedBlock] = [], anchors: [ParsedAnchor] = []) {
        self.blocks = blocks
        self.anchors = anchors
    }
}

public struct ParsedBlock: Codable, Sendable, Equatable {
    public var title: String
    public var category: String          // best-matching existing name, or a new one
    public var categoryKind: String      // CategoryKind raw value
    public var statedStart: String?      // clock time as said, e.g. "15:30", "3:30pm"
    public var statedEnd: String?
    public var statedDuration: String?   // e.g. "2 hours", "45 minutes"
    public var temporalState: String     // TemporalState raw value
    public var closesOpenBlock: Bool

    public init(
        title: String, category: String, categoryKind: String,
        statedStart: String? = nil, statedEnd: String? = nil, statedDuration: String? = nil,
        temporalState: String, closesOpenBlock: Bool = false
    ) {
        self.title = title
        self.category = category
        self.categoryKind = categoryKind
        self.statedStart = statedStart
        self.statedEnd = statedEnd
        self.statedDuration = statedDuration
        self.temporalState = temporalState
        self.closesOpenBlock = closesOpenBlock
    }
}

public struct ParsedAnchor: Codable, Sendable, Equatable {
    public var kind: String              // AnchorKind raw value
    public var targetHint: String?       // name/title of the activity this refers to
    public var newStart: String?         // new stated start clock time
    public var newEnd: String?           // new stated end clock time
    public var relativeReference: String? // "an hour ago", "since 2pm"

    public init(
        kind: String, targetHint: String? = nil,
        newStart: String? = nil, newEnd: String? = nil, relativeReference: String? = nil
    ) {
        self.kind = kind
        self.targetHint = targetHint
        self.newStart = newStart
        self.newEnd = newEnd
        self.relativeReference = relativeReference
    }
}
