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

/// **The converse loop's driver** (`dual-mode` PRD R6, `prd.md:150-163`): C10's recorded recipe
/// executed — the capture-stream driver, the utterance pipeline, the barge-in path and the
/// honest drops, composed over the loop's frozen seams (`barge-in-loop/plan_20260915.md:866-868`
/// — C11 wraps and selects, never modifies).
///
/// ## The drive shape (D2)
///
/// `start()` opens the capture (`ContinuousAudioSource.start()`) and spawns one main-actor
/// drive task: `for await frame in captureStream { loop.feed(frame); applyPendingEffects() }`.
/// The loop is synchronous and owner-isolated; the owner is this task, on the main actor (the
/// capture tick is main-actor-asserted and the loop is non-Sendable — confinement to one task,
/// never `@unchecked`). **The feed never pauses** (the C10 continuity doctrine): the utterance
/// pipeline runs in a `@MainActor` child task, so capture — which is continuous and never
/// stopped at interrupt time — keeps streaming while ASR/cleanup/reply work. The loop's own
/// guards make a late-landing reply safe: `scheduleReply` is refused in `.uttering` (never
/// speak over the user), in `.playing` (no double speech) and in `.idle`.
///
/// ## The effect application (the `ComposedTurnDriver.drain` shape)
///
/// - `.turnCommitted(utterance:)` → spawn the utterance pipeline: concatenate the frames →
///   resolve the ASR (**once per committed utterance** — D3: the provider reads the current
///   resolver, so a settings swap between turns uses the new engine; an unprepared engine
///   answers nil → the honest `.asrFailed` drop) → transcribe (a throw → `.asrFailed`; an
///   empty transcript → the silent skip — the dictation empty-skip policy) → resolve the
///   cleanup provider (**at most once per session** — nil → raw) → `clean` under the
///   injected-clock budget race (the `cleanIfWired` doctrine's caller-side copy — the
///   pipeline's is private and pinned; timeout/throw → raw) → **the intent step** (R4: a
///   resolved utterance branches — `.ask` speaks its question, bounded — a second
///   consecutive `.ask` falls through; `.toolCall` speaks the handler's reply, a silent
///   handler falls through; `.none`/unwired falls through — the reply generator untouched)
///   → `replyGenerator` → `loop.scheduleReply`.
/// - `.speakReply(text:)` → spawn the render child: resolve the synthesizer lazily → render
///   one pass collecting `AudioChunk`s → `reportPlaybackStarted()` (the window opens) → each
///   chunk via `reportPlaybackChunk` (the echo gate's reference) → `playback.play`. **The
///   window stays open after play** — the reply is still sounding, which is what lets the next
///   speech frame barge in; only the barge-in path (or a render/play failure) closes it. A
///   render/play throw → `reportPlaybackEnded()` (`.playing → .listening`, the honest close)
///   + one `.replyFailed` notice. A barge-in that already left `.playing` skips the play — a
///   discarded reply is never played.
/// - `.bargeIn` → `synthesizer.cancel()` (the ≤50 ms contract — C10's recorded acceptance, not
///   re-litigated) + `playback.cancelToSilence()` + `loop.reportPlaybackEnded()`.
/// - `.captureFailed` → `failureSink(.captureFailed)` once.
/// - `.started` / `.stopped` / `.speechBegan` → nothing (the projection rides `onStateChange`).
///
/// ## The honest stop (D5)
///
/// If the capture stream ends while the driver still believes the session is running (the
/// abnormal end — the converter-error path's shape), the driver calls
/// `loop.reportCaptureFailed()` — the loop's deliberately no-trap path — and the `.captureFailed`
/// effect delivers the notice once. A `stop()` requested by the owner is not a failure: the
/// driver marks the stop before closing the capture, so the stream's end is read as normal.
/// A `start()` refusal (`.unavailable` / `.alreadyStarted`) throws to the caller — nothing is
/// started, no notice is owed. A second `start()` while running is refused (the ownership pin,
/// mapped from `.alreadyStarted`).
///
/// ## What the driver is not
///
/// It names **no injector** — converse never injects (R6; the structural prohibition is the
/// mode machine's, and this file makes it vacuously true by construction: a driver with no
/// injector seam has nothing to reach) — and no network type. Its recipes (the ASR provider,
/// the cleanup provider, the intent provider, the action handler, the synthesizer) are lazy
/// closures so construction is pure and the zero-network probe stays green (D1).
@MainActor
public final class ConverseLoopDriver {

