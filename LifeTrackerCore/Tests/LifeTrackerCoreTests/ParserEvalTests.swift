import Foundation
import Testing
@testable import LifeTrackerCore

struct ParserEvalTests {
    @Test func scoreMatchesIdenticalStructure() {
        let c = EvalCase("done, now dinner", blocks: 2, states: ["completed", "inProgress"])
        let parsed = ParsedCheckIn(blocks: [
            ParsedBlock(title: "x", category: "a", categoryKind: "work", temporalState: "inProgress"),
            ParsedBlock(title: "y", category: "b", categoryKind: "meal", temporalState: "completed"),
        ])
        let s = ParserEval.score(parsed, against: c)
        #expect(s.blockCount)
        #expect(s.states)       // order-independent
        #expect(s.anchors)      // both empty
    }

    @Test func scoreDetectsMismatch() {
        let c = EvalCase("skipped the run", blocks: 0, states: [], anchors: ["skip"])
        let wrong = ParsedCheckIn(blocks: [
            ParsedBlock(title: "run", category: "run", categoryKind: "exercise", temporalState: "planned")
        ])
        let s = ParserEval.score(wrong, against: c)
        #expect(!s.blockCount)  // expected 0, got 1
        #expect(!s.anchors)     // expected [skip], got []
    }

    @Test func runReportsZeroForEmptyParser() async {
        struct EmptyParser: TranscriptParser {
            func parse(transcript: String, now: Int64, timeZone: TimeZone, existingCategories: [String]) async throws -> ParsedCheckIn {
                ParsedCheckIn()
            }
        }
        let report = await ParserEval.run(EmptyParser(), now: 0, timeZone: TimeZone(identifier: "UTC")!)
        #expect(report.cases == ParserEval.corpus.count)
        // An empty parser only matches the cases that expect zero blocks and no anchors.
        #expect(report.blockCountMatches < report.cases)
    }
}
