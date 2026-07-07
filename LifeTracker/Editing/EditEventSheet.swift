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
    @State private var splitAt: Date
    @State private var prevNeighbor: Event?
    @State private var nextNeighbor: Event?

    init(event: Event, onSaved: @escaping () -> Void) {
        self.event = event
        self.onSaved = onSaved
        _title = State(initialValue: event.title ?? "")
        _categoryId = State(initialValue: event.categoryId)
        _hasStart = State(initialValue: event.startAt != nil)
        _hasEnd = State(initialValue: event.endAt != nil)
        _start = State(initialValue: Clock.date(fromMillis: event.startAt ?? Clock.nowMillis()))
        _end = State(initialValue: Clock.date(fromMillis: event.endAt ?? event.startAt ?? Clock.nowMillis()))
        // Split defaults to the block's midpoint.
        let mid = event.startAt.flatMap { s in event.endAt.map { e in (s + e) / 2 } }
        _splitAt = State(initialValue: Clock.date(fromMillis: mid ?? Clock.nowMillis()))
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
                        DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    }
                    Toggle("Set end", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
                    }
                }
                if isPlanned {
                    Section {
                        Button("Mark as done") { markDone() }
                    }
                }
                if event.startAt != nil && event.endAt != nil || prevNeighbor != nil || nextNeighbor != nil {
                    Section("Structure") {
                        if event.startAt != nil && event.endAt != nil {
                            DatePicker("Split at", selection: $splitAt, displayedComponents: .hourAndMinute)
                            Button("Split into two blocks") { splitEvent() }
                        }
                        if let prev = prevNeighbor {
                            Button {
                                mergeWith(prev)
                            } label: {
                                Label("Merge with “\(prev.title ?? "previous block")”", systemImage: "arrow.triangle.merge")
                            }
                        }
                        if let next = nextNeighbor {
                            Button {
                                mergeWith(next)
                            } label: {
                                Label("Merge with “\(next.title ?? "next block")”", systemImage: "arrow.triangle.merge")
                            }
                        }
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
            loadNeighbors()
        }
    }

    /// The blocks directly before/after this one on its day (merge candidates).
    private func loadNeighbors() {
        guard let startAt = event.startAt else { return }
        let day = LocalDay(containing: Clock.date(fromMillis: startAt), in: env.timeZone)
        let dayEvents = ((try? EventRepository(env.database.dbWriter).events(on: day, tz: env.timeZone)) ?? [])
        guard let idx = dayEvents.firstIndex(where: { $0.id == event.id }) else { return }
        prevNeighbor = idx > 0 ? dayEvents[idx - 1] : nil
        nextNeighbor = idx + 1 < dayEvents.count ? dayEvents[idx + 1] : nil
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
        // Giving a planned block times that already ended is backfilling reality —
        // confirm in the same save, no separate "mark as done" needed.
        if isPlanned, let s = startMs, let e = endMs, e > s, e <= now {
            try? service.confirm(eventId: event.id, now: now)
        }
        onSaved()
        dismiss()
    }

    private func markDone() {
        try? service.confirm(eventId: event.id, now: now)
        onSaved()
        dismiss()
    }

    private func splitEvent() {
        _ = try? service.split(eventId: event.id, at: Clock.millis(from: splitAt), now: now)
        onSaved()
        dismiss()
    }

    private func mergeWith(_ other: Event) {
        _ = try? service.merge(eventId: event.id, absorbing: other.id, now: now)
        onSaved()
        dismiss()
    }

    private func deleteEvent() {
        try? service.delete(eventId: event.id, now: now)
        onSaved()
        dismiss()
    }
}
