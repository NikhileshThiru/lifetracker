import Foundation
import Testing
@testable import LifeTrackerCore

struct CategoryNormalizerTests {
    @Test func collapsesTrivialVariants() {
        #expect(CategoryNormalizer.matches("Workout", "work out"))
        #expect(CategoryNormalizer.matches("workout", "workouts"))
        #expect(CategoryNormalizer.matches("Swimming!", "swimming"))
    }

    @Test func toleratesSingleTypoForLongerNames() {
        #expect(CategoryNormalizer.matches("swiming", "swimming"))   // 1 edit, long
        #expect(!CategoryNormalizer.matches("work", "walk"))         // short, distinct
        #expect(!CategoryNormalizer.matches("run", "fun"))
    }

    @Test func distinctActivitiesDoNotMatch() {
        #expect(!CategoryNormalizer.matches("reading", "running")) // 3 edits apart
    }

    @Test func resolverMapsToExistingDefault() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = CategoryRepository(db.dbWriter)
        let resolver = CategoryResolver(repo)
        let before = try repo.live().count

        // "Exercise" is a seeded default; the plural "Exercises" should map to it, not create.
        let hit = try resolver.resolve(name: "Exercises", kind: "exercise", userId: "u1")
        #expect(hit.name == "Exercise")
        #expect(try repo.live().count == before)
    }

    @Test func resolverCreatesNewAutoCategory() throws {
        let db = try AppDatabase.makeInMemory()
        let repo = CategoryRepository(db.dbWriter)
        let resolver = CategoryResolver(repo)
        let before = try repo.live().count

        let made = try resolver.resolve(name: "Pickleball", kind: "exercise", userId: "u1")
        #expect(made.createdBy == "auto")
        #expect(made.colorHex == CategoryPalette.color(for: .exercise))
        #expect(try repo.live().count == before + 1)

        // Saying it again maps to the same row (no fragmentation).
        let again = try resolver.resolve(name: "pickleball", kind: "exercise", userId: "u1")
        #expect(again.id == made.id)
        #expect(try repo.live().count == before + 1)
    }
}
