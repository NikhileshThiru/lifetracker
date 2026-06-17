import SwiftUI
import LifeTrackerCore

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                TimelineContent(day: today, navTitle: "Today")
            }
            .tabItem { Label("Today", systemImage: "list.bullet") }
            .tag(0)

            NavigationStack {
                CalendarView()
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(1)

            NavigationStack {
                StatsView()
            }
            .tabItem { Label("Stats", systemImage: "chart.bar") }
            .tag(2)
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-showCalendar") { tab = 1 }
            if args.contains("-showStats") { tab = 2 }
        }
    }

    private var today: LocalDay {
        LocalDay(containing: Clock.date(fromMillis: env.currentTime()), in: env.timeZone)
    }
}
