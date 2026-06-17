import Foundation
import Observation
import LifeTrackerCore

@MainActor
@Observable
final class CaptureModel {
    enum Phase: Equatable {
        case preparing
        case recording
        case processing
        case finished
        case fallback(String)   // voice unavailable → typed entry
    }

    var phase: Phase = .preparing
    var liveText = ""
    var typedText = ""
    var resultMessage = ""

    private let transcriber = SpeechTranscriberService()

    func begin(env: AppEnvironment) async {
        do {
            try await transcriber.prepare()
            phase = .recording
            try await transcriber.start { [weak self] text, _ in
                Task { @MainActor in self?.liveText = text }
            }
        } catch {
            phase = .fallback("Voice capture isn’t available — type your check-in instead.")
        }
    }

    func finishRecording(env: AppEnvironment) async {
        guard phase == .recording else { return }
        phase = .processing
        let final = await transcriber.stop()
        let transcript = final.isEmpty ? liveText : final
        guard !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
            phase = .fallback("Didn’t catch that — type your check-in instead.")
            return
        }
        await ingest(transcript: transcript, method: .voice, engine: "speechanalyzer", env: env)
    }

    func submitTyped(env: AppEnvironment) async {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        phase = .processing
        await ingest(transcript: text, method: .typed, engine: "manual", env: env)
    }

    func cancel() async {
        _ = await transcriber.stop()
    }

    private func ingest(transcript: String, method: InputMethod, engine: String, env: AppEnvironment) async {
        let parser: TranscriptParser? = FoundationModelsParser.isAvailable ? FoundationModelsParser() : nil
        let service = CaptureService(dbWriter: env.database.dbWriter, parser: parser)
        let outcome = await service.ingest(
            transcript: transcript, inputMethod: method, sttEngine: engine,
            now: env.currentTime(), timeZone: env.timeZone
        )
        switch outcome {
        case .parsed: resultMessage = "Added to your timeline."
        case .manual: resultMessage = "Saved — structure it from the timeline."
        case .failedParse: resultMessage = "Saved your words — couldn’t auto-structure this one."
        }
        CaptureLauncher.shared.changeToken = UUID()
        env.rescheduleIdleReminder()
        phase = .finished
    }
}
