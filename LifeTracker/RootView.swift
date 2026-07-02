import SwiftUI
import LifeTrackerCore

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var launcher = CaptureLauncher.shared
    @AppStorage("onboarded") private var onboarded = false
    @State private var showOnboarding = false

    var body: some View {
        TabView(selection: $tab) {
            Tab("Today", systemImage: "list.bullet", value: 0) {
                NavigationStack {
                    TimelineContent(day: today, navTitle: "Today")
                        .environment(env)
                }
            }
            Tab("Calendar", systemImage: "calendar", value: 1) {
                NavigationStack { CalendarView().environment(env) }
            }
            Tab("Stats", systemImage: "chart.bar", value: 2) {
                NavigationStack { StatsView().environment(env) }
            }
            Tab("Settings", systemImage: "gearshape", value: 3) {
                NavigationStack { SettingsView().environment(env) }
            }
        }
        .tint(Theme.accent)
        .tabViewBottomAccessory {
            CheckInPill { launcher.present = true }
        }
        .fullScreenCover(isPresented: $launcher.present) {
            CaptureView().environment(env)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                onboarded = true
                showOnboarding = false
            }
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-showCalendar") { tab = 1 }
            if args.contains("-showStats") { tab = 2 }
            if args.contains("-showSettings") { tab = 3 }
            if args.contains("-showCapture") {
                // Presenting in the same tick as first render can be dropped.
                try? await Task.sleep(for: .milliseconds(400))
                launcher.present = true
            }
            // Demo/screenshot runs skip onboarding unless explicitly requested.
            if args.contains("-showOnboarding") {
                showOnboarding = true
            } else if !onboarded && !args.contains("-seedDemo") {
                showOnboarding = true
            }
            env.runMaintenance()
            env.rescheduleIdleReminder()
        }
        .onChange(of: scenePhase) { _, phase in
            // Daily rollover whenever the app returns to the foreground, so a
            // day boundary crossed while backgrounded is handled before use.
            if phase == .active {
                env.runMaintenance()
                launcher.changeToken = UUID()
            }
        }
    }

    private var today: LocalDay {
        LocalDay(containing: Clock.date(fromMillis: env.currentTime()), in: env.timeZone)
    }
}

/// The hero voice entry point: a persistent pill above the tab bar (the iOS 26
/// bottom-accessory slot), one tap from anywhere in the app.
private struct CheckInPill: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent, Theme.accent.opacity(0.78)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 30, height: 30)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("What are you doing?")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice check-in")
        .accessibilityHint("Records what you say and adds it to your timeline")
    }
}
