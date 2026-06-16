import SwiftUI
import LifeTrackerCore

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = TimelineModel()

    @State private var showAdd = false
    @State private var editingEvent: Event?
    @State private var fillGap: Gap?

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.isEmpty {
                    EmptyDayView().padding(.top, 100)
                } else {
                    LazyVStack(spacing: Theme.rowSpacing) {
                        ForEach(model.items) { item in
                            TimelineRowView(item: item, tz: env.timeZone)
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
            .navigationTitle(model.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddActivitySheet(initialStart: nil, initialEnd: nil) { reload() }
                .environment(env)
        }
        .sheet(item: $editingEvent) { event in
            EditEventSheet(event: event) { reload() }
                .environment(env)
        }
        .sheet(item: $fillGap) { gap in
            AddActivitySheet(initialStart: gap.startAt, initialEnd: gap.endAt) { reload() }
                .environment(env)
        }
        .task {
            reload()
            autoPresentForScreenshots()
        }
    }

    private func tap(_ item: TimelineItem) {
        switch item {
        case .event(let e, _): editingEvent = e
        case .gap(let g): fillGap = g
        }
    }

    private func reload() {
        model.load(database: env.database, now: env.currentTime(), tz: env.timeZone)
    }

    /// Dev hook: auto-open a sheet so it can be screenshotted headlessly.
    private func autoPresentForScreenshots() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-presentAdd") { showAdd = true }
        if args.contains("-presentEdit"),
           case let .event(e, _)? = model.items.first(where: { if case .event = $0 { return true } else { return false } }) {
            editingEvent = e
        }
    }
}

private struct EmptyDayView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.circle")
                .font(.system(size: 52))
                .foregroundStyle(Theme.textSecondary)
            Text("Nothing logged yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Press the Action Button and say what you’re doing.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

private struct LaterSection: View {
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
