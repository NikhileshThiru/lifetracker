import SwiftUI

@main
struct LifeTrackerApp: App {
    @State private var env = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .preferredColorScheme(.dark)
        }
    }
}
