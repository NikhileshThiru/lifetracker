import SwiftUI
import LifeTrackerCore

/// Check-ins that couldn't be auto-structured (AI off, or a parse failure).
/// The raw words are always kept; from here you can re-parse them (when the
/// model is available) or discard.
struct CheckInsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var items: [CheckIn] = []
    @State private var working = false

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "All caught up",
                    systemImage: "tray",
                    description: Text("Check-ins that couldn’t be auto-structured show up here.")
                )
            } else {
                List {
                    ForEach(items) { ci in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(ci.rawTranscript)
                                .foregroundStyle(Theme.textPrimary)
                            Text(statusLabel(ci.parseStatus))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                            HStack(spacing: 10) {
                                if FoundationModelsParser.isAvailable {
                                    Button("Re-parse") { reparse(ci) }
                                        .buttonStyle(.borderedProminent)
                                }
                                Button("Discard", role: .destructive) { discard(ci) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Theme.surface)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.bg)
        .navigationTitle("Unsorted")
        .disabled(working)
        .task { reload() }
    }

    private func reload() {
        items = (try? CheckInRepository(env.database.dbWriter).needingAttention()) ?? []
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case ParseStatus.failed.rawValue: return "Couldn’t auto-structure"
        case ParseStatus.manual.rawValue: return "Saved without AI"
        default: return "Pending"
        }
    }

    private func reparse(_ ci: CheckIn) {
        working = true
        Task {
            let parser: TranscriptParser? = FoundationModelsParser.isAvailable ? FoundationModelsParser() : nil
            _ = await CaptureService(dbWriter: env.database.dbWriter, parser: parser)
                .reparse(checkInId: ci.id, now: env.currentTime(), timeZone: env.timeZone)
            CaptureLauncher.shared.changeToken = UUID()
            working = false
            reload()
        }
    }

    private func discard(_ ci: CheckIn) {
        try? CheckInRepository(env.database.dbWriter).softDelete(id: ci.id)
        reload()
    }
}