    /// The composed turn loop — public because the mode machine's owner reads its state; the
    /// `ComposedTurnDriver` precedent.
    public let loop: TurnTakingLoop

    /// The full effect ledger — appended by the loop's `onEffect` hook, never consumed, so the
    /// contract tests read the whole trajectory ("assertions read the ledger, never a believed
    /// call").
    public var effects: [TurnEffect] { effectLedger.values }

    /// The continuous microphone this driver owns.
    private let capture: any ContinuousAudioSource

    /// The ASR recipe — resolved **once per committed utterance** (D3). `async` because the
    /// composition reads the current resolver's readiness (`DictationEngineResolver` is an
    /// actor — a synchronous provider cannot read it); a provider that never suspends is a
    /// synchronous closure, which satisfies the async parameter unchanged.
    private let asrProvider: @Sendable () async -> (any ASREngine)?

    /// The cleanup recipe — resolved at most once per session.
    private let cleanupProvider: @Sendable () async throws -> (any CleanupProvider)?

    /// The intent recipe — the resolution of a cleaned utterance (`intent-layer` PRD R4), in
    /// the `asrProvider`/`cleanupProvider` shape: resolved **once per committed utterance**,
    /// after cleanup, before the reply. `nil` is the unwired answer — today's behavior,
    /// byte-identical. `async` because the wiring's resolver may be an actor (the same reason
    /// the ASR recipe is); a synchronous closure satisfies it unchanged.
    private let intentProvider: @Sendable (String) async -> IntentResolution?

    /// The action leg — the spoken reply after a `.toolCall`'s terminal decision. `nil` is
    /// the honest-drop channel (the driver's silent-return discipline): the pipeline falls
    /// through to the reply generator, never a throw, never a notice.
    private let intentActionHandler: @Sendable (ActionInvocation) async -> String?

    /// The reply generator — the shipped deterministic stand-in behind the R7 seam.
    private let replyGenerator: any ReplyGenerator

    /// The synthesizer recipe — resolved lazily, at the first `.speakReply`.
    private let synthesizerProvider: @Sendable () async throws -> any SpeechSynthesizer

    /// The duckable playback engine the rendered reply drains into.
    private let playback: any PlaybackEngine

    /// The only time source — the playback window's and the cleanup race's clock.
    ///
    /// `Sendable` for the same reason the pipeline's is (`DictationPipeline.swift:110` —
    /// "`Sendable` because ... `MonotonicClock` itself carries no `Sendable` requirement"): the
    /// cleanup race's watcher reads it from a task closure. The shipped clock
    /// (`ContinuousMonotonicClock`) is a `Sendable` struct; the loop takes `any MonotonicClock`
    /// and receives the same value.
    private let clock: any MonotonicClock & Sendable

    /// The honest-drop notice sink.
    private let failureSink: @Sendable (ConverseTurnFailure) -> Void

    /// The effects the drive task has not yet applied — the `ComposedTurnDriver` pending shape.
    private let pendingEffects: EffectLedgerBox

    /// The effect ledger's box — a final class so the loop's `onEffect` closure can capture it
    /// while `self` is still mid-initialization (the `ComposedTurnDriver` shape).
    private let effectLedger: EffectLedgerBox

    /// The in-flight utterance pipeline, cancelled by `stop()`.
    private var pipelineTask: Task<Void, Never>?

    /// The in-flight reply render, cancelled by `stop()`.
    private var renderTask: Task<Void, Never>?

    /// The drive task — one per session.
    private var driveTask: Task<Void, Never>?

    /// Whether a session is live — the ownership pin read by `start()`/`stop()`.
    private var running = false

    /// Whether the owner asked for the stop — the stream's end is then normal, never a failure.
    private var stopRequested = false

