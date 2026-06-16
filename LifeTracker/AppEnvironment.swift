import Foundation
import LifeTrackerCore

enum AppEnvironment {
    /// The on-device database, created/opened in the app's Documents directory.
    static func makeDatabase() throws -> AppDatabase {
        let url = URL.documentsDirectory.appending(path: "lifetracker.sqlite")
        return try AppDatabase.make(atPath: url.path)
    }
}
