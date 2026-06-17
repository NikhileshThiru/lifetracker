import Foundation

/// A labeled parser test case: the transcript and the structure we expect.
/// We score structural fidelity (block count, temporal states, anchor kinds) —
/// not exact category names, which are dynamic/fuzzy.
public struct EvalCase: Sendable {
    public let transcript: String
    public let blockCount: Int
    public let temporalStates: [String]   // multiset, order-independent
    public let anchorKinds: [String]      // multiset, order-independent

    public init(_ transcript: String, blocks: Int, states: [String], anchors: [String] = []) {
        self.transcript = transcript
        self.blockCount = blocks
        self.temporalStates = states
        self.anchorKinds = anchors
    }
}

public struct EvalReport: Sendable {
    public let cases: Int
    public let blockCountMatches: Int
    public let stateMatches: Int
    public let anchorMatches: Int
    public let lines: [String]

    public var summary: String {
        "cases=\(cases) blockCount=\(blockCountMatches)/\(cases) states=\(stateMatches)/\(cases) anchors=\(anchorMatches)/\(cases)"
    }
}

/// On-device parser evaluation. The scoring is deterministic (headless-testable);
/// `run` drives a real `TranscriptParser` (Foundation Models on device) over the
/// corpus so prompt changes are measurable over time.
public enum ParserEval {
    public static let corpus: [EvalCase] = [
        EvalCase("Class from 3:30 to 5:30, then I'll go to the CRC to work out.",
                 blocks: 2, states: ["planned", "planned"]),
        EvalCase("Just finished class, ran late, ended at 5:50.",
                 blocks: 1, states: ["completed"]),
        EvalCase("Done with the workout, finished at 7, now starting dinner.",
                 blocks: 2, states: ["completed", "inProgress"]),
        EvalCase("Going to class, then run, then eat.",
                 blocks: 3, states: ["planned", "planned", "planned"]),
        EvalCase("Skipped the run.",
                 blocks: 0, states: [], anchors: ["skip"]),
        EvalCase("Just woke up.",
                 blocks: 0, states: [], anchors: ["wakeUp"]),
        EvalCase("Actually class was 4 to 6, not 3:30.",
                 blocks: 0, states: [], anchors: ["retime"]),
        EvalCase("Had breakfast at 8, then worked for three hours.",
                 blocks: 2, states: ["completed", "completed"]),
        EvalCase("I'll be in meetings all afternoon.",
                 blocks: 1, states: ["planned"]),
    ]

    public struct CaseScore: Sendable, Equatable {
        public let blockCount: Bool
        public let states: Bool
        public let anchors: Bool
    }

    public static func score(_ parsed: ParsedCheckIn, against c: EvalCase) -> CaseScore {
        CaseScore(
            blockCount: parsed.blocks.count == c.blockCount,
            states: parsed.blocks.map(\.temporalState).sorted() == c.temporalStates.sorted(),
            anchors: parsed.anchors.map(\.kind).sorted() == c.anchorKinds.sorted()
        )
    }

    public static func run(_ parser: any TranscriptParser, now: Int64, timeZone: TimeZone) async -> EvalReport {
        var blockOK = 0, stateOK = 0, anchorOK = 0
        var lines: [String] = []
        for c in corpus {
            do {
                let parsed = try await parser.parse(transcript: c.transcript, now: now, timeZone: timeZone, existingCategories: [])
                let s = score(parsed, against: c)
                if s.blockCount { blockOK += 1 }
                if s.states { stateOK += 1 }
                if s.anchors { anchorOK += 1 }
                lines.append("[\(s.blockCount ? "✓" : "✗")B \(s.states ? "✓" : "✗")S \(s.anchors ? "✓" : "✗")A] \(c.transcript)")
            } catch {
                lines.append("[ERROR] \(c.transcript): \(error)")
            }
        }
        return EvalReport(cases: corpus.count, blockCountMatches: blockOK, stateMatches: stateOK, anchorMatches: anchorOK, lines: lines)
    }
}