    /// The session's resolved cleanup provider — at most one, resolved lazily.
    private var cleanup: (any CleanupProvider)?

    /// The session's resolved synthesizer — at most one, resolved lazily.
    private var synthesizer: (any SpeechSynthesizer)?

    /// The bounded re-ask counter (`intent-layer` PRD R4): consecutive `.ask` resolutions,
    /// per-session, reset on any non-`.ask` outcome.
    private var consecutiveAsks = 0

    /// The re-ask bound (PRD R4): a question is spoken while the consecutive-`.ask` count is
    /// below the bound — so exactly the first `.ask` of a run is spoken, and a second
    /// consecutive one falls through to the reply generator (still `.ask` after the
    /// re-resolution → fall through to `.none`/echo).
    private static let askBound = 2

    /// The nothing-focused target: converse never names a target (`PRODUCT_SPEC.md:200`).
    private static let nothingFocused = TargetContext(
        bundleID: nil, windowTitle: nil, isSecureInput: false)

    /// - Parameters:
    ///   - vad: the voice-activity seam — passed through to the loop.
    ///   - turnDetector: the turn-commitment seam — passed through to the loop.
    ///   - clock: the one time source — passed through to the loop, and the cleanup race's.
    ///     `Sendable` (the pipeline's documented shape): the race's watcher reads it from a
    ///     task closure; the shipped `ContinuousMonotonicClock` conforms.
    ///   - gate: the echo gate — passed through to the loop.
    ///   - capture: the continuous microphone — one instance, one microphone.
    ///   - asrProvider: the engine recipe, read at the moment an utterance commits (`async` —
    ///     the current resolver is an actor; a synchronous closure satisfies it unchanged).
    ///   - cleanupProvider: the cleanup recipe, resolved at most once per session.
    ///   - intentProvider: the intent recipe — the resolution of a cleaned utterance, read at
    ///     the moment a turn reaches the intent step. `nil` (the default) is the unwired
    ///     answer: today's reply-generator behavior, byte-identical.
    ///   - intentActionHandler: the action leg — the spoken reply after a `.toolCall`'s
    ///     terminal decision. `nil` (the default) stays silent and the pipeline falls through
    ///     to the reply generator.
    ///   - replyGenerator: the R7 seam's deterministic stand-in.
    ///   - synthesizer: the speech recipe, resolved at the first `.speakReply`.
    ///   - playback: the duckable output the rendered reply drains into.
    ///   - onStateChange: the loop's N1 hook, wired at last — the widget projection's slot.
    ///   - failureSink: the honest-drop notice sink.
    public init(
        vad: any VoiceActivityDetector,
        turnDetector: any TurnDetector,
        clock: any MonotonicClock & Sendable,
        gate: EchoGate,
        capture: any ContinuousAudioSource,
        asrProvider: @escaping @Sendable () async -> (any ASREngine)?,
        cleanupProvider: @escaping @Sendable () async throws -> (any CleanupProvider)?,
        intentProvider: @escaping @Sendable (String) async -> IntentResolution? = { _ in nil },
        intentActionHandler: @escaping @Sendable (ActionInvocation) async -> String? = { _ in
            nil
        },
        replyGenerator: any ReplyGenerator,
        synthesizer: @escaping @Sendable () async throws -> any SpeechSynthesizer,
        playback: any PlaybackEngine,
        onStateChange: @escaping @Sendable (TurnState) -> Void,
        failureSink: @escaping @Sendable (ConverseTurnFailure) -> Void
    ) {
        self.capture = capture
        self.asrProvider = asrProvider
        self.cleanupProvider = cleanupProvider
        self.intentProvider = intentProvider
        self.intentActionHandler = intentActionHandler
        self.replyGenerator = replyGenerator
        self.synthesizerProvider = synthesizer
        self.playback = playback
        self.clock = clock
        self.failureSink = failureSink
        let ledger = EffectLedgerBox()
        let pending = EffectLedgerBox()
        self.effectLedger = ledger
        self.pendingEffects = pending
        self.loop = TurnTakingLoop(
            vad: vad,
            turnDetector: turnDetector,
            clock: clock,
            gate: gate,
            onEffect: { effect in
                ledger.values.append(effect)
                pending.values.append(effect)
            },
            onStateChange: onStateChange)
    }

