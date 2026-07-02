import Foundation
import AVFoundation
import Speech
import LifeTrackerCore

enum TranscriberError: Error {
    case notAuthorized
    case localeUnsupported
}

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
    private var interruptionObserver: (any NSObjectProtocol)?
    private var converter: AVAudioConverter?
    private var finalText = ""

    /// Optional live input-level callback (0…1), fired from the audio tap for the
    /// listening orb. Set before `start`. Called off the main thread.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Fired when the on-device speech assets need downloading (first run, or
    /// evicted under disk pressure), so the UI can say what the wait is.
    var onDownloadingAssets: (@Sendable () -> Void)?
    /// Fired if transcription dies mid-stream or the audio session is interrupted
    /// (phone call) — the capture flow should wrap up with the text so far.
    var onStopped: (@Sendable () -> Void)?

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    /// Picks a supported locale: the user's if the system supports it, else
    /// English, else fails (the capture flow falls back to typing).
    private func makeTranscriber() async throws -> SpeechTranscriber {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        let locale: Locale
        if supported.contains(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            locale = current
        } else if let sameLanguage = supported.first(where: { $0.language.languageCode == current.language.languageCode }) {
            locale = sameLanguage
        } else if let english = supported.first(where: { $0.language.languageCode == .english }) {
            locale = english
        } else {
            throw TranscriberError.localeUnsupported
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    func prepare() async throws {
        guard await Self.requestPermissions() else { throw TranscriberError.notAuthorized }
        let t = try await makeTranscriber()
        transcriber = t
        // Download/ensure on-device assets for this locale (system may have evicted them).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            onDownloadingAssets?()
            try await request.downloadAndInstall()
        }
    }

    func start(onUpdate: @escaping @Sendable (String, Bool) -> Void) async throws {
        finalText = ""
        let t: SpeechTranscriber
        if let existing = transcriber {
            t = existing
        } else {
            t = try await makeTranscriber()
            transcriber = t
        }

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
            } catch {
                // Mid-stream failure: hand the flow back with whatever was heard.
                self.onStopped?()
            }
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // A phone call (or Siri) taking the session should end the check-in
        // gracefully, not freeze the transcript.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: nil
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began { self?.onStopped?() }
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let resolvedOut = outFormat ?? inputFormat
        let needsConvert = inputFormat.sampleRate != resolvedOut.sampleRate
            || inputFormat.channelCount != resolvedOut.channelCount
        converter = needsConvert ? AVAudioConverter(from: inputFormat, to: resolvedOut) : nil

        let cont = continuation
        let conv = converter
        let levelCB = onLevel
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            if let levelCB { levelCB(Self.level(of: buffer)) }
            Self.feed(buffer: buffer, converter: conv, outFormat: resolvedOut, into: cont)
        }

        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)
    }

    func stop() async -> String {
        teardownAudio()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        deactivateSession()
        return finalText
    }

    /// Fast teardown for Cancel: no finalize pass, nothing returned.
    func cancelCapture() async {
        teardownAudio()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        deactivateSession()
    }

    private func teardownAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation?.finish()
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Normalized mic loudness (0…1) from a buffer's RMS, mapped from ~-50 dBFS…0 dBFS.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10f(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
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
