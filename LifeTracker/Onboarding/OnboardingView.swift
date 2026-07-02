import SwiftUI
import LifeTrackerCore

/// First-launch flow: what the app is, mic/speech permission priming, and the
/// Apple Intelligence status (with the manual fallback explained). Three pages,
/// skippable, shown once.
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0
    @State private var permissionsGranted: Bool?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(0)
                    permissions.tag(1)
                    intelligence.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    advance()
                } label: {
                    Text(buttonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var buttonTitle: String {
        switch page {
        case 0: return "Continue"
        case 1: return permissionsGranted == nil ? "Allow microphone & speech" : "Continue"
        default: return "Get started"
        }
    }

    private func advance() {
        switch page {
        case 0:
            withAnimation { page = 1 }
        case 1:
            if permissionsGranted == nil {
                Task {
                    permissionsGranted = await SpeechTranscriberService.requestPermissions()
                    withAnimation { page = 2 }
                }
            } else {
                withAnimation { page = 2 }
            }
        default:
            onDone()
        }
    }

    private var welcome: some View {
        OnboardPage(
            icon: "waveform",
            title: "Your day, spoken",
            lines: [
                "Press the Action Button, say what you're doing, and it lands on your timeline — structured, categorized, and timed.",
                "Everything stays on this device. No account, no cloud, no analytics.",
            ]
        )
    }

    private var permissions: some View {
        OnboardPage(
            icon: "mic.fill",
            title: "Microphone & speech",
            lines: [
                "Your voice is transcribed on-device by Apple's speech engine — audio never leaves the phone and isn't stored.",
                permissionsGranted == false
                    ? "Permission was declined — you can still type check-ins, or enable the mic later in Settings → Privacy."
                    : "The first recording may download the on-device speech model.",
            ]
        )
    }

    private var intelligence: some View {
        OnboardPage(
            icon: FoundationModelsParser.isAvailable ? "sparkles" : "keyboard",
            title: FoundationModelsParser.isAvailable ? "On-device intelligence is ready" : "Apple Intelligence is off",
            lines: [
                FoundationModelsParser.isAvailable
                    ? "Check-ins are parsed by the on-device model: it splits what you said into activities; precise timing is computed locally by the app."
                    : "Check-ins will be saved as text you can structure by hand. Enable Apple Intelligence in Settings to turn on automatic parsing.",
                "You can always fix anything with a tap — every check-in is undoable as a unit.",
            ]
        )
    }
}

private struct OnboardPage: View {
    let icon: String
    let title: String
    let lines: [String]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.15))
                    .frame(width: 120, height: 120)
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            VStack(spacing: 14) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 36)
    }
}
