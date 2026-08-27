// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import VoccaBootstrap
import VoccaCore
import VoccaInject
import XCTest

/// The `try-it-target` (A4) acceptance, driven headlessly: **TRY IT is a real dictation whose
/// transcript lands in the onboarding window's own field — only the delivery end swapped** (prd.md
/// M6). One ``DictationPipeline``, injector chosen once at root composition (ladder vs onboarding
/// sink), no caller branches anywhere.
///
/// Five promises are pinned here, each over the full shape it governs:
///
/// - **A completed session delivers into the sink** (prd.md M6): the pipeline transcribes the
///   outcome's audio with the shared ``StubEngine`` and the onboarding injector hands the
///   transcript to the sink — the field binding's seam (A5) — with a *delivered* record, never a
///   failsafe and never a silent idle.
/// - **A cancelled session delivers nothing** (the pipeline's own row,
///   `DictationPipeline.swift:338-341`): Esc during TRANSCRIBING — the route task is cancelled
///   mid-transcribe — ends `.idle`, finalizes `.aborted` and leaves the sink untouched.
/// - **Empty text never reaches the sink** (the pipeline's empty-skip row, held with the
///   onboarding injector): both shapes — the empty captured buffer (decided before transcribe)
///   and the engine's own empty answer — skip the injector entirely.
/// - **Delivery always resolves to the onboarding sink, regardless of the focused-app read**
///   (prd.md M6 — the ladder's allowlist is seeded with three apps, not Vocca, so the focused app
///   is deliberately irrelevant): the conformance carries no target of its own and makes no
///   system call; the text reaches the sink whatever `TargetContext` the pipeline passes.
/// - **A failed delivery is honest** (plan: "failsafe/reason vocabulary mapped honestly — do not
///   fabricate success"): a sink that refuses surfaces the pipeline's reason-only failure rather
///   than a fabricated delivered rung.
///
/// ## The composition and the zero-network probe
///
/// The injector is chosen once in `configure` from `CompletionFlagStore.isComplete()` — the pure
/// decision ``AppBootstrap/injectorComposition(completionFlag:)`` pinned below: complete ⇒ the
/// shipping ladder (today's behavior, byte for byte); incomplete ⇒ the onboarding sink.
///
/// The probe stays green by construction, and the two tests at the bottom pin the half that is
/// testable headlessly. `PROBE-CYCLE`'s post-condition is asserted by `ZeroNetworkTests` against
/// ``expectedCycleLifecycle`` (`rung=clipboardPaste`, `attempted=clipboardPaste` — the *real*
/// ladder delivered), and that report is produced by the probe's own cycle drive,
/// `Sources/VoccaNetworkProbe/DictationCycleDrive.swift:379-389`, which composes its **own**
/// ``LadderInjector`` over probe rung fakes — it never routes a session through `configure`'s
/// root (the probe holds that root only to read its activation policy for `PROBE-BOOTSTRAP`). So
/// whichever branch the flag selects in `configure`, the probe's `PROBE-CYCLE`/`PROBE-LATENCY`
/// strings are byte-identical — the drive is the injector's only exercised path in the probe,
/// and A4 does not touch it. What A4 pins instead is the composition decision itself: the one
/// branch (the two tests below), taken once at composition and never at session time.
final class OnboardingInjectorTests: XCTestCase {

    /// One onboarding pipeline over the shared stub: engine, the onboarding injector over a
    /// recording sink, and a ledger holder that never holds (the onboarding injector has no
    /// journal — the sink owns delivery, `OnboardingInjector.swift`'s documented divergence).
    /// The recorder is always a fresh ``LatencyLedger`` and the session id is minted from it —
    /// the `makeRecordedPipeline` shape (`DictationPipelineTests.swift:358-375`).
    private func makePipeline(
        engine: any ASREngine,
        sink: RecordingOnboardingSink,
        clock: TableClock? = nil
    ) -> (pipeline: DictationPipeline, holder: OnboardingLedgerHolder, ledger: LatencyLedger) {
        let holder = OnboardingLedgerHolder()
        let ledger = LatencyLedger()
        return (
            DictationPipeline(
                engine: engine,
                injector: OnboardingInjector(sink: sink),
                holder: holder,
                recorder: ledger,
                clock: clock),
            holder,
            ledger)
    }

    /// The focused context the route is given — any ordinary application, **not** Vocca itself:
    /// the ladder's allowlist is seeded with three apps, not Vocca (prd.md M6), and the
    /// onboarding injector must not care which app this is.
    private func target() -> TargetContext {
        TargetContext(
            bundleID: "com.example.WordProcessor", windowTitle: "Document 1", isSecureInput: false)
    }

    private func buffer(_ samples: [Float]) -> AudioBuffer {
        AudioBuffer(samples: samples, sampleRate: AudioBuffer.interchangeSampleRate)
    }

