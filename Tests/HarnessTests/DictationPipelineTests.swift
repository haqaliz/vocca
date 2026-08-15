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

import VoccaCore
import XCTest

/// The `loop-wiring` Task 1 decision table: what an ended session's ``SessionOutcome`` does to
/// the engine, the injector and the holder.
///
/// Four promises are pinned here, each over the full shape it governs:
///
/// - **A cancelled session is an instruction, not an accident** (PRD R3,
///   `PRODUCT_SPEC.md:129`): no transcribe, no inject, no holder touch — even when the
///   cancelled outcome was carrying audio, which is the case that distinguishes "the user asked
///   to abandon it" from "the pipeline forgot".
/// - **Empty text never reaches the injector** (PRD R3 — "no paste of `""`"): both shapes that
///   yield empty text — an empty captured buffer (the 20 ms press, skipped *before* transcribe)
///   and an engine that answers an empty transcript for non-empty audio (skipped *after*) —
///   end `.idle` with the injector untouched.
/// - **Every delivery rung is a success under I1** (`ARCHITECTURE.md:199`): the three delivery
///   rungs end `.idle` and never touch the holder; `.widgetFailsafe` — the *successful* outcome
///   where the ladder's handoff already holds — surfaces the held transcript after reading the
///   holder exactly once, and never holds or releases.
/// - **A transcribe failure is a reason-only notice** (PRD R5): `.reasonOnly(.transcriptionFailed)`
///   with nothing injected and nothing held — "Nothing was lost — you can try again."
///
/// The engine double is the shared ``StubEngine`` where the transcription is a pure function of
/// the samples (its transcription is the ground truth the expected strings are written by hand
/// against, `ASRTestDoubles.swift:40-45`); the throw shape and the empty-transcript shape need a
/// scripted engine, because ``StubEngine`` cannot fail by construction. The injector and the
/// holder are ledger actors written below — every call recorded, so "never" is an assertion on
/// a counter rather than an absence the test cannot see.
final class DictationPipelineTests: XCTestCase {

    /// One pipeline over the shared stub: engine, ledger injector and ledger holder, with the
    /// holder preloaded with the transcript the ladder's handoff would have held.
    ///
    /// The holder is preloaded because production composition routes the failsafe hold through
    /// the ladder's own handoff (`JournalTranscriptHolder` as `FailsafeHandoff`,
    /// `prd.md:80-84`) *before* the pipeline sees the `.widgetFailsafe` result — "the holder
    /// already holds" is the contract this table is written against. The pipeline's half of the
    /// contract is to surface what the handoff held, not to hold it again.
    private func makePipeline(
        engine: any ASREngine,
        injectorResult: InjectionResult,
        held: HeldTranscript? = nil
    ) -> (pipeline: DictationPipeline, injector: LedgerTextInjector, holder: LedgerTranscriptHolder) {
        let injector = LedgerTextInjector(result: injectorResult)
        let holder = LedgerTranscriptHolder(held: held)
        return (
            DictationPipeline(engine: engine, injector: injector, holder: holder),
            injector,
            holder)
    }

    /// The focused context the route is given — the root's key-down resolution (S1), handed to
    /// the pipeline at key-up.
    private func target() -> TargetContext {
        TargetContext(
            bundleID: "com.example.Notes", windowTitle: "Notes - The Draft", isSecureInput: false)
    }

    private func buffer(_ samples: [Float]) -> AudioBuffer {
        AudioBuffer(samples: samples, sampleRate: AudioBuffer.interchangeSampleRate)
    }

    private func outcome(_ reason: EndReason, _ samples: [Float]) -> SessionOutcome<AudioBuffer> {
        SessionOutcome.make(reason: reason, audio: buffer(samples))
    }

    // MARK: - Cancellation: an instruction, never an accident

