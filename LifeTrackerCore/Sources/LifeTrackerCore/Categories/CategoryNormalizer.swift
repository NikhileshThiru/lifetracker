import Foundation

/// Deterministic de-duplication so auto-created categories don't fragment
/// ("workout" / "Work out" / "workouts" / "swiming"). This is a safety net for
/// trivial variants and typos — not a synonym engine. The parser is also fed the
/// existing category names so it usually reuses them outright.
public enum CategoryNormalizer {
    /// Canonical key: lowercased, punctuation/space-stripped, simple plural trimmed.
    public static func key(_ name: String) -> String {
        let lowered = name.lowercased()
        let alphanum = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        var key = String(String.UnicodeScalarView(alphanum))
        if key.count > 3, key.hasSuffix("s") {
            key.removeLast()
        }
        return key
    }

    /// True if two names should be treated as the same category. Exact key match,
    /// or a single-edit typo for longer names.
    public static func matches(_ a: String, _ b: String) -> Bool {
        let ka = key(a), kb = key(b)
        if ka.isEmpty || kb.isEmpty { return ka == kb }
        if ka == kb { return true }
        if min(ka.count, kb.count) >= 5, levenshtein(ka, kb) <= 1 { return true }
        return false
    }

    /// Looser matching for reconciling spoken titles against existing blocks
    /// ("the workout" ~ "gym workout"): `matches`, or one key containing the other.
    public static func titleMatches(_ a: String, _ b: String) -> Bool {
        if matches(a, b) { return true }
        let ka = key(a), kb = key(b)
        guard ka.count >= 3, kb.count >= 3 else { return false }
        return ka.contains(kb) || kb.contains(ka)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }
}

/// Cleans a spoken activity title the parser may have over-filled with clause
/// fragments — "work from 9 to 10" → "work", "now traveling" → "traveling".
/// Falls back (usually to the category name) when nothing meaningful remains.
public enum TitleSanitizer {
    private static let junk: Set<String> = [
        "now", "then", "later", "today", "tonight", "that", "this", "it", "stuff",
    ]
    private static let patterns = [
        // "from 9 to 10", "at 3pm", "until 5:30" — with an optional range tail.
        #"\b(?:from|at|until|till)\s+\d{1,2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?(?:\s*(?:to|until|till|-|–)\s*\d{1,2}(?::\d{2})?\s*(?:[ap]\.?m\.?)?)?"#,
        #"\bright now\b"#,
        #"^\s*now\b"#,
        #"\bnow\s*$"#,
    ]

    public static func clean(_ raw: String, fallback: String) -> String {
        var s = raw
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || junk.contains(s.lowercased()) { return fallback }
        return s
    }
}

/// Default look for an auto-created category, keyed by coarse kind.
public enum CategoryPalette {
    public static func color(for kind: CategoryKind) -> String {
        switch kind {
        case .sleep: return "#5E5CE6"
        case .work: return "#0A84FF"
        case .exercise: return "#30D158"
        case .social: return "#FF9F0A"
        case .chore: return "#8E8E93"
        case .leisure: return "#BF5AF2"
        case .transit: return "#64D2FF"
        case .meal: return "#FF6482"
        case .other: return "#98989D"
        }
    }

    public static func icon(for kind: CategoryKind) -> String {
        switch kind {
        case .sleep: return "bed.double.fill"
        case .work: return "laptopcomputer"
        case .exercise: return "figure.run"
        case .social: return "person.2.fill"
        case .chore: return "checklist"
        case .leisure: return "gamecontroller.fill"
        case .transit: return "car.fill"
        case .meal: return "fork.knife"
        case .other: return "circle.dashed"
        }
    }
}

/// Maps a spoken category to an existing one, or creates a new auto category.
public struct CategoryResolver {
    let repo: CategoryRepository
    public init(_ repo: CategoryRepository) { self.repo = repo }

    /// Returns the existing matching category, or inserts and returns a new one.
    public func resolve(
        name: String, kind: String, userId: String?, now: Int64 = Clock.nowMillis()
    ) throws -> Category {
        let existing = try repo.live()
        let kindEnum = CategoryKind.parse(kind)

        // Prefer a same-kind match, then any-kind match.
        let sameKind = existing.first { $0.kind == kindEnum.rawValue && CategoryNormalizer.matches($0.name, name) }
        let anyKind = existing.first { CategoryNormalizer.matches($0.name, name) }
        if let hit = sameKind ?? anyKind { return hit }

        let created = Category(
            id: newID(), userId: userId, parentId: nil,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kindEnum.rawValue,
            colorHex: CategoryPalette.color(for: kindEnum),
            icon: CategoryPalette.icon(for: kindEnum),
            isDefault: false, createdBy: "auto",
            sortOrder: (existing.map(\.sortOrder).max() ?? 0) + 1,
            isArchived: false, createdAt: now, updatedAt: now, deletedAt: nil
        )
        try repo.insert(created)
        return created
    }
}