    private func outcome(_ reason: EndReason, _ samples: [Float]) -> SessionOutcome<AudioBuffer> {
        SessionOutcome.make(reason: reason, audio: buffer(samples))
    }

    /// Waits until a condition holds — the gate test's synchronisation, the
    /// `DictationPipelineTests.waitUntil` shape (2 s deadline, 1 ms sleep).
    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition did not hold within 2 seconds")
    }

    // MARK: - A completed session: the transcript reaches the sink

    /// The happy path, end to end (prd.md M6): the outcome's audio is transcribed exactly once
    /// and the transcript text is delivered into the sink — the seam A5's window field binds to.
    /// The record is a *delivered* one (a successful outcome under I1, `ARCHITECTURE.md:199`):
    /// never a failsafe hold, never a fabricated failure.
    func testACompletedSessionDeliversTheTranscriptToTheSink() async {
        let engine = StubEngine.parakeet()
        let sink = RecordingOnboardingSink()
        let clock = TableClock()
        let (pipeline, holder, ledger) = makePipeline(engine: engine, sink: sink, clock: clock)
        let sessionID = await ledger.beginSession()

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target(), sessionID: sessionID)

        XCTAssertEqual(
            surface, .idle,
            "a delivered transcript has nothing for the widget to present — the field already "
                + "shows it through the sink")
        let delivered = await sink.delivered
        XCTAssertEqual(
            delivered, ["1 2 3"],
            "the transcript text must reach the sink — the delivery end of TRY IT")
        let transcribeCalls = await engine.transcribeCalls
        XCTAssertEqual(transcribeCalls, 1)
        let records = await ledger.snapshot()
        XCTAssertEqual(
            records.first?.outcome, .delivered(rung: .clipboardPaste, verified: false),
            "the record is a delivered one — the vocabulary's delivery rung is the artifact the "
                + "conformance reports (`OnboardingInjector.swift` documents why), the outcome "
                + "class is the truth")
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0, "the onboarding injector holds nothing — the sink owns delivery")
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
    }

    // MARK: - Cancellation: nothing delivered, aborted

    /// Esc during TRANSCRIBING (`PRODUCT_SPEC.md:129` — the pipeline's own row, held with the
    /// onboarding injector): the route task is cancelled while the engine is parked inside
    /// `transcribe`, the gate opens, and the post-transcribe guard discards — `.idle`, the sink
    /// untouched, the record finalized `.aborted` with the engine that *was* asked attributed.
    func testACancelledSessionDuringTranscribingDeliversNothingAndFinalizesAborted() async {
        let clock = TableClock()
        let engine = GatedEngine(clock: clock)
        let sink = RecordingOnboardingSink()
        let (pipeline, holder, ledger) = makePipeline(engine: engine, sink: sink, clock: clock)
        let sessionID = await ledger.beginSession()
        let effect = SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3]))
        let target = target()

        let task = Task {
            await pipeline.route(effect, target: target, sessionID: sessionID)
        }
        await self.waitUntil { await engine.parkedTranscribes == 1 }
        task.cancel()
        await engine.openGate()
        let surface = await task.value

        XCTAssertEqual(
            surface, .idle,
            "a cancelled transcription is a discard, not a failure — nothing to present")
        let delivered = await sink.delivered
        XCTAssertEqual(
            delivered, [],
            "a cancelled session must never deliver — Esc is an instruction (`PRODUCT_SPEC.md:129`)")
        let records = await ledger.snapshot()
        XCTAssertEqual(records.count, 1, "exactly one record per route")
        XCTAssertEqual(
            records.first?.outcome, .aborted,
            "the cancelled route finalizes aborted — not delivered, not failed")
        XCTAssertEqual(
            records.first?.engine, engine.identity,
            "the engine was asked — the discard is the user's, not the engine's")
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 0, "the cancelled route never reads the holder")
    }

    // MARK: - Empty text: the sink is never asked

    /// The 20 ms press — a completed session that captured nothing — is decided empty *before*
    /// transcribe (the empty-buffer policy, `ASREngine.swift:28-32`): the engine is never asked,
    /// the injector never called, the sink never touched. The pipeline's empty-skip row holds
    /// with the onboarding injector exactly as it holds with the ladder.
    func testAnEmptyCapturedBufferSkipsTheInjectorAndTheSink() async {
        let engine = StubEngine.parakeet()
        let sink = RecordingOnboardingSink()
        let clock = TableClock()
        let (pipeline, holder, ledger) = makePipeline(engine: engine, sink: sink, clock: clock)
        let sessionID = await ledger.beginSession()

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [])),
            target: target(), sessionID: sessionID)

        XCTAssertEqual(surface, .idle)
        let transcribeCalls = await engine.transcribeCalls
        XCTAssertEqual(
            transcribeCalls, 0,
            "an empty captured buffer is decided empty without asking the engine")
        let delivered = await sink.delivered
        XCTAssertEqual(delivered, [], "no text was ever produced — the sink is never asked")
        let records = await ledger.snapshot()
        XCTAssertEqual(records.first?.outcome, .emptySkip)
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
    }

    /// The second empty shape: the engine answers an empty transcript for **non-empty** audio.
    /// Whatever an engine decided to call silence, `""` is never delivered — the sink stays
    /// untouched and the record is the empty-skip class.
    func testAnEmptyTranscriptTextSkipsTheInjectorAndTheSink() async {
        let engine = OnboardingScriptedEngine(text: "")
        let sink = RecordingOnboardingSink()
        let clock = TableClock()
        let (pipeline, holder, ledger) = makePipeline(engine: engine, sink: sink, clock: clock)
        let sessionID = await ledger.beginSession()

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target(), sessionID: sessionID)

        XCTAssertEqual(surface, .idle)
        let transcribeCalls = await engine.transcribeCalls
        XCTAssertEqual(
            transcribeCalls, 1,
            "the audio was transcribed — the emptiness is the engine's answer, not a skip")
        let delivered = await sink.delivered
        XCTAssertEqual(delivered, [], "the empty answer never reaches the sink")
        let records = await ledger.snapshot()
        XCTAssertEqual(records.first?.outcome, .emptySkip)
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
    }

    // MARK: - Resolution: the onboarding sink is the target, always

    /// The resolve row (prd.md M6, "no system calls, no decisions"): the onboarding injector
    /// carries no target of its own and reads no focused application — whatever ``TargetContext``
    /// the pipeline passes (a focused app, nothing focused, Secure Input in force), the text
    /// reaches the sink, and the answer is a delivery, never a rung-0 refusal. The context is
    /// deliberately varied across the closed refusals the ladder would have made: the onboarding
    /// path must not inherit any of them.
    func testDeliveryAlwaysResolvesToTheOnboardingSinkRegardlessOfTheFocusedApp() async {
        let sink = RecordingOnboardingSink()
        let injector = OnboardingInjector(sink: sink)

        let targets = [
            TargetContext(
                bundleID: "com.example.WordProcessor", windowTitle: "Document 1",
                isSecureInput: false),
            TargetContext(bundleID: nil, windowTitle: nil, isSecureInput: false),
            TargetContext(
                bundleID: "com.example.Bank", windowTitle: "Password", isSecureInput: true),
        ]
        for target in targets {
            let result = await injector.inject("hello", into: target)
            XCTAssertNotEqual(
                result.rung, .widgetFailsafe,
                "the sink accepted the text — a delivery rung, never the failsafe terminal")
        }

        let delivered = await sink.delivered
        XCTAssertEqual(
            delivered, ["hello", "hello", "hello"],
            "every context resolves to the same destination — the onboarding sink, regardless "
                + "of the focused-app read")
    }

    // MARK: - Failure: honest, never a fabricated success

    /// A sink that refuses delivery (the field binding is gone — the window closed mid-dictation,
    /// A5's failure row) must not report success: the injector answers the failsafe terminal, the
    /// pipeline reads a holder that holds nothing and surfaces the reason-only failure — the TRY
    /// IT failure the window folds (`OnboardingAction.tryItFailed`), never a delivered lie.
    func testAFailedSinkDeliverySurfacesAsAFailureAndNeverFabricatesSuccess() async {
        let engine = StubEngine.parakeet()
        let sink = RecordingOnboardingSink(failure: FakeSinkFailure.refused)
        let clock = TableClock()
        let (pipeline, holder, ledger) = makePipeline(engine: engine, sink: sink, clock: clock)
        let sessionID = await ledger.beginSession()

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target(), sessionID: sessionID)

        XCTAssertEqual(
            surface, .reasonOnly(.exhausted),
            "a refused delivery surfaces the pipeline's reason-only failure — a silent idle or a "
                + "fabricated delivered would lose the transcript and lie about it")
        let delivered = await sink.delivered
        XCTAssertEqual(delivered, [], "the sink refused — nothing was appended")
        let records = await ledger.snapshot()
        XCTAssertEqual(
            records.first?.outcome, .failed,
            "the refused delivery finalizes failed — never a delivered class")
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 1, "the failsafe path reads the holder exactly once")
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0, "the onboarding injector never holds — the sink owns delivery")
    }

    // MARK: - The composition decision (the only branch)

    /// **Complete ⇒ the ladder** — the composition decision's probe-relevant direction: a machine
    /// that finished onboarding composes today's injector, byte for byte (`ShippingLadder`). The
    /// probe's `PROBE-CYCLE` post-condition (`rung=clipboardPaste`, `ZeroNetworkTests`) is
    /// produced by the probe's own drive composing the ladder directly
    /// (`DictationCycleDrive.swift:379-389`) — the decision below cannot reach it — and this
    /// pin keeps the decision itself honest: the onboarding injector is never reachable when the
    /// flag is set, and the decision is the only branch (no caller checks state at session time).
    func testTheCompositionChoosesTheLadderWhenOnboardingIsComplete() {
        XCTAssertEqual(
            AppBootstrap.injectorComposition(completionFlag: true),
            .ladder,
            "onboarding complete ⇒ the shipping ladder — today's behavior, byte for byte")
    }

    /// **Incomplete ⇒ the onboarding sink** — TRY IT's dictation lands in the window's own field
    /// (prd.md M6) until a successful TRY IT sets the flag. The choice is made once, at
    /// composition, in `configure`; a flag set later (TRY IT success) changes nothing for the
    /// running process — the next launch composes the ladder (the resolve-once doctrine).
    func testTheCompositionChoosesTheOnboardingInjectorBeforeCompletion() {
        XCTAssertEqual(
            AppBootstrap.injectorComposition(completionFlag: false),
            .onboarding,
            "before completion the loop's injector is the onboarding sink — the delivery end "
                + "swapped, nothing else")
    }
}

