import Foundation
import Testing
import GRDB
@testable import LifeTrackerCore

struct EditServiceTests {
    private func fixture() throws -> (AppDatabase, EventRepository, EditService, Event) {
        let db = try AppDatabase.makeInMemory()
        let repo = EventRepository(db.dbWriter)
        let now: Int64 = 1_000_000
        let ev = Event(
            id: newID(), userId: "u1", categoryId: nil, title: "work", notes: nil,
            startAt: 9 * 3600_000, endAt: 10 * 3600_000, state: EventState.confirmed.rawValue,
            sequenceHint: nil, confidence: 1.0, source: EventSource.voice.rawValue, sourceRef: nil,
            originCheckInId: nil, isPinned: false, createdAt: now, updatedAt: now, deletedAt: nil
        )
        try repo.insert(ev)
        return (db, repo, EditService(db.dbWriter), ev)
    }

    private let H: Int64 = 3_600_000

    @Test func retimeChangesTimesAndUndoRestores() throws {
        let (_, repo, edit, ev) = try fixture()
        let batch = try #require(try edit.retime(eventId: ev.id, start: 11 * H, end: 12 * H))

        var fetched = try #require(try repo.find(id: ev.id))
        #expect(fetched.startAt == 11 * H)
        #expect(fetched.endAt == 12 * H)

        try edit.undo(batchId: batch)
        fetched = try #require(try repo.find(id: ev.id))
        #expect(fetched.startAt == 9 * H)   // restored
        #expect(fetched.endAt == 10 * H)
    }

    @Test func deleteSoftDeletesAndUndoRestores() throws {
        let (_, repo, edit, ev) = try fixture()
        let batch = try #require(try edit.delete(eventId: ev.id))
        #expect(try repo.find(id: ev.id)?.deletedAt != nil)

        try edit.undo(batchId: batch)
        #expect(try repo.find(id: ev.id)?.deletedAt == nil) // alive again
    }

    @Test func recategorizeAndConfirm() throws {
        let (_, repo, edit, ev) = try fixture()
        try edit.recategorize(eventId: ev.id, categoryId: "cat-123")
        #expect(try repo.find(id: ev.id)?.categoryId == "cat-123")

        // make it planned first, then confirm
        try edit.retime(eventId: ev.id, start: ev.startAt, end: ev.endAt) // no-op-ish, keeps it
        try edit.confirm(eventId: ev.id)
        #expect(try repo.find(id: ev.id)?.state == EventState.confirmed.rawValue)
    }

    @Test func mergeCategoryRepointsEventsAndArchivesSource() throws {
        let (db, repo, edit, ev) = try fixture()
        let cats = try CategoryRepository(db.dbWriter).live()
        let source = try #require(cats.first)
        let target = try #require(cats.dropFirst().first)
        try? edit.recategorize(eventId: ev.id, categoryId: source.id)

        let batch = try edit.mergeCategory(sourceId: source.id, into: target.id)

        let fetched = try #require(try repo.find(id: ev.id))
        #expect(fetched.categoryId == target.id)
        let live = try CategoryRepository(db.dbWriter).live()
        #expect(!live.contains { $0.id == source.id })   // archived out of pickers

        // Merge is one undoable batch.
        try edit.undo(batchId: batch)
        let restored = try #require(try repo.find(id: ev.id))
        #expect(restored.categoryId == source.id)
    }

    @Test func editingMissingEventReturnsNil() throws {
        let (_, _, edit, _) = try fixture()
        #expect(try edit.delete(eventId: "does-not-exist") == nil)
    }

    @Test func createInsertsEventWithExactTimes() throws {
        let (_, repo, edit, _) = try fixture()
        let made = try edit.create(
            title: "Pickleball", categoryId: "cat-x",
            start: 18 * H, end: 19 * H, state: .planned
        )
        let fetched = try #require(try repo.find(id: made.id))
        #expect(fetched.title == "Pickleball")
        #expect(fetched.startAt == 18 * H)
        #expect(fetched.source == EventSource.manual.rawValue)
        #expect(fetched.state == EventState.planned.rawValue)
    }
}
