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

/// What the dictation pipeline did with one session — the widget-facing answer of the loop
/// wiring's routing half.
///
/// Three cases, and the set is closed for the reason every enum in this module is closed: a
/// fourth thing the pipeline can do must be given a meaning here rather than quietly inheriting
/// one of these. ``idle`` is *not* a failure — it is the honest answer of every path that has
/// nothing for the widget to show (a cancelled session, an empty press, a delivered transcript);
/// ``transcriptHeld`` and ``reasonOnly`` are the two surfaces the FAILSAFE window renders
/// (`prd.md:80-88`, PRD R5).
public enum PipelineSurface: Sendable, Equatable {
    /// Nothing to present: the session was cancelled, captured nothing, delivered its text, or
    /// was not an ended session at all.
    case idle

    /// The ladder fell through to the failsafe, the handoff held the transcript durably (I1 —
    /// `ARCHITECTURE.md:199`), and here it is, verbatim, for the FAILSAFE window to present.
    case transcriptHeld(HeldTranscript)

    /// A reason-only notice: voice processing failed or the failsafe refused custody. **No text
    /// was ever held** — the reason-only window state has nothing to copy and nothing to retry
    /// (`FailsafeState.reasonShown`, the failure-surfaces aspect).
    case reasonOnly(FailsafeReason)
}

/// The dictation loop's routing half: what an ended session does to the engine, the injector and
/// the holder — decided entirely above the seams, over Core-owned protocols
/// (``ASREngine``, ``TextInjector``, ``TranscriptHolder``).
///
/// The session machine is **untouched**; its ``SessionEffect/ended(_:)`` is the only hand-off
/// point (`SessionEffect.swift:53-59`), and everything this type decides is decided over
/// injected seams so a test drives it headless.
///
/// ## The decision table
///
/// | Input | What happens | Surface |
/// |---|---|---|
/// | `.cancelled` outcome | Discarded — no transcribe, no inject, no holder touch. Esc is an instruction (`PRODUCT_SPEC.md:129`) | `.idle` |
/// | `.completed`, task cancelled | Esc during TRANSCRIBING — the in-flight transcribe task is cancelled (`AppBootstrap`'s router holds the handle), a discard not a failure: never inject, never notice | `.idle` |
/// | `.completed`, empty captured buffer | Decided empty *before* transcribe: the empty-buffer policy makes `samples.isEmpty` and `text == ""` the same fact (`ASREngine.swift:28-32`), so the 20 ms press never asks the engine | `.idle` |
/// | `.completed`, `transcribe` throws | Nothing was ever produced — PRD R5's `.transcriptionFailed` notice ("Nothing was lost — you can try again") | `.reasonOnly(.transcriptionFailed)` |
/// | `.completed`, empty transcript text | An engine that calls the audio silence still must not paste `""` | `.idle` |
/// | `.completed`, delivery rung | The text reached the focused field | `.idle` |
/// | `.completed`, `.widgetFailsafe` | The ladder's handoff already holds (the journal write is part of the hand-off, `FailsafeHandoff.swift:26-34`); the holder is read exactly once and the held transcript is surfaced | `.transcriptHeld(held)` |
/// | Not an ended effect | The widget's projection reads these; the pipeline does not | `.idle` |
///
/// ## Why the pipeline reads the holder instead of holding
///
/// The failsafe hold happens inside the ladder — ``LadderInjector`` is wired with the same
/// ``TranscriptHolder`` as both its `FailsafeHandoff` and this pipeline's holder
/// (`prd.md:80-84`), and the durable write is *part of the hand-off, not after it*. By the time
/// the pipeline sees `.widgetFailsafe`, the transcript is already held; the pipeline's half of
/// the contract is to surface it. It also cannot reconstruct one: ``InjectionResult`` carries the
/// rung and the trace but **not** the reason the ladder gave up, so a pipeline that built its own
/// ``HeldTranscript`` would have to fabricate the cause — exactly the lie `FailsafeReason`'s
/// documentation exists to forbid.
///
/// The one residual this design cannot avoid: a `.widgetFailsafe` result with **nothing** held —
/// the journal refused custody, the one branch `LadderInjector` catches and reports as the
/// failsafe outcome (`LadderInjector.swift:84-88`). No transcript exists to surface, and
/// fabricating one would lie about the cause; the pipeline surfaces
/// ``PipelineSurface/reasonOnly(.exhausted)`` instead, so the failure is *visible* rather than a
/// silent idle that would pretend the transcript was delivered. It is unreachable through the
/// real injector by contract (durable-before-return), and is pinned as the table's residual row.
///
/// ## Isolation
///
/// A plain `Sendable` struct, unlike ``LadderInjector``'s `@MainActor`: every dependency is a
/// `Sendable` protocol, so the pipeline needs no isolation domain of its own and a test can drive
/// it directly. The route is `async` because every seam on it is.
///
/// ## The latency record (loop-wiring Phase 1)
///
/// The pipeline is the closed-set finalizer of the session's latency record: when the router
/// wired a ``LatencyRecorder``, a ``MonotonicClock`` and a minted ``SessionRecord/ID`` in, every
/// row of the table above finalizes its record — `aborted` for the three cancelled rows and the
/// two never-asked skips, `emptySkip` for the empty buffer, `failed` for the transcribe failure,
/// `emptySkip` for the empty text, `delivered(rung:verified:)` off the ``InjectionResult``, and
/// `failsafeHeld`/`failed` for the failsafe's two fates. The ASR span is measured around
/// ``ASREngine/transcribe(_:)`` with the *injected* clock (never a clock read of its own — the
/// ``MonotonicClock`` contract), recorded even on the throwing path; the inject span is the
/// ``InjectionResult/elapsed`` the ladder already measured; attribution is the engine that was
/// asked, nil only on the rows that never asked one. The cleanup span is never recorded — the
/// record carries it as `notPresent` by construction (C5 is unbuilt, `LatencySpan.swift:27-32`).
public struct DictationPipeline: Sendable {
    private let engine: any ASREngine
    private let injector: any TextInjector
    private let holder: any TranscriptHolder
    private let recorder: (any LatencyRecorder)?
    private let clock: (any MonotonicClock & Sendable)?

