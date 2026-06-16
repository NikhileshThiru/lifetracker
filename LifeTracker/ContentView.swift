import SwiftUI
import LifeTrackerCore

/// Temporary smoke-test screen: proves the app links LifeTrackerCore, opens the
/// on-device DB, and reads the seeded categories. Real screens come in later steps.
struct ContentView: View {
    // Module-qualified: `Category` alone is ambiguous with the ObjC runtime typedef.
    @State private var categories: [LifeTrackerCore.Category] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView(
                        "Couldn’t open data",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else {
                    List(categories) { category in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: category.colorHex) ?? .gray)
                                .frame(width: 12, height: 12)
                            Text(category.name)
                            Spacer()
                            Text(category.kind)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Categories")
        }
        .preferredColorScheme(.dark)
        .task { await load() }
    }

    private func load() async {
        do {
            let db = try AppEnvironment.makeDatabase()
            categories = try CategoryRepository(db.dbWriter).live()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private extension Color {
    /// Parses a "#RRGGBB" hex string.
    init?(hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7,
              let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
