import Foundation
import Observation

/// Bridges the Action Button App Intent (and the in-app mic button) to the UI:
/// set `present = true` to show capture; bump `changeToken` to refresh the timeline.
@MainActor
@Observable
final class CaptureLauncher {
    static let shared = CaptureLauncher()
    var present = false
    var changeToken = UUID()

    private init() {}
}
