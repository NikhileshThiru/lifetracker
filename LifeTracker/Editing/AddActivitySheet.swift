import SwiftUI
import LifeTrackerCore

/// Manual entry (also the AI-unavailable fallback). Routes through EditService.create.
struct AddActivitySheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let initialStart: Int64?
    let initialEnd: Int64?
    var onSaved: () -> Void

    enum StatusChoice: String, CaseIterable, Identifiable {
        case planned = "Planned", done = "Done", inProgress = "In progress"
        var id: String { rawValue }
    }

    @State private var title = ""
    @State private var categories: [LifeTrackerCore.Category] = []
    @State private var categoryId: String?
    @State private var status: StatusChoice = .planned
    @State private var hasStart = false
    @State private var hasEnd = false
    @State private var start = Date()
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What did you do?", text: $title)
                    Picker("Category", selection: $categoryId) {
                        ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section {
                    Picker("Status", selection: $status) {
                        ForEach(StatusChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Times") {
                    Toggle("Set start", isOn: $hasStart)
                    if hasStart {
                        DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                    }
                    if status != .inProgress {
                        Toggle("Set end", isOn: $hasEnd)
                        if hasEnd {
                            DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                        }
                    }
                }
            }
            .navigationTitle("Add activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(title.isEmpty || categoryId == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            categories = (try? CategoryRepository(env.database.dbWriter).live()) ?? []
            categoryId = categoryId ?? categories.first?.id
            if let s = initialStart { start = Clock.date(fromMillis: s); hasStart = true }
            if let e = initialEnd { end = Clock.date(fromMillis: e); hasEnd = true }
        }
    }

    private func save() {
        let mappedState: EventState = (status == .planned) ? .planned : .confirmed
        let startMs = hasStart ? Clock.millis(from: start) : nil
        let endMs = (hasEnd && status != .inProgress) ? Clock.millis(from: end) : nil
        _ = try? EditService(env.database.dbWriter).create(
            title: title, categoryId: categoryId, start: startMs, end: endMs,
            state: mappedState, now: env.currentTime()
        )
        onSaved()
        dismiss()
    }
}