    /// - Parameters:
    ///   - engine: The prepared engine, resolved once at launch by the composition root's engine
    ///     lifecycle (``DictationEngineResolver``). Non-optional: an unprepared engine refuses
    ///     *before* the session opens the microphone — the readiness gate lives above the
    ///     machine, so a session that ends can always be transcribed.
    ///   - injector: The injection ladder — ``LadderInjector`` at ship, any ``TextInjector`` in
    ///     a test.
    ///   - holder: The custody seam the ladder's handoff writes and this pipeline reads — the
    ///     ``JournalTranscriptHolder`` at ship.
    ///   - recorder: The latency ledger's seam; `nil` (the default) keeps the pipeline exactly
    ///     as it was before the loop-wiring phase — no span is measured, nothing is recorded.
    ///   - clock: The injected clock the ASR span is measured with; `nil` (the default) with
    ///     the same effect. `Sendable` because the pipeline is a `Sendable` struct and
    ///     ``MonotonicClock`` itself carries no `Sendable` requirement.
    public init(
        engine: any ASREngine,
        injector: any TextInjector,
        holder: any TranscriptHolder,
        recorder: (any LatencyRecorder)? = nil,
        clock: (any MonotonicClock & Sendable)? = nil
    ) {
        self.engine = engine
        self.injector = injector
        self.holder = holder
        self.recorder = recorder
        self.clock = clock
    }

    /// Routes one session effect through the dictation loop and answers what the widget should
    /// present.
    ///
    /// The only value with anything to route is ``SessionEffect/ended(_:)`` — the other four are
    /// the widget projection's news, not the pipeline's. `target` is the context the root
    /// resolved at key-down (S1) and the transcript is injected into that same context at
    /// key-up (`prd.md:136-139`) — the root holds it between the two because a focus change
    /// mid-session must not retarget.
    ///
    /// - Parameters:
    ///   - effect: One effect from the machine's `deliverEffect` stream.
    ///   - target: The focused application as it was at key-down; unused on every path that
    ///     does not inject.
    ///   - sessionID: The record ``LatencyRecorder/beginSession()`` minted for this session,
    ///     `nil` (the default) when no recording is wired — a nil id makes every record call a
    ///     no-op, so a router that forgot to begin records nothing rather than crashing.
    public func route(
        _ effect: SessionEffect<AudioBuffer>, target: TargetContext,
        sessionID: SessionRecord.ID? = nil
    ) async -> PipelineSurface
    {
        switch effect {
        case .unchanged, .started, .opening, .captureUnavailable:
            // Not an ended session: the widget's projection reads these effects; the dictation
            // pipeline has nothing to route, and no session record to close — the router owns
            // the non-ended terminals (`.captureUnavailable` finalizes `failed` itself).
            return .idle
        case .ended(let outcome):
            return await route(outcome, target: target, sessionID: sessionID)
        }
    }

    /// The ended-session half of the table, over the outcome's two fates.
    private func route(
        _ outcome: SessionOutcome<AudioBuffer>, target: TargetContext,
        sessionID: SessionRecord.ID?
    ) async -> PipelineSurface
    {
        switch outcome.content {
        case .cancelled:
            // The user asked to abandon the session. Nothing to hand on, by construction
            // (SessionOutcome.swift:93-101): no transcribe, no inject, no holder touch.
            await finalize(sessionID: sessionID, outcome: .aborted, engine: nil)
            return .idle
        case .completed(_, let audio, _):
            // The empty captured buffer is the empty text, decided before the engine is asked:
            // transcribing silence is a wasted latency-path call, and the empty-buffer policy
            // makes the two readings the same fact.
            if audio.samples.isEmpty {
                await finalize(sessionID: sessionID, outcome: .emptySkip, engine: nil)
                return .idle
            }
            return await transcribeAndInject(audio, target: target, sessionID: sessionID)
        }
    }

