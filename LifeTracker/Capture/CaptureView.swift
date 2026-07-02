import SwiftUI
import LifeTrackerCore

struct CaptureView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model = CaptureModel()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            content
                .padding(.horizontal, 28)
        }
        .task { await model.begin(env: env) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .preparing:
            VStack(spacing: 14) {
                ProgressView().tint(Theme.textPrimary)
                Text(model.preparingMessage)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

        case .recording:
            VStack(spacing: 24) {
                Spacer()
                ListeningOrb(level: model.level)
                Text(elapsed)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                ScrollView {
                    Text(model.liveText.isEmpty ? "Listening…" : model.liveText)
                        .font(.title3)
                        .foregroundStyle(model.liveText.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 180)
                Spacer()
                Button { Task { await model.finishRecording(env: env) } } label: {
                    Text("Done").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                Button("Cancel") { Task { await model.cancel(); dismiss() } }
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 40)

        case .processing:
            VStack(spacing: 14) {
                ProgressView().tint(Theme.textPrimary)
                Text("Structuring…").foregroundStyle(Theme.textSecondary)
            }

        case .result:
            resultCard

        case .fallback(let message):
            VStack(spacing: 16) {
                Spacer()
                Text(message)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                TextField("Type your check-in", text: $model.typedText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3, reservesSpace: true)
                Button { Task { await model.submitTyped(env: env) } } label: {
                    Text("Save").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.typedText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { dismiss() }.foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.vertical, 40)
        }
    }

    /// What the check-in became: each block with its category color and resolved
    /// times, so a wrong parse is visible (and undoable) immediately.
    private var resultCard: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(model.resultMessage)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if !model.resultItems.isEmpty {
                VStack(spacing: 10) {
                    ForEach(model.resultItems) { item in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.category(item.colorHex))
                                .frame(width: 4, height: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Theme.textPrimary)
                                if !item.detail.isEmpty {
                                    Text(item.detail)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Spacer()
            HStack(spacing: 12) {
                if model.canUndo {
                    Button {
                        model.undo(env: env)
                        dismiss()
                    } label: {
                        Text("Undo").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.textSecondary)
                }
                Button { dismiss() } label: {
                    Text("Done").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(.vertical, 40)
        .task {
            // Auto-dismiss so the voice flow stays one-press; Undo/Done interrupt it.
            try? await Task.sleep(for: .seconds(5))
            dismiss()
        }
    }

    private var elapsed: String {
        String(format: "%d:%02d", model.recordingSeconds / 60, model.recordingSeconds % 60)
    }
}

/// The listening indicator: an accent orb that breathes on its own and swells with
/// your voice level. Purely decorative (VoiceOver reads the live transcript instead).
struct ListeningOrb: View {
    let level: Float
    @State private var breathe = false

    var body: some View {
        let l = CGFloat(max(0, min(1, level)))
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.10))
                .frame(width: 200, height: 200)
                .scaleEffect(1 + l * 0.6)
            Circle()
                .fill(Theme.accent.opacity(0.18))
                .frame(width: 150, height: 150)
                .scaleEffect(1 + l * 0.45)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.72)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 104, height: 104)
                .scaleEffect((breathe ? 1.05 : 0.97) * (1 + l * 0.35))
                .shadow(color: Theme.accent.opacity(0.5), radius: 24, y: 6)
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(height: 220)
        .animation(.easeOut(duration: 0.12), value: level)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityHidden(true)
    }
}
