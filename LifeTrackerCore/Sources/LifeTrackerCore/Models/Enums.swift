import Foundation

/// Coarse activity bucket used for priors/grouping. The specific category name is freeform.
public enum CategoryKind: String, CaseIterable, Codable, Sendable {
    case sleep, work, exercise, social, chore, leisure, transit, meal, other

    /// Maps any raw string to a known kind, defaulting to `.other` (parser robustness).
    public static func parse(_ raw: String) -> CategoryKind {
        CategoryKind(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) ?? .other
    }
}

/// Stored event state. Gaps are computed, never stored (see spec §5).
public enum EventState: String, Codable, Sendable {
    case planned    // proposal: future, or loose placeholder (may have NULL start)
    case confirmed  // actually happened (open block = confirmed with NULL end)
}

public enum EventSource: String, Codable, Sendable {
    case voice, manual, healthkit, inferred
}

/// Per-activity temporal state the parser reports (not stored directly).
public enum TemporalState: String, Codable, Sendable {
    case completed, inProgress, planned
}

public enum ChangeKind: String, Codable, Sendable {
    case create, retime, recategorize, merge, split, confirm, delete, edit, skip, backfill
}

public enum InputMethod: String, Codable, Sendable {
    case voice, typed
}

public enum ParseStatus: String, Codable, Sendable {
    case pending, parsed, failed
    case reparseNeeded = "reparse_needed"
    case manual
}

/// Retroactive-correction kinds the parser can emit.
public enum AnchorKind: String, Codable, Sendable {
    case wakeUp, backfillStart, skip, retime, setEnd
}
