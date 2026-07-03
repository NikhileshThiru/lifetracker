import Foundation
import FoundationModels
import LifeTrackerCore

// On-device @Generable mirror of the Core ParsedCheckIn contract. The model
// returns STATED structure only (empty string = not stated); TimelineService
// resolves times and reconciles.
//
// Reliability levers for the small on-device model:
// - enums (not free strings) for every closed set, so guided generation can't
//   emit "Done"/"Finished" where the code expects "completed"
// - few-shot examples in the instructions (segmentation of multi-activity
//   speech is what the model gets wrong most)
// - greedy sampling so the same sentence always parses the same way

@Generable
enum GenTemporalState: String {
    case completed, inProgress, planned
}

@Generable
enum GenCategoryKind: String {
    case sleep, work, exercise, social, chore, leisure, transit, meal, other
}

@Generable
enum GenAnchorKind: String {
    case wakeUp, backfillStart, skip, retime, setEnd
}

@Generable
struct GenParsedCheckIn {
    @Guide(description: "Every distinct activity mentioned, in spoken order. Split on connectives like 'then', 'and then', 'after that'.")
    let blocks: [GenBlock]
    @Guide(description: "Corrections about existing/past activities only: just woke up, been going since 2pm, skipped the run, actually class was 4 to 6.")
    let anchors: [GenAnchor]
}

@Generable
struct GenBlock {
    @Guide(description: "Activity NAME only, 1-3 words (work, gym, dinner). Never include times or words like now/from/until.")
    let title: String
    @Guide(description: "Best-matching existing category name, or a new short lowercase name if none fits.")
    let category: String
    let categoryKind: GenCategoryKind
    @Guide(description: "Start clock time exactly as spoken (e.g. 3:30pm, 15:30, 8). Empty if not spoken.")
    let statedStart: String
    @Guide(description: "End clock time exactly as spoken, or the word now for 'until now'. Empty if not spoken.")
    let statedEnd: String
    @Guide(description: "Duration exactly as spoken (e.g. 2 hours, 45 minutes). Empty if not spoken.")
    let statedDuration: String
    @Guide(description: "completed = already happened (past tense). inProgress = happening right now. planned = will happen later.")
    let temporalState: GenTemporalState
    @Guide(description: "True only if the speaker says they just finished the activity they had been doing.")
    let closesOpenBlock: Bool
}

@Generable
struct GenAnchor {
    let kind: GenAnchorKind
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
    /// Bump when instructions/prompt change so parse_runs stay comparable.
    static let promptVersion = "v4"
    /// Existing category names injected into the prompt are capped to protect
    /// the model's fixed ~4096-token context window.
    private static let maxInjectedCategories = 40

    /// Whether the on-device model can be used right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var promptVersion: String { Self.promptVersion }

    func parse(transcript: String, now: Int64, timeZone: TimeZone, existingCategories: [String]) async throws -> ParsedCheckIn {
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(
            to: Self.prompt(transcript: transcript, now: now, timeZone: timeZone, categories: existingCategories),
            generating: GenParsedCheckIn.self,
            options: GenerationOptions(sampling: .greedy)
        )
        return Self.map(response.content)
    }

    private static let instructions = """
    You convert one short spoken check-in into structured activities. The text comes from \
    speech recognition and may lack punctuation. Extract only what is said: every distinct \
    activity (split on connectives like "then", "and then", "after that"), its category, any \
    clock times or durations actually stated, and its temporal state — past tense means \
    completed, happening right now means inProgress, future means planned. Corrections about \
    existing activities (waking up, backfilled starts, skips, retimes) are anchors, not blocks. \
    Never compute dates, invent times, or guess durations; leave unstated fields empty.

    Examples:

    "Class from 3:30 to 5:30 then I'll go to the gym"
    → blocks: class (planned, start 3:30, end 5:30), gym (planned, no times); anchors: none

    "Had breakfast at 8 then worked out then showered"
    → blocks: breakfast (completed, start 8), workout (completed), shower (completed); anchors: none

    "Done with the workout finished at 7 now starting dinner"
    → blocks: workout (completed, end 7, closesOpenBlock true), dinner (inProgress); anchors: none

    "Just finished showering put my laundry in and now I'm doing work"
    → blocks: shower (completed, closesOpenBlock true), laundry (completed), work (inProgress); anchors: none

    "Slept at 3 woke up at 9 did work until now and now I'm driving to the airport"
    → blocks: sleep (completed, start 3, end 9), work (completed, start 9, end now), \
    commute (inProgress); anchors: none

    "Worked from 9 to 10 and now I'm traveling"
    → blocks: work (completed, start 9, end 10), travel (inProgress); anchors: none. \
    Titles are the bare activity name: "work", never "work from 9 to 10"; "travel", never "now traveling".

    "Just woke up"
    → blocks: none; anchors: wakeUp

    "Actually class was 4 to 6 not 3:30"
    → blocks: none; anchors: retime (target class, newStart 4, newEnd 6)

    "Skipped the run"
    → blocks: none; anchors: skip (target run)

    "Been reading since 2pm"
    → blocks: reading (inProgress, start 2pm); anchors: none
    """

    private static func prompt(transcript: String, now: Int64, timeZone: TimeZone, categories: [String]) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        let nowStr = f.string(from: Date(timeIntervalSince1970: Double(now) / 1000))
        let capped = categories.prefix(maxInjectedCategories)
        let cats = capped.isEmpty ? "(none yet)" : capped.joined(separator: ", ")
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
        let blocks = g.blocks.map { (b: GenBlock) -> ParsedBlock in
            // Deterministic cleanup of model over-fills: "work from 9 to 10" →
            // "work"; "now traveling" → "traveling"; pure filler → category name.
            let category = TitleSanitizer.clean(b.category, fallback: b.categoryKind.rawValue)
            return ParsedBlock(
                title: TitleSanitizer.clean(b.title, fallback: category),
                category: category, categoryKind: b.categoryKind.rawValue,
                statedStart: clean(b.statedStart), statedEnd: clean(b.statedEnd),
                statedDuration: clean(b.statedDuration),
                temporalState: b.temporalState.rawValue, closesOpenBlock: b.closesOpenBlock
            )
        }
        let anchors = g.anchors.map {
            ParsedAnchor(
                kind: $0.kind.rawValue, targetHint: clean($0.targetHint),
                newStart: clean($0.newStart), newEnd: clean($0.newEnd),
                relativeReference: clean($0.relativeReference)
            )
        }
        return ParsedCheckIn(blocks: blocks, anchors: anchors)
    }
}
