import AppIntents

/// Action Button / Siri entry point. Uses `supportedModes = .foreground(.immediate)`
/// (NOT the deprecated `openAppWhenRun`) so it brings the app to the foreground
/// immediately and opens capture.
struct CaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Check-in"
    static let description = IntentDescription("Start a voice check-in.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    func perform() async throws -> some IntentResult {
        await MainActor.run { CaptureLauncher.shared.present = true }
        return .result()
    }
}

struct LifeTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureIntent(),
            phrases: [
                "Check in with \(.applicationName)",
                "Log a check-in in \(.applicationName)",
            ],
            shortTitle: "Check-in",
            systemImageName: "mic.fill"
        )
    }
}
