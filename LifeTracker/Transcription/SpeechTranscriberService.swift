import Foundation
import AVFoundation
import Speech
import LifeTrackerCore

enum TranscriberError: Error { case notAuthorized }

/// On-device live transcription via SpeechAnalyzer/SpeechTranscriber.
/// NOTE: this path only truly runs on a physical device — verify/tune on-device.
/// `@unchecked Sendable`: mutable state is touched from `start`/`stop` and the
/// audio tap thread; access is serialized by the capture flow's usage.
final class SpeechTranscriberService: Transcriber, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var finalText = ""

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    func prepare() async throws {
        guard await Self.requestPermissions() else { throw TranscriberError.notAuthorized }
        let t = makeTranscriber()
        transcriber = t
        // Download/ensure on-device assets for this locale (system may have evicted them).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await request.downloadAndInstall()
        }
    }

    func start(onUpdate: @escaping @Sendable (String, Bool) -> Void) async throws {
        finalText = ""
        let t = transcriber ?? makeTranscriber()
        transcriber = t

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [t])
        self.analyzer = analyzer
        let outFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in t.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        self.finalText += (self.finalText.isEmpty ? "" : " ") + piece
                        onUpdate(self.finalText, true)
                    } else {
                        let live = self.finalText.isEmpty ? piece : self.finalText + " " + piece
                        onUpdate(live, false)
                    }
                }
            } catch { /* surfaced to the user via the empty/failed path */ }
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let resolvedOut = outFormat ?? inputFormat
        let needsConvert = inputFormat.sampleRate != resolvedOut.sampleRate
            || inputFormat.channelCount != resolvedOut.channelCount
        converter = needsConvert ? AVAudioConverter(from: inputFormat, to: resolvedOut) : nil

        let cont = continuation
        let conv = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            Self.feed(buffer: buffer, converter: conv, outFormat: resolvedOut, into: cont)
        }

        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)
    }

    func stop() async -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return finalText
    }

    private static func feed(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        outFormat: AVAudioFormat,
        into cont: AsyncStream<AnalyzerInput>.Continuation
    ) {
        guard let converter else {
            cont.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var nsErr: NSError?
        converter.convert(to: out, error: &nsErr) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if nsErr == nil, out.frameLength > 0 {
            cont.yield(AnalyzerInput(buffer: out))
        }
    }
}
