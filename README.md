# Life Tracker

A voice-first personal timeline app for iPhone. Press the Action Button, say what you're doing, and it transcribes and structures your day into a timeline — entirely on-device.

## What it does

- **Voice capture** via the Action Button → live on-device transcription → structured timeline.
- **Reconciliation**: multi-activity check-ins with planned vs. confirmed blocks, "done with X → now Y", retime, skip, backfill, and "just woke up" anchors.
- **Today timeline** with confirmed/planned blocks and tappable gaps; **ruthless editing** (recategorize, retime, fill-gap, delete) with undo.
- **Dynamic categories** created from speech, de-duplicated automatically.
- **Month calendar** with per-day fill, **Stats** (time per category, streaks), **reminders**, and **export/backup**.

## Architecture

Two layers:

- **`LifeTrackerCore`** — a platform-agnostic Swift package (Foundation + GRDB only). Holds the schema/migrations, repositories, and the deterministic engine: `TimelineService` (reconciliation), `EditService`, `GapCalculator`, `TimeResolver`, category normalization, and `CaptureService`. Fully unit-tested headlessly (`swift test`).
- **`LifeTracker`** — the SwiftUI iOS app. Adds the screens plus the on-device pipeline behind protocols defined in Core (`Transcriber`, `TranscriptParser`).

**The model proposes; deterministic code disposes.** The on-device language model only segments a sentence into activities, categories, and *stated* times. All clock math, block-matching, and database mutation happen in `TimelineService` — predictable and testable.

### On-device pipeline

```
Action Button → App Intent (supportedModes = .foreground(.immediate))
  → CaptureView (auto-records)
  → SpeechAnalyzer / SpeechTranscriber  (live transcript, on-device)
  → CaptureService: persist raw transcript (always)
  → FoundationModels @Generable parser → ParsedCheckIn  (on-device)
  → TimelineService.reconcile → GRDB (revisions for undo)
  → Today / Calendar / Stats
```

If Apple Intelligence is unavailable, capture + transcription still work and the check-in is saved for manual structuring — nothing core depends on the model succeeding.

## Privacy

Everything stays on the device. No backend, no accounts, no analytics. The raw transcript is stored (so a check-in can be re-parsed); raw audio is not. Export produces a single SQLite file you share yourself. The schema is sync-ready (UUIDs, tombstones) so optional cloud sync can be added later without a rewrite.

## Requirements

- iPhone 15 Pro or later (A17 Pro+) with **Apple Intelligence enabled**, iOS 26+.
- A Mac with **Xcode 26+**.

## Build & run

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`.

```sh
brew install xcodegen          # once
xcodegen generate              # creates LifeTracker.xcodeproj
open LifeTracker.xcodeproj      # then Run on your iPhone
```

Free signing: select your personal team in **Signing & Capabilities**. Free-provisioned apps expire after 7 days — reconnect and rebuild to refresh. The Action Button, microphone, and on-device model only work on a physical device (not the Simulator).

## Testing

- **Core logic** (headless): `cd LifeTrackerCore && swift test`.
- **UI / navigation**: iOS Simulator (`xcodebuild` + `xcrun simctl`). The app supports `-seedDemo` to populate a sample day.
- **Voice / parsing**: physical device only. Parser quality is measured with the labeled corpus in `ParserEval` (run it from an on-device test target against `FoundationModelsParser`).
