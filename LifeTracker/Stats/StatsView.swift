import SwiftUI
import LifeTrackerCore

struct StatsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = StatsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.streakDays > 0 {
                    Text("\(model.streakDays)-day logging streak")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.bottom, 4)
                }

                if model.rows.isEmpty {
                    Text("No tracked time this week yet.")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    Text("THIS WEEK")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(model.rows) { row in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.category(row.colorHex))
                                .frame(width: 10, height: 10)
                            Text(row.name)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(TimeFormat.duration(Int64(row.weekMinutes) * 60_000))
                                    .foregroundStyle(Theme.textPrimary)
                                    .monospacedDigit()
                                Text("\(TimeFormat.duration(Int64(row.todayMinutes) * 60_000)) today")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.hPadding)
            .padding(.vertical, 12)
        }
        .background(Theme.bg)
        .navigationTitle("Stats")
        .task { model.load(database: env.database, tz: env.timeZone, now: env.currentTime()) }
    }
}