    // MARK: - The public surface (thin funnels)

    /// Opens the capture, starts the loop and spawns the drive task.
    ///
    /// The `ContinuousAudioSourceError` maps through: an `.unavailable` capture throws to the
    /// caller and nothing is started; a second `start()` while running is refused with
    /// `.alreadyStarted` (the ownership pin at the driver level, backed by the capture's own).
    public func start() throws {
        guard !running else {
            throw ContinuousAudioSourceError.alreadyStarted
        }
        let stream = try capture.start()
        loop.start()
        running = true
        stopRequested = false
        driveTask = Task { @MainActor in
            for await frame in stream {
                loop.feed(frame)
                await applyPendingEffects()
            }
            await applyPendingEffects()
            if !stopRequested {
                loop.reportCaptureFailed()
                await applyPendingEffects()
            }
            running = false
        }
    }

    /// Ends the session: cancels the in-flight pipeline and render, closes the capture and
    /// stops the loop. Idempotent; a no-op when no session is running. A stop is never a
    /// failure — no notice is delivered (the user asked to stop).
    public func stop() async {
        guard running else { return }
        stopRequested = true
        running = false
        pipelineTask?.cancel()
        renderTask?.cancel()
        capture.stop()
        loop.stop()
        await driveTask?.value
    }

    // MARK: - The effect application

    /// Applies the pending effects in order, on the main actor — the drive task's and the
    /// pipeline's shared drain.
    private func applyPendingEffects() async {
        while !pendingEffects.values.isEmpty {
            let effect = pendingEffects.values.removeFirst()
            switch effect {
            case .turnCommitted(let utterance):
                pipelineTask = Task { @MainActor in
                    await self.runUtterancePipeline(utterance: utterance)
                }
            case .speakReply(let text):
                renderTask = Task { @MainActor in
                    await self.renderReply(text)
                }
            case .bargeIn:
                if let synthesizer {
                    await synthesizer.cancel()
                }
                await playback.cancelToSilence()
                loop.reportPlaybackEnded()
            case .captureFailed:
                failureSink(.captureFailed)
            case .started, .stopped, .speechBegan:
                break
            }
        }
    }

    // MARK: - The utterance pipeline

    /// The committed utterance's journey: ASR → cleanup(`.conversing`) → the intent step →
    /// reply → `scheduleReply`. Cancellation (a user stop) returns silently at every boundary
    /// — no `scheduleReply`, no notice.
    private func runUtterancePipeline(utterance: [AudioBuffer]) async {
        let buffer = AudioBuffer(
            samples: utterance.flatMap(\.samples),
            sampleRate: AudioBuffer.interchangeSampleRate)

        guard let engine = await asrProvider() else {
            failureSink(.asrFailed)
            return
        }
        let transcript: Transcript
        do {
            transcript = try await engine.transcribe(buffer)
        } catch is CancellationError {
            return
        } catch {
            failureSink(.asrFailed)
            return
        }
        guard !Task.isCancelled else { return }
        // An empty transcript is the seam's legitimate answer — nothing to reply to, a silent
        // skip, never a notice (the dictation empty-skip policy).
        guard !transcript.text.isEmpty else { return }

        let provider: (any CleanupProvider)?
        if let resolved = cleanup {
            provider = resolved
        } else if let resolved = try? await cleanupProvider() {
            cleanup = resolved
            provider = resolved
        } else {
            provider = nil
        }

        let raw: String
        if let provider {
            raw = await clean(transcript, provider: provider)
        } else {
            raw = transcript.text
        }
        guard !Task.isCancelled else { return }

        // The intent step (`intent-layer` PRD R4), between cleanup and the reply: a resolved
        // utterance branches — `.ask` speaks its question and nothing executes (R2: a guess
        // never runs), bounded by the re-ask counter; `.toolCall` speaks the action handler's
        // reply (a silent handler falls through — the honest-drop channel); `.none` and the
        // unwired `nil` fall through — the reply generator untouched, byte-identical.
        let reply: String
        if let resolution = await intentProvider(raw) {
            switch resolution {
            case .ask(let question):
                consecutiveAsks += 1
                if consecutiveAsks < Self.askBound {
                    reply = question
                } else {
                    reply = replyGenerator.reply(to: raw)
                }
            case .toolCall(let invocation):
                consecutiveAsks = 0
                reply = await intentActionHandler(invocation) ?? replyGenerator.reply(to: raw)
            case .none:
                consecutiveAsks = 0
                reply = replyGenerator.reply(to: raw)
            }
        } else {
            consecutiveAsks = 0
            reply = replyGenerator.reply(to: raw)
        }
        guard !Task.isCancelled else { return }
        loop.scheduleReply(reply)
        // The `.speakReply` we just queued is drained here — the drive task may be awaiting the
        // next capture frame, and the reply must not wait for one.
        await applyPendingEffects()
    }

