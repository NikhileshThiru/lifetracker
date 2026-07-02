import SwiftUI
import UniformTypeIdentifiers
import LifeTrackerCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    @AppStorage("reminderEnabled") private var reminderEnabled = false
    @AppStorage("idleHours") private var idleHours = 4

    @State private var exportURL: URL?
    @State private var unsortedCount = 0

    @State private var showRestorePicker = false
    @State private var pendingRestore: URL?      // copied to temp, awaiting confirmation
    @State private var showRestoreConfirm = false
    @State private var restoreMessage: String?

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

            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Export backup", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Preparing backup…", systemImage: "square.and.arrow.up")
                        .foregroundStyle(Theme.textSecondary)
                }
                Button {
                    showRestorePicker = true
                } label: {
                    Label("Restore backup", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Export saves a full copy you can keep in Files or AirDrop to your Mac. Restore replaces everything currently in the app with a chosen backup.")
                    .font(.footnote)
            }

            Section {
                NavigationLink {
                    CategoryManagerView()
                } label: {
                    Label("Categories", systemImage: "tag")
                }
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
        .fileImporter(
            isPresented: $showRestorePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in handlePicked(result) }
        .confirmationDialog(
            "Replace all current data with this backup?",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible,
            presenting: pendingRestore
        ) { url in
            Button("Replace everything", role: .destructive) { performRestore(url) }
            Button("Cancel", role: .cancel) { cleanupPending() }
        } message: { _ in
            Text("This can’t be undone. Consider exporting a backup first.")
        }
        .alert("Restore", isPresented: Binding(
            get: { restoreMessage != nil },
            set: { if !$0 { restoreMessage = nil } }
        )) {
            Button("OK", role: .cancel) { restoreMessage = nil }
        } message: {
            Text(restoreMessage ?? "")
        }
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

    /// Copy the picked file into our sandbox (it may be security-scoped), then ask to confirm
    /// before overwriting anything.
    private func handlePicked(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let picked = urls.first else { return }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        let temp = FileManager.default.temporaryDirectory.appending(path: "restore-source.sqlite")
        try? FileManager.default.removeItem(at: temp)
        do {
            try FileManager.default.copyItem(at: picked, to: temp)
            pendingRestore = temp
            showRestoreConfirm = true
        } catch {
            restoreMessage = "Couldn’t read that file."
        }
    }

    private func performRestore(_ url: URL) {
        do {
            try env.database.restore(from: url)
            CaptureLauncher.shared.changeToken = UUID()   // refresh Today/Calendar/Stats
            prepareExport()                               // export now reflects restored data
            unsortedCount = (try? CheckInRepository(env.database.dbWriter).needingAttention().count) ?? 0
            env.rescheduleIdleReminder()
            restoreMessage = "Backup restored."
        } catch AppDatabase.RestoreError.notALifeTrackerBackup {
            restoreMessage = "That doesn’t look like a Life Tracker backup."
        } catch {
            restoreMessage = "Couldn’t restore that backup."
        }
        cleanupPending()
    }

    private func cleanupPending() {
        if let url = pendingRestore { try? FileManager.default.removeItem(at: url) }
        pendingRestore = nil
    }
}
