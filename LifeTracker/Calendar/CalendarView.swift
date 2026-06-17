import SwiftUI
import LifeTrackerCore

struct CalendarView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: MonthModel
    @State private var selected: LocalDay?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let weekdays = ["S", "M", "T", "W", "T", "F", "S"]

    init() {
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        _model = State(initialValue: MonthModel(year: comps.year ?? 2026, month: comps.month ?? 1))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(weekdays.indices, id: \.self) { i in
                        Text(weekdays[i])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(model.cells) { cell($0) }
                }
            }
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, 12)
        }
        .background(Theme.bg)
        .navigationTitle("Calendar")
        .navigationDestination(item: $selected) { day in
            TimelineContent(day: day, navTitle: nil).environment(env)
        }
        .task { model.load(database: env.database, tz: env.timeZone, now: env.currentTime()) }
    }

    private var header: some View {
        HStack {
            Button { model.shift(by: -1, database: env.database, tz: env.timeZone, now: env.currentTime()) } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(model.title).font(.headline).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { model.shift(by: 1, database: env.database, tz: env.timeZone, now: env.currentTime()) } label: {
                Image(systemName: "chevron.right")
            }
        }
        .foregroundStyle(Theme.textSecondary)
    }

    @ViewBuilder
    private func cell(_ c: MonthModel.DayCell) -> some View {
        if let n = c.dayNumber {
            VStack(spacing: 6) {
                Text("\(n)")
                    .font(.callout)
                    .fontWeight(c.isToday ? .bold : .regular)
                    .foregroundStyle(c.isToday ? Theme.textPrimary : Theme.textSecondary)
                Capsule()
                    .fill(Color.category(c.topColorHex))
                    .frame(width: 4 + 20 * fillFraction(c.trackedMinutes), height: 3)
                    .opacity(c.trackedMinutes > 0 ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(c.isToday ? Theme.surface : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { selected = c.day }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                c.trackedMinutes > 0
                    ? "Day \(n), \(TimeFormat.duration(Int64(c.trackedMinutes) * 60_000)) logged"
                    : "Day \(n)"
            )
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 46)
        }
    }

    private func fillFraction(_ minutes: Int) -> CGFloat {
        CGFloat(min(1.0, Double(minutes) / (16 * 60)))   // ~16 active hours = full bar
    }
}