    /// A cancelled session discards **even when it carries audio** — the case that proves the
    /// discard is the user's instruction and not the pipeline mistaking silence for nothing. No
    /// transcribe, no inject, no holder touch.
    func testCancelledContentIsDiscardedWithoutTranscribeInjectOrHold() async {
        let engine = StubEngine.parakeet()
        let (pipeline, injector, holder) = makePipeline(
            engine: engine,
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))
        let cancelled = outcome(.userCancelled, [1, 2, 3])

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(cancelled), target: target())

        XCTAssertEqual(surface, .idle)
        let transcribeCalls = await engine.transcribeCalls
        XCTAssertEqual(transcribeCalls, 0)
        let calls = await injector.calls
        XCTAssertEqual(calls, [])
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
        let releaseCalls = await holder.releaseCalls
        XCTAssertEqual(releaseCalls, 0)
    }

    // MARK: - Empty text: no paste of ""

    /// A completed session that captured nothing — the 20 ms press — is decided *before*
    /// transcribe: the empty buffer is the empty text (the empty-buffer policy,
    /// `ASREngine.swift:28-32`), so the engine is never asked, the injector never called and
    /// the holder never touched. Straight back to `.idle`.
    func testCompletedWithEmptySamplesSkipsTranscribeInjectAndHold() async {
        let engine = StubEngine.parakeet()
        let (pipeline, injector, holder) = makePipeline(
            engine: engine,
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [])), target: target())

        XCTAssertEqual(surface, .idle)
        let transcribeCalls = await engine.transcribeCalls
        XCTAssertEqual(
            transcribeCalls, 0,
            "an empty captured buffer is decided empty without asking the engine")
        let calls = await injector.calls
        XCTAssertEqual(calls, [])
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
    }

    /// The second empty shape: the engine answers an empty transcript for **non-empty** audio.
    /// Whatever an engine decides to call silence, `""` must not be pasted — the injector and
    /// the holder stay untouched and the surface is `.idle`.
    func testEmptyTranscriptTextNeverReachesTheInjector() async {
        let engine = ScriptedEngine(text: "")
        let (pipeline, injector, holder) = makePipeline(
            engine: engine,
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target())

        XCTAssertEqual(surface, .idle)
        let transcribeCalls = await engine.transcribeCalls
        XCTAssertEqual(
            transcribeCalls, 1,
            "the audio was transcribed — the emptiness is the engine's answer, not a skip")
        let calls = await injector.calls
        XCTAssertEqual(calls, [])
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
    }

    // MARK: - The dictation path: transcribe once, inject once

    /// The happy path, end to end: the outcome's audio is transcribed exactly once, and the
    /// transcript text is injected exactly once **into the same context the root resolved at
    /// key-down** (S1 — "inject into that same context at key-up"). A delivery rung ends
    /// `.idle` with the holder untouched.
    func testCompletedWithTextTranscribesOnceAndInjectsIntoTheGivenTarget() async {
        let engine = StubEngine.parakeet()
        let (pipeline, injector, holder) = makePipeline(
            engine: engine,
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))
        let target = target()

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])), target: target)

        XCTAssertEqual(surface, .idle)
        let transcribeCalls = await engine.transcribeCalls
        XCTAssertEqual(transcribeCalls, 1)
        let calls = await injector.calls
        XCTAssertEqual(
            calls, [InjectionCall(text: "1 2 3", target: target)],
            "the transcript text must reach the injector, into the resolved context")
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
        let releaseCalls = await holder.releaseCalls
        XCTAssertEqual(releaseCalls, 0)
    }

    /// Every delivery rung is a *successful* outcome under I1 — accessibility, clipboard-paste
    /// and keystroke all end `.idle` and never touch the holder. The closed set keeps the table
    /// growing with the enum.
    func testEveryDeliveryRungEndsIdleAndNeverTouchesTheHolder() async {
        for rung in InjectionRung.allCases where rung != .widgetFailsafe {
            let (pipeline, injector, holder) = makePipeline(
                engine: StubEngine.parakeet(),
                injectorResult: InjectionResult(
                    rung: rung, attempted: [rung], verified: false, elapsed: .zero))

            let surface = await pipeline.route(
                SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1])),
                target: target())

            XCTAssertEqual(
                surface, .idle,
                "\(rung) delivered the text — the surface is idle, not a reason and not a hold")
            let calls = await injector.calls
            XCTAssertEqual(calls.count, 1)
            let holdCalls = await holder.holdCalls
            XCTAssertEqual(holdCalls, 0)
            let currentCalls = await holder.currentCalls
            XCTAssertEqual(currentCalls, 0)
            let releaseCalls = await holder.releaseCalls
            XCTAssertEqual(releaseCalls, 0)
        }
    }

    // MARK: - The failsafe: surface what the handoff held, exactly once

    /// `.widgetFailsafe` is the outcome where the ladder's handoff already holds the transcript
    /// durably (the journal write is part of the hand-off, `FailsafeHandoff.swift:26-34`). The
    /// pipeline's half is to read the holder **exactly once** and surface the held transcript —
    /// never hold again, never release.
    func testWidgetFailsafeSurfacesTheHeldTranscriptAndReadsTheHolderExactlyOnce() async {
        let held = HeldTranscript(
            text: "1 2 3", reason: .exhausted, targetAppName: "Notes",
            capturedAt: .seconds(7))
        let (pipeline, injector, holder) = makePipeline(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .widgetFailsafe, attempted: [.accessibility, .clipboardPaste],
                verified: false, elapsed: .zero),
            held: held)

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target())

        XCTAssertEqual(surface, .transcriptHeld(held),
            "the failsafe surface is the transcript the handoff held, verbatim")
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 1,
            "the holder is read exactly once on the failsafe path — to surface what it holds")
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0,
            "the holder already holds — the pipeline must not hold a second time")
        let releaseCalls = await holder.releaseCalls
        XCTAssertEqual(releaseCalls, 0)
        let calls = await injector.calls
        XCTAssertEqual(calls.count, 1)
    }

    /// The residual no test can reach through the real injector: a `.widgetFailsafe` result
    /// with **nothing** held — the journal refused custody (the one branch `LadderInjector`
    /// catches and reports as the failsafe outcome). The pipeline cannot fabricate a
    /// ``HeldTranscript`` the handoff never produced, so it surfaces the exhaustion reason
    /// rather than pretending the text is somewhere it is not.
    func testAWidgetFailsafeWithNothingHeldSurfacesTheExhaustedReason() async {
        let (pipeline, injector, holder) = makePipeline(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .widgetFailsafe, attempted: [.accessibility], verified: false,
                elapsed: .zero))

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target())

        XCTAssertEqual(surface, .reasonOnly(.exhausted),
            "a failsafe that holds nothing must still surface — a silent idle would lose the transcript")
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 1)
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let calls = await injector.calls
        XCTAssertEqual(calls.count, 1,
            "the ladder ran — the exhaustion is the failsafe's, not a skipped injection")
    }

    // MARK: - Failure: a reason-only notice, nothing held

    /// `transcribe` throwing surfaces `.reasonOnly(.transcriptionFailed)` (PRD R5): the injector
    /// is never called, the holder is never touched, and the transcript is neither injected nor
    /// lost — it simply never existed.
    func testATranscribeFailureSurfacesTranscriptionFailedAndInjectsNothing() async {
        let (pipeline, injector, holder) = makePipeline(
            engine: ScriptedEngine(error: FakeTranscriptionError.boom),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target())

        XCTAssertEqual(surface, .reasonOnly(.transcriptionFailed))
        let calls = await injector.calls
        XCTAssertEqual(calls, [])
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
        let releaseCalls = await holder.releaseCalls
        XCTAssertEqual(releaseCalls, 0)
    }

    // MARK: - Non-ended effects: nothing to route

    /// The four non-ended effects are not a dictation surface — the widget's projection reads
    /// them, the pipeline does not. Each routes to `.idle` touching nothing: the engine is not
    /// transcribed, the injector not called, the holder not read.
    func testNonEndedEffectsRouteToIdleAndTouchNothing() async {
        let effects: [SessionEffect<AudioBuffer>] = [
            .unchanged,
            .started,
            .opening,
            .captureUnavailable,
        ]
        for effect in effects {
            let engine = StubEngine.parakeet()
            let (pipeline, injector, holder) = makePipeline(
                engine: engine,
                injectorResult: InjectionResult(
                    rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                    elapsed: .zero))

            let surface = await pipeline.route(effect, target: target())

            XCTAssertEqual(surface, .idle, "\(effect) is not an ended session — nothing to route")
            let transcribeCalls = await engine.transcribeCalls
            XCTAssertEqual(transcribeCalls, 0)
            let calls = await injector.calls
            XCTAssertEqual(calls, [])
            let currentCalls = await holder.currentCalls
            XCTAssertEqual(currentCalls, 0)
            let holdCalls = await holder.holdCalls
            XCTAssertEqual(holdCalls, 0)
        }
    }

    // MARK: - W1: every route finalizes exactly one record (loop-wiring Phase 1)

    /// A route with the recorder, the clock and a minted ``SessionRecord/ID`` — the W1 shape —
    /// runs the session end to end and hands the ledger back, for the table test below.
    private func makeRecordedPipeline(
        engine: any ASREngine,
        clock: TableClock,
        injectorResult: InjectionResult,
        held: HeldTranscript? = nil
    ) async -> (
        pipeline: DictationPipeline, ledger: LatencyLedger, sessionID: SessionRecord.ID
    ) {
        let ledger = LatencyLedger()
        let sessionID = await ledger.beginSession()
        let pipeline = DictationPipeline(
            engine: engine,
            injector: LedgerTextInjector(result: injectorResult),
            holder: LedgerTranscriptHolder(held: held),
            recorder: ledger,
            clock: clock)
        return (pipeline, ledger, sessionID)
    }

    /// The cleanup contract's builder — ``makeRecordedPipeline`` plus the `cleanup:` argument.
    ///
    /// The recorder is always a fresh ``LatencyLedger`` (the shape `makeRecordedPipeline` sets);
    /// a test that wants the record mints a session id from the returned ledger and passes it to
    /// the route. `clock` is optional because the B1/B5 rows exercise the no-clock path — no
    /// measurement, no budget race, direct call (`plan §6`). Synchronous because nothing here
    /// awaits — the ledger minting is the test's call, not the builder's.
    private func makeCleanupPipeline(
        engine: any ASREngine,
        injectorResult: InjectionResult,
        held: HeldTranscript? = nil,
        cleanup: (any CleanupProvider)? = nil,
        clock: TableClock? = nil
    ) -> (
        pipeline: DictationPipeline, injector: LedgerTextInjector, holder: LedgerTranscriptHolder,
        ledger: LatencyLedger
    ) {
        let ledger = LatencyLedger()
        let injector = LedgerTextInjector(result: injectorResult)
        let holder = LedgerTranscriptHolder(held: held)
        let pipeline = DictationPipeline(
            engine: engine,
            injector: injector,
            holder: holder,
            recorder: ledger,
            clock: clock,
            cleanup: cleanup)
        return (pipeline, injector, holder, ledger)
    }

    /// Routes one ended outcome through a recorded pipeline and collects the ledger's answer.
    ///
    /// The engine's own `identity` comes back with the record, so the table can assert
    /// attribution against the engine that was actually asked — never a value the test invented.
    private func runRecordedRoute(
        _ outcome: SessionOutcome<AudioBuffer>,
        engine: any ASREngine,
        clock: TableClock,
        injectorResult: InjectionResult,
        held: HeldTranscript? = nil
    ) async -> (
        surface: PipelineSurface, records: [SessionRecord], sessionID: SessionRecord.ID,
        engineIdentity: EngineIdentity
    ) {
        let (pipeline, ledger, sessionID) = await makeRecordedPipeline(
            engine: engine, clock: clock, injectorResult: injectorResult, held: held)
        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome), target: target(), sessionID: sessionID)
        let records = await ledger.snapshot()
        return (surface, records, sessionID, engine.identity)
    }

    /// Waits until a condition holds — the gate test's synchronisation, the
    /// `DictationEngineResolverTests.waitUntil` shape (2 s deadline, 1 ms sleep).
    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition did not hold within 2 seconds")
    }

    /// The W1 closed-set finalize table (spec W1): **every** row of the pipeline's decision
    /// table — the guards at `DictationPipeline.swift:139,147,160,165,174,180,184,195-198,201` —
    /// driven over a real `LatencyLedger`, a hand-moved clock and the ledger-minted
    /// ``SessionRecord/ID``. Each row yields exactly one record, class per the table, spans
    /// `asr` then `inject` in order, `cleanup` never recorded, engine = the fake engine's
    /// identity on every row that reached transcribe (nil on the three that never did),
    /// delivered rows carrying the rung + verified off the ``InjectionResult``.
    func testEveryRowOfTheDecisionTableFinalizesExactlyOneRecord() async {
        let asrAdvance = Duration.milliseconds(5)
        let injectElapsed = Duration.milliseconds(3)
        let standardResult = InjectionResult(
            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
            elapsed: injectElapsed)

        let cases: [(
            name: String,
            outcome: SessionOutcomeClass,
            surface: PipelineSurface,
            spanNames: [SpanName],
            engineAttributed: Bool,
            run: () async -> (
                surface: PipelineSurface, records: [SessionRecord], sessionID: SessionRecord.ID,
                engineIdentity: EngineIdentity
            )
        )] = [
            // Row 1: a cancelled outcome is an instruction — nothing was asked of anyone.
            ("cancelled outcome", .aborted, .idle, [], false, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock)
                return await self.runRecordedRoute(
                    self.outcome(.userCancelled, [1, 2, 3]), engine: engine, clock: clock,
                    injectorResult: standardResult)
            }),
            // Row 2: the empty captured buffer is decided empty *before* transcribe.
            ("completed with empty captured buffer", .emptySkip, .idle, [], false, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock)
                return await self.runRecordedRoute(
                    self.outcome(.retained(.keyUp), []), engine: engine, clock: clock,
                    injectorResult: standardResult)
            }),
            // Row 3: cancelled *before* the engine was asked (Esc during TRANSCRIBING) — the
            // cancellation is delivered before the route body can start, so the guard at
            // `DictationPipeline.swift:160` fires with nothing asked of the engine. The
            // cancellation-before-start race is resolved in practice by the absence of a
            // suspension between `Task {}` and `cancel()`; if it ever lost, the assertions
            // below fail loudly (a transcribe would have happened) rather than pass falsely.
            ("cancelled before transcribe", .aborted, .idle, [], false, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock)
                let (pipeline, ledger, sessionID) = await self.makeRecordedPipeline(
                    engine: engine, clock: clock, injectorResult: standardResult)
                let effect = SessionEffect<AudioBuffer>.ended(
                    self.outcome(.retained(.keyUp), [1, 2, 3]))
                let target = self.target()
                let task = Task {
                    await pipeline.route(effect, target: target, sessionID: sessionID)
                }
                task.cancel()
                let surface = await task.value
                let records = await ledger.snapshot()
                return (surface, records, sessionID, engine.identity)
            }),
            // Row 4: `transcribe` throws — the ASR span is still measured and recorded (the
            // transcribe consumed the time), and the failure is attributed to the engine that
            // failed (`EngineIdentity`: "which engine produced a transcript *or failed to*").
            ("transcribe throws", .failed, .reasonOnly(.transcriptionFailed), [.asr], true, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock, error: FakeTranscriptionError.boom)
                return await self.runRecordedRoute(
                    self.outcome(.retained(.keyUp), [1, 2, 3]), engine: engine, clock: clock,
                    injectorResult: standardResult)
            }),
            // Row 5: the engine observes the cancellation as CancellationError — a discard,
            // not a failure; the ASR span was measured before it threw.
            ("engine throws CancellationError", .aborted, .idle, [.asr], true, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock, error: CancellationError())
                return await self.runRecordedRoute(
                    self.outcome(.retained(.keyUp), [1, 2, 3]), engine: engine, clock: clock,
                    injectorResult: standardResult)
            }),
            // Row 6: cancelled *after* transcribe returned — the route is held inside the
            // engine's transcribe (the gate), the cancellation lands while it is parked, and
            // the post-transcribe guard at `DictationPipeline.swift:180` fires. A cancelled
            // transcription never injects (`PRODUCT_SPEC.md:129`), and the transcript the
            // engine did produce is attributed.
            ("cancelled after transcribe", .aborted, .idle, [.asr], true, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock, gated: true)
                let (pipeline, ledger, sessionID) = await self.makeRecordedPipeline(
                    engine: engine, clock: clock, injectorResult: standardResult)
                let effect = SessionEffect<AudioBuffer>.ended(
                    self.outcome(.retained(.keyUp), [1, 2, 3]))
                let target = self.target()
                let task = Task {
                    await pipeline.route(effect, target: target, sessionID: sessionID)
                }
                await self.waitUntil { await engine.parkedTranscribes == 1 }
                task.cancel()
                await engine.openGate()
                let surface = await task.value
                let records = await ledger.snapshot()
                return (surface, records, sessionID, engine.identity)
            }),
            // Row 7: the engine's own answer can be empty for non-empty audio — whatever it
            // called silence, `""` is never pasted and never held.
            ("empty transcript text", .emptySkip, .idle, [.asr], true, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock, text: "")
                return await self.runRecordedRoute(
                    self.outcome(.retained(.keyUp), [1, 2, 3]), engine: engine, clock: clock,
                    injectorResult: standardResult)
            }),
            // Row 8: a delivered rung is a success under I1 — the class carries the rung and
            // the read-back truth off the InjectionResult, verbatim.
            ("delivered via accessibility", .delivered(rung: .accessibility, verified: true),
                .idle, [.asr, .inject], true, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock)
                let result = InjectionResult(
                    rung: .accessibility, attempted: [.accessibility], verified: true,
                    elapsed: injectElapsed)
                return await self.runRecordedRoute(
                    self.outcome(.retained(.keyUp), [1, 2, 3]), engine: engine, clock: clock,
                    injectorResult: result)
            }),
            ("delivered via clipboardPaste", .delivered(rung: .clipboardPaste, verified: false),
                .idle, [.asr, .inject], true, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock)
                let result = InjectionResult(
                    rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                    elapsed: injectElapsed)
                return await self.runRecordedRoute(
                    self.outcome(.retained(.keyUp), [1, 2, 3]), engine: engine, clock: clock,
                    injectorResult: result)
            }),
            ("delivered via keystrokeSynthesis", .delivered(rung: .keystrokeSynthesis, verified: false),
                .idle, [.asr, .inject], true, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock)
                let result = InjectionResult(
                    rung: .keystrokeSynthesis, attempted: [.keystrokeSynthesis], verified: false,
                    elapsed: injectElapsed)
                return await self.runRecordedRoute(
                    self.outcome(.retained(.keyUp), [1, 2, 3]), engine: engine, clock: clock,
                    injectorResult: result)
            }),
            // Row 9: the failsafe's handoff already holds — the class is `failsafeHeld`, and
            // the inject span still records the ladder's own measurement.
            ("widgetFailsafe with the transcript held", .failsafeHeld,
                .transcriptHeld(HeldTranscript(
                    text: "1 2 3", reason: .exhausted, targetAppName: "Notes",
                    capturedAt: .seconds(7))),
                [.asr, .inject], true, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock)
                let result = InjectionResult(
                    rung: .widgetFailsafe, attempted: [.accessibility, .clipboardPaste],
                    verified: false, elapsed: injectElapsed)
                return await self.runRecordedRoute(
                    self.outcome(.retained(.keyUp), [1, 2, 3]), engine: engine, clock: clock,
                    injectorResult: result,
                    held: HeldTranscript(
                        text: "1 2 3", reason: .exhausted, targetAppName: "Notes",
                        capturedAt: .seconds(7)))
            }),
            // Row 10: a `.widgetFailsafe` with *nothing* held — the journal refused custody —
            // is a visible failure, not a silent idle.
            ("widgetFailsafe with nothing held", .failed, .reasonOnly(.exhausted),
                [.asr, .inject], true, {
                let clock = TableClock()
                let engine = TableEngine(clock: clock)
                let result = InjectionResult(
                    rung: .widgetFailsafe, attempted: [.accessibility], verified: false,
                    elapsed: injectElapsed)
                return await self.runRecordedRoute(
                    self.outcome(.retained(.keyUp), [1, 2, 3]), engine: engine, clock: clock,
                    injectorResult: result)
            }),
        ]

        for testCase in cases {
            let ran = await testCase.run()
            let name = testCase.name

            XCTAssertEqual(
                ran.records.count, 1,
                "\(name): exactly one record per route — no path produces no record, none two")
            guard let record = ran.records.first else { continue }
            XCTAssertEqual(record.id, ran.sessionID, "\(name): the record carries the minted id")
            XCTAssertEqual(
                record.outcome, testCase.outcome,
                "\(name): the class from the pipeline's own table")
            XCTAssertEqual(
                record.spans.map(\.name), testCase.spanNames,
                "\(name): spans in recording order — asr before inject, nothing else recorded")
            XCTAssertTrue(
                record.spans.allSatisfy { $0.presence == .recorded },
                "\(name): a recorded span is never notPresent")
            XCTAssertNil(
                record.spans.first { $0.name == .cleanup },
                "\(name): cleanup never ran (C5 unbuilt) — never a recorded span")
            if testCase.engineAttributed {
                XCTAssertEqual(
                    record.engine, ran.engineIdentity,
                    "\(name): the engine was asked — attribution is the engine's identity")
            } else {
                XCTAssertNil(
                    record.engine,
                    "\(name): the engine was never asked — attribution stays nil")
            }
            if testCase.spanNames.contains(.asr) {
                XCTAssertEqual(
                    record.spans[0].elapsed, asrAdvance,
                    "\(name): the ASR span carries the measured delta between the pipeline's two "
                        + "clock reads — never a fabricated zero")
            }
            if testCase.spanNames.contains(.inject) {
                XCTAssertEqual(
                    record.spans[1].elapsed, injectElapsed,
                    "\(name): the inject span carries the InjectionResult's elapsed verbatim")
            }
            XCTAssertEqual(ran.surface, testCase.surface, "\(name): the surface is the table's")
        }
    }

    /// The absence pin (spec W1, plan §6): the recorder and the clock are wired, but the router
    /// did not begin a session — `sessionID` is the default `nil` — so the route must behave
    /// exactly as before (transcribe and inject, the same `.idle` surface) and record nothing:
    /// the ledger stays empty.
    func testRouteWithARecorderAndClockButNoSessionIDRecordsNothing() async {
        let ledger = LatencyLedger()
        let engine = StubEngine.parakeet()
        let injector = LedgerTextInjector(
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))
        let pipeline = DictationPipeline(
            engine: engine, injector: injector, holder: LedgerTranscriptHolder(),
            recorder: ledger, clock: TableClock())

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target())

        XCTAssertEqual(surface, .idle, "no sessionID — the route itself is unchanged")
        let snapshot = await ledger.snapshot()
        XCTAssertTrue(
            snapshot.isEmpty,
            "without a sessionID no record may begin or finalize — the ledger is untouched")
        let transcribeCalls = await engine.transcribeCalls
        XCTAssertEqual(transcribeCalls, 1, "the absence is about recording, not about routing")
        let calls = await injector.calls
        XCTAssertEqual(calls.count, 1)
    }

    /// The defaults' absence pin: a pipeline built with no recorder and no clock, routed without
    /// a sessionID, behaves exactly as before — the same surfaces, the same engine/injector/
    /// holder behaviour, nothing crashes.
    func testADefaultPipelineWithNoRecorderOrClockRoutesExactlyAsBefore() async {
        let engine = StubEngine.parakeet()
        let (pipeline, injector, holder) = makePipeline(
            engine: engine,
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        let delivered = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target())
        XCTAssertEqual(delivered, .idle)

        let cancelled = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.userCancelled, [1, 2, 3])),
            target: target())
        XCTAssertEqual(cancelled, .idle)

        let transcribeCalls = await engine.transcribeCalls
        XCTAssertEqual(transcribeCalls, 1, "only the delivered route asked the engine")
        let calls = await injector.calls
        XCTAssertEqual(calls.count, 1, "the cancelled route injected nothing")
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 0)
        let holdCalls = await holder.holdCalls
        XCTAssertEqual(holdCalls, 0)
    }

    // MARK: - The cleanup stage: wired, degraded, budgeted, recorded

    /// **B1 — clean routes through.** With a cleanup provider wired, the raw transcript reaches
    /// `clean` and the provider's output — **not** the raw text — is what the injector records
    /// (the ledger-injector convention). The context handed over carries the route's target, the
    /// dictation mode and the pipeline's shipped budget as information only.
    func testCleanRoutesThroughAndTheInjectorReceivesTheCleanedText() async {
        let provider = ScriptedCleanupProvider(behavior: .returns("cleaned"))
        let target = target()
        let (pipeline, injector, _, _) = makeCleanupPipeline(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero),
            cleanup: provider)

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target)

        XCTAssertEqual(surface, .idle)
        let calls = await injector.calls
        XCTAssertEqual(
            calls, [InjectionCall(text: "cleaned", target: target)],
            "the cleaned text — not the raw transcript — is what reaches the injector")
        let cleanCalls = await provider.cleanCalls
        XCTAssertEqual(cleanCalls, 1, "the wired provider was asked exactly once")
        let received = await provider.receivedContext
        XCTAssertEqual(received?.target, target, "the context's target is the route's target")
        XCTAssertEqual(received?.mode, .dictation, "the context's mode is the dictation mode")
        XCTAssertEqual(
            received?.budget, .milliseconds(10),
            "the context carries the pipeline's shipped budget (ARCHITECTURE.md:316) — "
                + "caller-enforced, handed over as information")
    }

    /// **B2 — nil is today.** `cleanup: nil` calls no provider, injects the raw text, and the
    /// finalized record carries no cleanup span — the ledger's `notPresent` is the absence
    /// (`describe()` renders only recorded spans). Nothing is constructed, so no provider can be
    /// called.
    func testNilCleanupCallsNoProviderInjectsRawAndRecordsNoCleanupSpan() async {
        let clock = TableClock()
        let (pipeline, injector, _, ledger) = makeCleanupPipeline(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero),
            cleanup: nil,
            clock: clock)
        let sessionID = await ledger.beginSession()

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target(), sessionID: sessionID)

        XCTAssertEqual(surface, .idle)
        let calls = await injector.calls
        XCTAssertEqual(
            calls.map(\.text), ["1 2 3"],
            "nil cleanup is today's behavior, byte for byte — the raw transcript reaches the "
                + "injector")
        let records = await ledger.snapshot()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(
            records.first?.spans.first { $0.name == .cleanup },
            "a nil-cleanup pipeline records no cleanup span — cleanup stays notPresent")
    }

    /// **B3 — hung provider → raw within budget.** A provider that never completes, against a
    /// short injected-clock budget, terminates with the raw text reaching the injector — the
    /// caller's cancellation fires on the *injected clock*, not on the provider's cooperation.
    /// The double advances the shared clock past the budget and then suspends
    /// cancellation-responsively, so the test is instant: no wall-clock waiting.
    func testAHungProviderFallsBackToRawWithinTheInjectedClockBudget() async {
        let clock = TableClock()
        let provider = ScriptedCleanupProvider(
            behavior: .hangs(clock: clock, budget: .milliseconds(10)))
        let (pipeline, injector, _, _) = makeCleanupPipeline(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero),
            cleanup: provider,
            clock: clock)

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target())

        XCTAssertEqual(surface, .idle)
        let calls = await injector.calls
        XCTAssertEqual(
            calls.map(\.text), ["1 2 3"],
            "a provider that never returns must not block the loop — the injected-clock deadline "
                + "fires, the group cancels the provider, and raw proceeds")
    }

    /// **B4 — provider throwing → raw, and the cleanup span is still recorded.** The throw
    /// degrades to the raw text (the surface is the rung's own `.idle`), and the span's elapsed
    /// is the measured delta between the pipeline's two clock reads — the double advances the
    /// shared clock during `clean`, the W1 table's ``TableEngine`` shape — never a fabricated
    /// zero, exactly like the throwing ASR row's.
    func testAThrowingProviderRoutesRawAndStillRecordsTheCleanupSpan() async {
        let clock = TableClock()
        let provider = ScriptedCleanupProvider(
            behavior: .throws, clock: clock, advance: .milliseconds(2))
        let (pipeline, injector, _, ledger) = makeCleanupPipeline(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero),
            cleanup: provider,
            clock: clock)
        let sessionID = await ledger.beginSession()

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target(), sessionID: sessionID)

        XCTAssertEqual(surface, .idle)
        let calls = await injector.calls
        XCTAssertEqual(
            calls.map(\.text), ["1 2 3"],
            "a throwing cleanup degrades to the raw text — the throw never loses the transcript")
        let records = await ledger.snapshot()
        XCTAssertEqual(records.count, 1)
        let cleanupSpan = records.first?.spans.first { $0.name == .cleanup }
        XCTAssertEqual(
            cleanupSpan?.elapsed, .milliseconds(2),
            "the cleanup span is recorded on the throwing path — the measured delta between the "
                + "pipeline's two clock reads, never a fabricated zero")
    }

    /// **B5 — empty clean result → raw (never-empty).** The provider returns `""` and `"   "`;
    /// in both rows the raw text reaches the injector. The empty-text guard ran before cleanup,
    /// so this is cleanup's own guard: cleanup never injects `""`.
    func testAnEmptyCleanResultFallsBackToRaw() async {
        for scripted in ["", "   "] {
            let provider = ScriptedCleanupProvider(behavior: .returns(scripted))
            let (pipeline, injector, _, _) = makeCleanupPipeline(
                engine: StubEngine.parakeet(),
                injectorResult: InjectionResult(
                    rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                    elapsed: .zero),
                cleanup: provider)

            let surface = await pipeline.route(
                SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
                target: target())

            XCTAssertEqual(surface, .idle, "scripted result: \(scripted)")
            let calls = await injector.calls
            XCTAssertEqual(
                calls.map(\.text), ["1 2 3"],
                "scripted result: \(scripted) — an empty/whitespace clean result falls back to "
                    + "the raw text (never-empty)")
        }
    }

    /// **B6 — Esc during cleanup → nothing injected.** The route task is cancelled mid-clean
    /// (the `signalAndHang` double parks on a cancellation-responsive suspension); the post-clean
    /// re-check discards the raw candidate: `.idle`, injector untouched, record finalized
    /// `.aborted` (`PRODUCT_SPEC.md:129`).
    func testCancellationDuringCleanupInjectsNothingAndFinalizesAborted() async {
        let provider = ScriptedCleanupProvider(behavior: .signalAndHang)
        let (pipeline, injector, _, ledger) = makeCleanupPipeline(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero),
            cleanup: provider)
        let sessionID = await ledger.beginSession()
        let effect = SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3]))
        let target = target()

        let task = Task {
            await pipeline.route(effect, target: target, sessionID: sessionID)
        }
        var turns = 0
        while !(await provider.cleanStarted) && turns < 20_000 {
            await Task.yield()
            turns += 1
        }
        let cleanStarted = await provider.cleanStarted
        XCTAssertTrue(cleanStarted, "the route never reached the cleanup stage")
        task.cancel()
        let surface = await task.value

        XCTAssertEqual(
            surface, .idle,
            "a cancellation that landed during cleanup discards — nothing is injected")
        let calls = await injector.calls
        XCTAssertEqual(calls, [], "a cancelled transcription must never inject")
        let records = await ledger.snapshot()
        XCTAssertEqual(
            records.first?.outcome, .aborted,
            "the record finalizes aborted — the cancelled route's cleanup is a discard")
    }

    /// **B7 — failsafe holds cleaned text.** On the `.widgetFailsafe` path the surfaced
    /// ``HeldTranscript``'s text is the cleaned text, and the holder was read exactly once.
    func testWidgetFailsafeHoldsTheCleanedTextAndReadsTheHolderOnce() async {
        let held = HeldTranscript(
            text: "cleaned", reason: .exhausted, targetAppName: "Notes", capturedAt: .seconds(7))
        let provider = ScriptedCleanupProvider(behavior: .returns("cleaned"))
        let (pipeline, injector, holder, _) = makeCleanupPipeline(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .widgetFailsafe, attempted: [.accessibility, .clipboardPaste],
                verified: false, elapsed: .zero),
            held: held,
            cleanup: provider)

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target())

        XCTAssertEqual(
            surface, .transcriptHeld(held),
            "the failsafe surface is the cleaned text the handoff held")
        let currentCalls = await holder.currentCalls
        XCTAssertEqual(currentCalls, 1, "the holder is read exactly once on the failsafe path")
        let calls = await injector.calls
        XCTAssertEqual(
            calls.map(\.text), ["cleaned"],
            "the cleaned text — not the raw — reached the ladder before the failsafe held it")
    }

    /// **B8-pipeline — the cleanup span is recorded with the injected clock.** With recorder,
    /// clock and cleanup wired, the finalized record's spans include `cleanup` with an elapsed
    /// equal to the injected clock's delta — the double advances the shared clock during `clean`,
    /// the W1 ASR-span assertion style (measured delta, never a fabricated zero).
    func testCleanupSpanIsRecordedWithTheInjectedClock() async {
        let clock = TableClock()
        let provider = ScriptedCleanupProvider(
            behavior: .returns("cleaned"), clock: clock, advance: .milliseconds(3))
        let (pipeline, injector, _, ledger) = makeCleanupPipeline(
            engine: StubEngine.parakeet(),
            injectorResult: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero),
            cleanup: provider,
            clock: clock)
        let sessionID = await ledger.beginSession()

        let surface = await pipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target(), sessionID: sessionID)

        XCTAssertEqual(surface, .idle)
        let calls = await injector.calls
        XCTAssertEqual(calls.map(\.text), ["cleaned"])
        let records = await ledger.snapshot()
        XCTAssertEqual(records.count, 1)
        let cleanupSpan = records.first?.spans.first { $0.name == .cleanup }
        XCTAssertEqual(
            cleanupSpan?.elapsed, .milliseconds(3),
            "the cleanup span carries the measured delta between the pipeline's two clock reads — "
                + "never a fabricated zero")
    }
}

