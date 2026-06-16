import SwiftUI
import LifeTrackerCore

/// Tap-to-edit an existing block. Routes through EditService (each change is a revision).
struct EditEventSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let event: Event
    var onSaved: () -> Void

    @State private var title: String
    @State private var categories: [LifeTrackerCore.Category] = []
    @State private var categoryId: String?
    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    @State private var start: Date
    @State private var end: Date

    init(event: Event, onSaved: @escaping () -> Void) {
        self.event = event
        self.onSaved = onSaved
        _title = State(initialValue: event.title ?? "")
        _categoryId = State(initialValue: event.categoryId)
        _hasStart = State(initialValue: event.startAt != nil)
        _hasEnd = State(initialValue: event.endAt != nil)
        _start = State(initialValue: Clock.date(fromMillis: event.startAt ?? Clock.nowMillis()))
        _end = State(initialValue: Clock.date(fromMillis: event.endAt ?? event.startAt ?? Clock.nowMillis()))
    }

    private var isPlanned: Bool { event.state == EventState.planned.rawValue }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    Picker("Category", selection: $categoryId) {
                        ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("Times") {
                    Toggle("Set start", isOn: $hasStart)
                    if hasStart {
                        DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                    }
                    Toggle("Set end", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                    }
                }
                if isPlanned {
                    Section {
                        Button("Mark as done") { markDone() }
                    }
                }
                Section {
                    Button("Delete", role: .destructive) { deleteEvent() }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            categories = (try? CategoryRepository(env.database.dbWriter).live()) ?? []
        }
    }

    private var service: EditService { EditService(env.database.dbWriter) }
    private var now: Int64 { env.currentTime() }

    private func save() {
        try? service.rename(eventId: event.id, title: title, now: now)
        if let cid = categoryId, cid != event.categoryId {
            try? service.recategorize(eventId: event.id, categoryId: cid, now: now)
        }
        let startMs = hasStart ? Clock.millis(from: start) : nil
        let endMs = hasEnd ? Clock.millis(from: end) : nil
        try? service.retime(eventId: event.id, start: startMs, end: endMs, now: now)
        onSaved()
        dismiss()
    }

    private func markDone() {
        try? service.confirm(eventId: event.id, now: now)
        onSaved()
        dismiss()
    }

    private func deleteEvent() {
        try? service.delete(eventId: event.id, now: now)
        onSaved()
        dismiss()
    }
}
