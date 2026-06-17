import SwiftUI
import LifeTrackerCore

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var tab = 0
    @State private var launcher = CaptureLauncher.shared

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

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(3)
        }
        .fullScreenCover(isPresented: $launcher.present) {
            CaptureView().environment(env)
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-showCalendar") { tab = 1 }
            if args.contains("-showStats") { tab = 2 }
            if args.contains("-showSettings") { tab = 3 }
            if args.contains("-showCapture") { launcher.present = true }
            env.rescheduleIdleReminder()
        }
    }

    private var today: LocalDay {
        LocalDay(containing: Clock.date(fromMillis: env.currentTime()), in: env.timeZone)
    }
}
