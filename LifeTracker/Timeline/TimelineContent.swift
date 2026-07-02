import SwiftUI
import LifeTrackerCore

/// Renders one day's timeline (confirmed/planned/gaps) with add/edit/fill.
/// Reused for the Today tab and for any day drilled into from the calendar.
/// Expects to be embedded in a NavigationStack provided by its container.
struct TimelineContent: View {
    @Environment(AppEnvironment.self) private var env
    let day: LocalDay
    let navTitle: String?
    /// Today hosts add in the app's bottom bar; drilled-in days show a per-day add button.
    /// Voice check-in is always the global bottom-bar mic, so no per-view mic here.
    var showsAddButton: Bool = true

    @State private var model = TimelineModel()
    @State private var showAdd = false
    @State private var editingEvent: Event?
    @State private var fillGap: Gap?
    @State private var launcher = CaptureLauncher.shared

    var body: some View {
        ScrollView {
            if model.isEmpty {
                EmptyDayView().padding(.top, 100)
            } else {
                LazyVStack(spacing: Theme.rowSpacing) {
                    if let summary = model.summaryLine {
                        HStack {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                        .padding(.bottom, 2)
                    }
                    ForEach(model.items) { item in
                        TimelineRowView(item: item, tz: env.timeZone, onAdjust: adjust)
                            .contentShape(Rectangle())
                            .onTapGesture { tap(item) }
                    }
                    if !model.laterPlanned.isEmpty {
                        LaterSection(items: model.laterPlanned) { editingEvent = $0 }
                    }
                }
                .padding(.horizontal, Theme.hPadding)
                .padding(.vertical, 14)
            }
        }
        .background(Theme.bg)
        .navigationTitle(navTitle ?? model.title)
        .toolbar {
            if showsAddButton {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add activity")
                }
            }
        }
        .onChange(of: launcher.changeToken) { _, _ in reload() }
        .sheet(isPresented: $showAdd) {
            AddActivitySheet(initialStart: nil, initialEnd: nil) { reload() }.environment(env)
        }
        .sheet(item: $editingEvent) { event in
            EditEventSheet(event: event) { reload() }.environment(env)
        }
        .sheet(item: $fillGap) { gap in
            AddActivitySheet(initialStart: gap.startAt, initialEnd: gap.endAt) { reload() }.environment(env)
        }
        .task { reload(); autoPresentForScreenshots() }
    }

    private func tap(_ item: TimelineItem) {
        switch item {
        case .event(let layout): editingEvent = layout.event
        case .gap(let g): fillGap = g
        case .nowMarker: break
        }
    }

    private func reload() {
        model.load(database: env.database, day: day, now: env.currentTime(), tz: env.timeZone)
    }

    /// Commits a drag-edge retime (5-min-snapped in the row) as one revision.
    private func adjust(_ event: Event, newStart: Int64?, newEnd: Int64?) {
        _ = try? EditService(env.database.dbWriter).retime(
            eventId: event.id,
            start: newStart ?? event.startAt,
            end: newEnd ?? event.endAt,
            now: env.currentTime()
        )
        reload()
    }

    private func autoPresentForScreenshots() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-presentAdd") { showAdd = true }
        if args.contains("-presentEdit"),
           let first = model.items.first(where: { if case .event = $0 { return true } else { return false } }),
           case let .event(layout) = first {
            editingEvent = layout.event
        }
    }
}

struct EmptyDayView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.circle")
                .font(.system(size: 52))
                .foregroundStyle(Theme.textSecondary)
            Text("Nothing logged yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Tap the mic below — or press the Action Button — and say what you’re doing.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

struct LaterSection: View {
    let items: [(event: Event, category: LifeTrackerCore.Category?)]
    var onTap: (Event) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowSpacing) {
            Text("LATER")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)
            ForEach(items, id: \.event.id) { item in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.category(item.category?.colorHex))
                        .frame(width: 4)
                        .opacity(0.5)
                    Text(item.event.title ?? item.category?.name ?? "Untitled")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("planned")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onTap(item.event) }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.corner)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(Theme.hairline)
                }
            }
        }
    }
}
