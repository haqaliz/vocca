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
}

/// What a scripted transcription failure is, for the throw row of the table. The specific error
/// is the engine's business — the pipeline must not stringify it.
private enum FakeTranscriptionError: Error {
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