/// What a scripted transcription failure is, for the throw row of the table. The specific error
/// is the engine's business — the pipeline must not stringify it.
private enum FakeTranscriptionError: Error {
    case boom
}

/// What a scripted cleanup failure is, for the throwing row of the cleanup contract. The specific
/// error is the provider's business — the pipeline must not stringify it, and the degrade must not
/// care which error it was.
private enum FakeCleanupError: Error {
    case boom
}

/// **An ASR engine the test scripts** — the failure and empty-answer rows of the table, which
/// ``StubEngine`` cannot produce by construction (`ASRTestDoubles.swift:40-45`). An actor, for
/// the boundary reason ``StubEngine`` is one: `ASREngine` is a `Sendable` protocol, and the
/// double must cross the boundary honestly.
actor ScriptedEngine: ASREngine {
    let identity = EngineIdentity(
        id: "scripted-engine", displayName: "Scripted engine", isLocal: true)
    let supportsStreaming = false
    private let text: String?
    private let error: Error?
    private(set) var transcribeCalls = 0

    init(text: String? = nil, error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func prepare() async throws {}

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeCalls += 1
        if let error { throw error }
        return Transcript(
            text: text ?? "",
            segments: [],
            engine: identity,
            isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}

/// **One recorded injection** — the injector ledger's row, `Equatable` so the table can assert
/// the exact text and the exact context the pipeline handed the ladder.
fileprivate struct InjectionCall: Equatable {
    let text: String
    let target: TargetContext
}

/// **The injector, with a ledger** — every call's text and target recorded in order, and one
/// fixed result. The result is fixed at construction so a test varies exactly one thing; the
/// ledger is what makes "never called" an assertion instead of an assumption.
actor LedgerTextInjector: TextInjector {
    private let result: InjectionResult
    fileprivate var calls: [InjectionCall] = []

    init(result: InjectionResult) {
        self.result = result
    }

    func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        calls.append(InjectionCall(text: text, target: target))
        return result
    }
}

/// **The holder, with a ledger** — every method's call count recorded, and a transcript the test
/// preloads to stand in for the ladder's handoff. An actor, for the same boundary reason as
/// ``ScriptedEngine``: `TranscriptHolder` is a `Sendable` protocol.
actor LedgerTranscriptHolder: TranscriptHolder {
    private var held: HeldTranscript?
    private(set) var holdCalls = 0
    private(set) var currentCalls = 0
    private(set) var releaseCalls = 0

    init(held: HeldTranscript? = nil) {
        self.held = held
    }

    func hold(_ transcript: HeldTranscript) async throws {
        holdCalls += 1
        held = transcript
    }

    func current() async -> HeldTranscript? {
        currentCalls += 1
        return held
    }

    func release() async {
        releaseCalls += 1
    }
}

// MARK: - The cleanup contract's own doubles

/// What the scripted cleanup provider answers on its one `clean` call.
private enum ScriptedCleanupBehavior {
    /// Answers the scripted text — the B1/B5/B7/B8 rows.
    case returns(String)
    /// Throws `FakeCleanupError.boom` — the B4 row.
    case `throws`
    /// Advances the shared clock past `budget`, then suspends cancellation-responsively
    /// (`try await Task.sleep`) — the B3 hung-provider row: the provider never returns, and the
    /// injected-clock deadline must fire anyway. The suspension observes cancellation so the
    /// group's child-await completes instantly when the watcher wins.
    case hangs(clock: TableClock, budget: Duration)
    /// Sets `cleanStarted` and suspends the same way — the B6 row, so the test can cancel the
    /// route task *during* cleanup.
    case signalAndHang
}

/// **A cleanup provider the test scripts** — the B1–B8 rows of the cleanup contract, in
/// ``ScriptedEngine``'s shape: an actor, because `CleanupProvider` is a `Sendable` protocol and
/// the double must cross the boundary honestly. `requiresNetwork` is declared `false` — the
/// B10-style honesty applied to the double too.
///
/// `clock`/`advance` are the shared injected clock the double moves during `clean` — the W1
/// table's ``TableEngine`` shape: the pipeline's two clock reads straddle a real, asserted delta,
/// so the cleanup span's elapsed is measured, never a fabricated zero.
private actor ScriptedCleanupProvider: CleanupProvider {
    let identity = ProviderIdentity(
        id: "scripted-cleanup", displayName: "Scripted cleanup")
    nonisolated var requiresNetwork: Bool { false }

    private let behavior: ScriptedCleanupBehavior
    private let clock: TableClock?
    private let advance: Duration

    private(set) var cleanCalls = 0
    private(set) var receivedContext: CleanupContext?
    private(set) var cleanStarted = false

    init(behavior: ScriptedCleanupBehavior, clock: TableClock? = nil, advance: Duration = .zero) {
        self.behavior = behavior
        self.clock = clock
        self.advance = advance
    }

    func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        cleanCalls += 1
        receivedContext = context
        if let clock { clock.now += advance }
        switch behavior {
        case .returns(let text):
            return text
        case .throws:
            throw FakeCleanupError.boom
        case .hangs(let hangsClock, let budget):
            hangsClock.now += budget + .milliseconds(1)
            try await Task.sleep(for: .seconds(3600))
            return ""
        case .signalAndHang:
            cleanStarted = true
            try await Task.sleep(for: .seconds(3600))
            return ""
        }
    }
}