// MARK: - The sink double

/// What a refused delivery is, for the honest-failure row. The specific error is the sink's
/// business — the injector must not stringify it.
private enum FakeSinkFailure: Error {
    case refused
}

/// **The sink, with a ledger** — every delivered transcript recorded in order, and an optional
/// scripted refusal. An actor, for the boundary reason ``LedgerTextInjector`` is one:
/// ``OnboardingTranscriptSink`` is a `Sendable` protocol, and the double must cross the boundary
/// honestly.
actor RecordingOnboardingSink: OnboardingTranscriptSink {
    private let failure: Error?
    private(set) var delivered: [String] = []

    init(failure: Error? = nil) {
        self.failure = failure
    }

    func deliver(_ transcript: String) async throws {
        if let failure { throw failure }
        delivered.append(transcript)
    }
}

// MARK: - The pipeline doubles

/// **The holder, with a ledger** — nothing ever held (the onboarding injector has no journal; the
/// sink owns delivery), every method's call count recorded so "never" is an assertion on a
/// counter. An actor, for the same boundary reason ``LedgerTranscriptHolder`` is one.
actor OnboardingLedgerHolder: TranscriptHolder {
    private(set) var holdCalls = 0
    private(set) var currentCalls = 0
    private(set) var releaseCalls = 0

    func hold(_ transcript: HeldTranscript) async throws {
        holdCalls += 1
    }

    func current() async -> HeldTranscript? {
        currentCalls += 1
        return nil
    }

    func release() async {
        releaseCalls += 1
    }
}

