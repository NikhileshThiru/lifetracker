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
                Text("Starting…").foregroundStyle(Theme.textSecondary)
            }

        case .recording:
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.textPrimary)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                ScrollView {
                    Text(model.liveText.isEmpty ? "Listening…" : model.liveText)
                        .font(.title3)
                        .foregroundStyle(model.liveText.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                Spacer()
                Button { Task { await model.finishRecording(env: env) } } label: {
                    Text("Done").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { Task { await model.cancel(); dismiss() } }
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 40)

        case .processing:
            VStack(spacing: 14) {
                ProgressView().tint(Theme.textPrimary)
                Text("Working…").foregroundStyle(Theme.textSecondary)
            }

        case .finished:
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52)).foregroundStyle(.green)
                Text(model.resultMessage).foregroundStyle(Theme.textPrimary)
            }
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            }

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
}