    /// The caller-enforced cleanup race — the `cleanIfWired` doctrine's own copy (the
    /// pipeline's is private and pinned; the doctrine is the caller's, not the file's): the
    /// provider is raced against its own declared budget over the injected clock, and a
    /// timeout or a throw routes to the raw transcript — a transcript is never lost. An empty
    /// or whitespace-only clean result also falls back to the raw text.
    private func clean(_ transcript: Transcript, provider: any CleanupProvider) async -> String {
        let start = clock.now
        let budget = provider.budget
        let cleaned = try? await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await provider.clean(
                    transcript,
                    context: CleanupContext(
                        target: Self.nothingFocused, mode: .conversing, dictionary: [],
                        budget: budget))
            }
            group.addTask {
                // `!Task.isCancelled` is what makes the watcher a cooperative group member:
                // when the provider wins first (or the route task is cancelled), the group
                // cancels the remaining children at scope exit and awaits them — a watcher
                // that only exits on the deadline would spin on `Task.yield()` forever.
                while (self.clock.now - start) < budget, !Task.isCancelled {
                    await Task.yield()
                }
                throw ConverseCleanupBudgetExpired()
            }
            for try await text in group {
                // The provider won the race — stop the watcher explicitly, never leaving it
                // spinning at the scope exit.
                group.cancelAll()
                return text
            }
            throw ConverseCleanupBudgetExpired()
        }
        guard let cleaned, !cleaned.isEmpty, !cleaned.allSatisfy(\.isWhitespace) else {
            return transcript.text
        }
        return cleaned
    }

    // MARK: - The reply render

    /// The `.speakReply` application: resolve the synthesizer lazily, render one pass, open the
    /// playback window and feed the reference, then drain the chunks into the playback. The
    /// window stays open — the reply is still sounding, which is what lets the next speech
    /// frame barge in; the barge-in path (or a render/play failure) closes it. A barge-in that
    /// already left `.playing` skips the play — a discarded reply is never played.
    private func renderReply(_ text: String) async {
        let synth: any SpeechSynthesizer
        do {
            if let resolved = synthesizer {
                synth = resolved
            } else {
                let resolved = try await synthesizerProvider()
                synthesizer = resolved
                synth = resolved
            }
        } catch is CancellationError {
            return
        } catch {
            loop.reportPlaybackEnded()
            failureSink(.replyFailed)
            return
        }
        do {
            var chunks: [AudioChunk] = []
            for try await chunk in synth.speak(text) {
                chunks.append(chunk)
            }
            guard loop.state == .playing else { return }
            loop.reportPlaybackStarted()
            for chunk in chunks {
                loop.reportPlaybackChunk(chunk)
            }
            let stream = AsyncThrowingStream<AudioChunk, Error> { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            try await playback.play(stream)
        } catch is CancellationError {
            return
        } catch {
            loop.reportPlaybackEnded()
            failureSink(.replyFailed)
        }
    }
}

/// The cleanup race's deadline — private to this file, the `cleanIfWired` watcher's twin.
private struct ConverseCleanupBudgetExpired: Error {}

/// The effect ledger's box — a final class so the loop's `onEffect` closure can capture it
/// while the driver is still mid-initialization (the `ComposedTurnDriver` shape).
private final class EffectLedgerBox {
    var values: [TurnEffect] = []
}