/// **An ASR engine the test scripts** — the empty-answer row, which ``StubEngine`` cannot produce
/// by construction (`ASRTestDoubles.swift:40-45`). An actor, for the boundary reason
/// ``StubEngine`` is one.
actor OnboardingScriptedEngine: ASREngine {
    let identity = EngineIdentity(id: "scripted-engine", displayName: "Scripted engine", isLocal: true)
    let supportsStreaming = false
    private let text: String
    private(set) var transcribeCalls = 0

    init(text: String) {
        self.text = text
    }

    func prepare() async throws {}

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeCalls += 1
        return Transcript(
            text: text, segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}

// MARK: - The cancellation gate's own doubles

/// **The gate test's hand-moved clock** — ``TableClock``'s role, `Sendable` because the pipeline
/// is a `Sendable` struct and ``MonotonicClock`` carries no `Sendable` requirement.
private final class TableClock: MonotonicClock, @unchecked Sendable {
    var now: Duration = .zero
}

/// **The cancellation row's engine** — the ``TableEngine`` shape
/// (`DictationPipelineTests.swift:1250-1301`): `transcribe` parks on a continuation until the
/// test opens it, so the route is *held mid-transcribe* and the cancellation lands
/// deterministically. The parked count and the stored gate sit next to each other with no
/// suspension between them, so observing `parkedTranscribes == 1` guarantees the gate is set.
private actor GatedEngine: ASREngine {
    let identity = EngineIdentity(id: "gated-engine", displayName: "Gated engine", isLocal: true)
    let supportsStreaming = false

    private let clock: TableClock
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var transcribeCalls = 0
    private(set) var parkedTranscribes = 0

    init(clock: TableClock) {
        self.clock = clock
    }

    func prepare() async throws {}

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeCalls += 1
        parkedTranscribes += 1
        await withCheckedContinuation { self.gate = $0 }
        clock.now += .milliseconds(5)
        return Transcript(
            text: "1 2 3", segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }

    func openGate() {
        gate?.resume()
        gate = nil
    }
}