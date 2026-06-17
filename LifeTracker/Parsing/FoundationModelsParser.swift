import Foundation
import FoundationModels
import LifeTrackerCore

// On-device @Generable mirror of the Core ParsedCheckIn contract. The model
// returns STATED structure only (empty string = not stated); TimelineService
// resolves times and reconciles. Keeping fields non-optional keeps guided
// generation reliable.

@Generable
struct GenParsedCheckIn {
    @Guide(description: "Every activity mentioned, in spoken order.")
    let blocks: [GenBlock]
    @Guide(description: "Retroactive corrections: just woke up, since 2pm, skipped the run, actually class was 4 to 6.")
    let anchors: [GenAnchor]
}

@Generable
struct GenBlock {
    let title: String
    @Guide(description: "Best-matching existing category name, or a new short lowercase name if none fits.")
    let category: String
    @Guide(description: "One of: sleep, work, exercise, social, chore, leisure, transit, meal, other.")
    let categoryKind: String
    @Guide(description: "Stated start clock time exactly as said (e.g. 3:30pm or 15:30). Empty if not stated.")
    let statedStart: String
    @Guide(description: "Stated end clock time. Empty if not stated.")
    let statedEnd: String
    @Guide(description: "Stated duration if any (e.g. 2 hours, 45 minutes). Empty otherwise.")
    let statedDuration: String
    @Guide(description: "One of: completed, inProgress, planned.")
    let temporalState: String
    @Guide(description: "True only if the speaker just finished/closed the currently-open activity.")
    let closesOpenBlock: Bool
}

@Generable
struct GenAnchor {
    @Guide(description: "One of: wakeUp, backfillStart, skip, retime, setEnd.")
    let kind: String
    @Guide(description: "Name of the activity this refers to. Empty if none.")
    let targetHint: String
    @Guide(description: "New stated start clock time. Empty if none.")
    let newStart: String
    @Guide(description: "New stated end clock time. Empty if none.")
    let newEnd: String
    @Guide(description: "Relative reference like 'an hour ago' or 'since 2pm'. Empty if none.")
    let relativeReference: String
}

struct FoundationModelsParser: TranscriptParser {
    /// Whether the on-device model can be used right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func parse(transcript: String, now: Int64, timeZone: TimeZone, existingCategories: [String]) async throws -> ParsedCheckIn {
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(
            to: Self.prompt(transcript: transcript, now: now, timeZone: timeZone, categories: existingCategories),
            generating: GenParsedCheckIn.self
        )
        return Self.map(response.content)
    }

    private static let instructions = """
    You convert one short spoken check-in into structured activities. Extract only what is said: \
    the activities and their category, any clock times or durations actually stated, each activity's \
    temporal state, and retroactive corrections (anchors). Do not compute dates, invent times, or guess \
    durations. Leave a field as an empty string when it is not stated.
    """

    private static func prompt(transcript: String, now: Int64, timeZone: TimeZone, categories: [String]) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        let nowStr = f.string(from: Date(timeIntervalSince1970: Double(now) / 1000))
        let cats = categories.isEmpty ? "(none yet)" : categories.joined(separator: ", ")
        return """
        Current local time: \(nowStr) (\(timeZone.identifier)).
        Existing categories: \(cats).
        Check-in: "\(transcript)"
        """
    }

    private static func map(_ g: GenParsedCheckIn) -> ParsedCheckIn {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let blocks = g.blocks.map {
            ParsedBlock(
                title: $0.title, category: $0.category, categoryKind: $0.categoryKind,
                statedStart: clean($0.statedStart), statedEnd: clean($0.statedEnd),
                statedDuration: clean($0.statedDuration),
                temporalState: $0.temporalState, closesOpenBlock: $0.closesOpenBlock
            )
        }
        let anchors = g.anchors.map {
            ParsedAnchor(
                kind: $0.kind, targetHint: clean($0.targetHint),
                newStart: clean($0.newStart), newEnd: clean($0.newEnd),
                relativeReference: clean($0.relativeReference)
            )
        }
        return ParsedCheckIn(blocks: blocks, anchors: anchors)
    }
}