    /// Transcribe, then inject — the dictation half of the table.
    private func transcribeAndInject(
        _ audio: AudioBuffer, target: TargetContext, sessionID: SessionRecord.ID?
    ) async -> PipelineSurface
    {
        // A cancellation that landed before the engine was asked (Esc during TRANSCRIBING —
        // `PRODUCT_SPEC.md:129`): a discard, and the engine is not worth asking.
        guard !Task.isCancelled else {
            await finalize(sessionID: sessionID, outcome: .aborted, engine: nil)
            return .idle
        }

        // The ASR span wraps the whole engine call — measured with the injected clock, and
        // recorded on *every* answer, including the throwing one: the transcribe consumed the
        // time, so the failure's latency is real latency.
        let start = clock?.now
        let transcript: Transcript
        do {
            transcript = try await engine.transcribe(audio)
        } catch is CancellationError {
            // The user pressed Escape while the engine was transcribing, and the engine observed
            // the cancellation (the transcribe task is cancellable — the root cancels it through
            // the router). This is a discard, not a failure: no `.transcriptionFailed` notice,
            // nothing held, nothing injected.
            await recordASRSpan(from: start, sessionID: sessionID)
            await finalize(sessionID: sessionID, outcome: .aborted, engine: engine.identity)
            return .idle
        } catch {
            // PRD R5: a failed transcribe is a reason-only notice. Nothing was ever produced,
            // so nothing is held and nothing is lost — the notice is the whole surface.
            await recordASRSpan(from: start, sessionID: sessionID)
            await finalize(sessionID: sessionID, outcome: .failed, engine: engine.identity)
            return .reasonOnly(.transcriptionFailed)
        }
        await recordASRSpan(from: start, sessionID: sessionID)

        // A cancellation that landed *after* the transcribe returned: the engine finished, but
        // the user's Escape was earlier than the injection decision. **A cancelled transcription
        // must never inject** (`PRODUCT_SPEC.md:129`).
        guard !Task.isCancelled else {
            await finalize(sessionID: sessionID, outcome: .aborted, engine: transcript.engine)
            return .idle
        }

        // The engine's own answer can be empty even for non-empty audio; whatever it called
        // silence, `""` must not be pasted and no failsafe may hold it.
        guard !transcript.text.isEmpty else {
            await finalize(sessionID: sessionID, outcome: .emptySkip, engine: transcript.engine)
            return .idle
        }

        let result = await injector.inject(transcript.text, into: target)
        await recordInjectSpan(from: result, sessionID: sessionID)
        switch result.rung {
        case .widgetFailsafe:
            // The ladder's handoff already holds — the durable write was part of the hand-off
            // itself (FailsafeHandoff.swift:26-34). Surface what it held, reading the holder
            // exactly once; the residual (nothing held — the journal refused custody) surfaces
            // the exhaustion reason rather than pretending the text is somewhere it is not.
            guard let held = await holder.current() else {
                await finalize(sessionID: sessionID, outcome: .failed, engine: transcript.engine)
                return .reasonOnly(.exhausted)
            }
            await finalize(sessionID: sessionID, outcome: .failsafeHeld, engine: transcript.engine)
            return .transcriptHeld(held)
        case .accessibility, .clipboardPaste, .keystrokeSynthesis:
            // Delivered. A successful outcome under I1 — nothing for the widget to present.
            await finalize(
                sessionID: sessionID,
                outcome: .delivered(rung: result.rung, verified: result.verified),
                engine: transcript.engine)
            return .idle
        }
    }

    /// Records the ASR span the caller measured around ``ASREngine/transcribe(_:)``. A no-op on
    /// every absent wiring: no session id, no recorder or no clock (the measurement itself came
    /// from the clock, so without it there is nothing to record).
    private func recordASRSpan(from start: Duration?, sessionID: SessionRecord.ID?) async {
        guard let sessionID, let recorder, let start, let clock else { return }
        let elapsed = clock.now - start
        _ = await recorder.recordSpan(
            LatencySpan.recorded(name: .asr, elapsed: elapsed), for: sessionID)
    }

    /// Records the inject span from the ladder's own measurement — already-measured deltas only,
    /// the ``LatencyLedger`` contract (spec "Isolation decisions", A7).
    private func recordInjectSpan(from result: InjectionResult, sessionID: SessionRecord.ID?) async {
        guard let sessionID, let recorder else { return }
        _ = await recorder.recordSpan(
            LatencySpan.recorded(name: .inject, elapsed: result.elapsed), for: sessionID)
    }

    /// Closes the session's record with the class from the pipeline's own table. A no-op when
    /// nothing was begun (no session id) or no recorder is wired.
    private func finalize(
        sessionID: SessionRecord.ID?, outcome: SessionOutcomeClass, engine: EngineIdentity?
    ) async {
        guard let sessionID, let recorder else { return }
        _ = await recorder.finalize(id: sessionID, outcome: outcome, engine: engine)
    }
}