// MARK: - W1: the recorded table's own doubles

/// **The W1 table's hand-moved clock** — `TestClock`'s role, `Sendable` because the pipeline is
/// a `Sendable` struct and `MonotonicClock` itself carries no `Sendable` requirement: a plain
/// class clock like ``TestClock`` could not cross into the pipeline's stored properties under
/// strict concurrency (the harness's other hand-moved clocks are plain classes for exactly that
/// reason — they live in non-`Sendable` holders).
///
/// `@unchecked Sendable` is the claim every test clock with a mutable reading makes, confined to
/// this file: the reading is only ever mutated by this suite's own thread and by the
/// ``TableEngine`` actor it is handed to, serialized by the gate.
private final class TableClock: MonotonicClock, @unchecked Sendable {
    var now: Duration = .zero
}

/// **The W1 table's engine** — `ScriptedEngine`'s role with the clock in the loop: `transcribe`
/// advances the shared ``TableClock`` by a fixed step, so the pipeline's two clock reads straddle
/// a real, asserted delta (measured, not assumed), and then answers from a scripted text/error.
///
/// `gated` is the cancelled-after-transcribe row's transcribe gate: `transcribe` parks on a
/// continuation until the test opens it, so the route is *held mid-transcribe* and the
/// cancellation lands deterministically — the `GatedPrepareEngine` precedent
/// (`DictationEngineResolverTests.swift:230-277`).
private actor TableEngine: ASREngine {
    let identity = EngineIdentity(
        id: "table-engine", displayName: "Table engine", isLocal: true)
    let supportsStreaming = false

    /// How much one `transcribe` advances the shared clock.
    private let advance: Duration
    private let clock: TableClock
    private let text: String?
    private let error: Error?
    private let gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var transcribeCalls = 0
    private(set) var parkedTranscribes = 0

    init(
        clock: TableClock,
        advance: Duration = .milliseconds(5),
        text: String? = nil,
        error: Error? = nil,
        gated: Bool = false
    ) {
        self.clock = clock
        self.advance = advance
        self.text = text
        self.error = error
        self.gated = gated
    }

    func prepare() async throws {}

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribeCalls += 1
        if gated {
            parkedTranscribes += 1
            await withCheckedContinuation { self.gate = $0 }
        }
        clock.now += advance
        if let error { throw error }
        return Transcript(
            text: text ?? "1 2 3",
            segments: [],
            engine: identity,
            isFinal: true,
            audioDuration: buffer.audioDuration)
    }

    func openGate() {
        gate?.resume()
        gate = nil
    }
}
