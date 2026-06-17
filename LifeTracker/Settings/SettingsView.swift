import SwiftUI
import LifeTrackerCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @AppStorage("reminderEnabled") private var reminderEnabled = false
    @AppStorage("idleHours") private var idleHours = 4

    @State private var exportURL: URL?
    @State private var unsortedCount = 0

    var body: some View {
        Form {
            Section("Reminders") {
                Toggle("Nudge me when I go quiet", isOn: $reminderEnabled)
                if reminderEnabled {
                    Picker("After no check-ins for", selection: $idleHours) {
                        ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0) hours").tag($0) }
                    }
                    Text("A “what’s going on?” nudge if you go quiet. Never overnight.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Section("Backup") {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export backup", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Preparing backup…", systemImage: "square.and.arrow.up")
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Section {
                NavigationLink {
                    CheckInsView()
                } label: {
                    HStack {
                        Label("Unsorted check-ins", systemImage: "tray")
                        Spacer()
                        if unsortedCount > 0 {
                            Text("\(unsortedCount)").foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }

            Section {
                Text("All data stays on this device.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Settings")
        .onChange(of: reminderEnabled) { _, on in Task { await applyReminder(enabled: on) } }
        .onChange(of: idleHours) { _, _ in env.rescheduleIdleReminder() }
        .task {
            prepareExport()
            unsortedCount = (try? CheckInRepository(env.database.dbWriter).needingAttention().count) ?? 0
        }
    }

    private func applyReminder(enabled: Bool) async {
        if enabled {
            if await ReminderScheduler.requestAuthorization() {
                env.rescheduleIdleReminder()
            } else {
                reminderEnabled = false   // permission denied
            }
        } else {
            ReminderScheduler.cancel()
        }
    }

    private func prepareExport() {
        let url = FileManager.default.temporaryDirectory.appending(path: "lifetracker-backup.sqlite")
        try? FileManager.default.removeItem(at: url)
        do {
            try env.database.backup(to: url)
            exportURL = url
        } catch {
            exportURL = nil
        }
    }
}
