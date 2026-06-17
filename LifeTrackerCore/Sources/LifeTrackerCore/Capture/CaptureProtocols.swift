import Foundation

/// Turns a raw transcript into proposed structure. The on-device FoundationModels
/// implementation lives in the app; Core only knows this interface (swappable for
/// a cloud parser later). Stateless about the timeline — `TimelineService` reconciles.
public protocol TranscriptParser: Sendable {
    func parse(
        transcript: String,
        now: Int64,
        timeZone: TimeZone,
        existingCategories: [String]
    ) async throws -> ParsedCheckIn
}

/// Live speech-to-text. The SpeechAnalyzer implementation lives in the app
/// (it imports Speech/AVFAudio); Core only knows this interface.
public protocol Transcriber: Sendable {
    /// Ensures permissions + on-device assets are ready (may download).
    func prepare() async throws
    /// Starts mic transcription; `onUpdate` fires with (text, isFinal) as results arrive.
    func start(onUpdate: @escaping @Sendable (_ text: String, _ isFinal: Bool) -> Void) async throws
    /// Stops capture and returns the final transcript.
    func stop() async -> String
}
