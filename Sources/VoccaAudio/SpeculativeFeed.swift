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

import OSLog
import VoccaCore

/// **The speculative feed: the ring's mid-session consumer, and the production source of the
/// streaming route's chunks.**
///
/// `speculative-feed` (2026-08-31). While a session is recording, this object drains the ring at
/// a fixed cadence, converts each drain through the *same* ``AudioFormatConverter`` the
/// ``MicrophoneSource`` finishes at `endCapture`, holds the converted samples back until the
/// accumulated buffer passes the engine's minimum, and yields ``AudioBuffer`` chunks into the
/// `AsyncStream` ``chunks`` — the stream
/// ``DictationPipeline/routeStreaming(chunks:target:sessionID:)`` consumes. The router starts it
/// on `.opening` and terminates it on every terminal: on a completed session the *remainder* —
/// the tail `endCapture` drained — is appended as the stream's final chunk, so the engine still
/// receives the whole audio (batch-equivalence). On a cancelled session the stream is finished
/// with nothing appended.
///
/// ## The timer is a closure pair, and why
///
/// The plan named the constructor parameter `timer: any RepeatingTimer` (the `VoccaHotkey`
/// seam). The module rules do not permit `VoccaAudio` to import `VoccaHotkey` (rule 3: an
/// adapter imports `VoccaCore` and no other Vocca module), and `Package.swift` is deliberately
/// untouched by this aspect — so the timer's two operations are injected as the closure pair
/// `schedule`/`unschedule`, which is the ``RepeatingTimer`` seam's minimum surface, and the
/// composition root wires the shipped ``MainRunLoopTimer`` behind them. A feed built with no-op
/// closures is inert: it never drains, and a session routed through it still reaches the engine
/// whole via the remainder — the safe degradation, never a hot mic. The 50 ms cadence is the one
/// constant of the feed's own; a single-source scan pins that it appears nowhere else in
/// `Sources/`.
///
/// ## Where this type runs, and where it does not
///
/// Not annotated `@MainActor`, for the same reason ``MicrophoneSource`` is not: this object is
/// constructed by `MicrophoneSource.init`, whose seam (`SessionAudioSource`) is nonisolated, so
/// the annotation would make the feed unconstructable at its only legitimate construction site.
/// The confinement is a fact about how the feed is *used* — `start`/`terminate`/`cancel` are
/// called by the router in the session domain, and the timer fires on the main run loop (`the
/// ``MainRunLoopTimer`` contract) — and ``tick()`` asserts it with
/// `MainActor.preconditionIsolated`, the ``MainRunLoopTimer`` precedent. That is what keeps the
/// ring's SPSC warrant intact: the feed's tick and `MicrophoneSource.endCapture()` are the
/// consumer role's two occupants, both main-actor, serialized by the actor and by the machine's
/// synchronous `.ended` transition. The tick never touches the realtime thread: drain, convert
/// and yield all run on the main actor, and nothing in a tick takes a lock beyond the ring's own
/// read.
public final class SpeculativeFeed {

    /// **The feed's tick — the one file that names it.** A 50 ms drain cadence: the ring's own
    /// doc sanctions ~10 ms consumer polls, the watchdog's 150 ms is a hot-mic bound and not a
    /// feed cadence, and against a 100 ms-scale pipeline 50 ms is a smooth partial cadence for
    /// a display-only surface. The composition root and the tests consume this constant; the
    /// single-source scan pins it to this file.
    public static let cadence: Duration = .milliseconds(50)

    /// The stream the router routes through `routeStreaming`: one chunk per drain tick (held
    /// back until the sub-minimum predicate releases, then the whole accumulated prefix in the
    /// first chunk), the terminal's remainder as the last chunk, then the stream ends.
    public let chunks: AsyncStream<AudioBuffer>

    private let ring: AudioRingBuffer
    private let converter: AudioFormatConverter
    private let schedule: (Duration, @escaping () -> Void) -> Void
    private let unschedule: () -> Void
    private let cadence: Duration
    private let subMinimum: (@Sendable (Int) -> Bool)?
    private let continuation: AsyncStream<AudioBuffer>.Continuation

    /// Converted samples not yet yielded: the sub-minimum hold. While
    /// ``subMinimum?(pending.count)`` holds, ticks accumulate and yield nothing; the first yield
    /// after the crossing carries the whole accumulated prefix, so the engine still sees every
    /// sample. With a nil predicate (the default) every tick yields immediately — byte-for-byte
    /// "no suppression".
    private var pending: [Float] = []

    /// **The stopped flag the tick consults *before* draining** — "nothing is read while idle",
    /// the ``SessionWatchdog/wake()`` precedent. Set by `terminate`/`cancel` and by the
    /// converter-error path; once set, ticks are no-ops and `start`/`terminate`/`cancel` are
    /// no-ops too — no `AsyncStream` yield ever happens after the stream is finished.
    private var stopped = false

    private let logger = Logger(subsystem: "dev.vocca.Vocca", category: "feed")

    /// - Parameters:
    ///   - ring: the session ring. The feed is the ring's consumer during `.recording`; the
    ///     ownership handover is documented in `AudioRingBuffer`'s warrant, claim 1.
    ///   - converter: the microphone's own converter — the same instance `endCapture` finishes,
    ///     which is what makes the feed's chunks and the remainder one contiguous conversion.
    ///   - schedule: arms the repeating timer — `RepeatingTimer.start(every:_:)`'s operation.
    ///   - unschedule: stops the timer — `RepeatingTimer.stop()`'s operation.
    ///   - cadence: the drain tick; defaults to ``cadence``.
    ///   - subMinimum: the suppression predicate over the accumulated sample count — `true`
    ///     holds the chunk back. `nil` yields every tick.
    public init(
        ring: AudioRingBuffer,
        converter: AudioFormatConverter,
        schedule: @escaping (Duration, @escaping () -> Void) -> Void,
        unschedule: @escaping () -> Void,
        cadence: Duration = SpeculativeFeed.cadence,
        subMinimum: (@Sendable (Int) -> Bool)? = nil
    ) {
        self.ring = ring
        self.converter = converter
        self.schedule = schedule
        self.unschedule = unschedule
        self.cadence = cadence
        self.subMinimum = subMinimum
        (self.chunks, self.continuation) = AsyncStream.makeStream(of: AudioBuffer.self)
    }

    /// Arm the timer: a tick drains the ring, converts the drain, accumulates, and yields a
    /// chunk per tick (or holds below the sub-minimum). A feed that has been terminated or
    /// cancelled is never re-armed — `start` after a terminal is a no-op.
    public func start() {
        guard !stopped else { return }
        logger.info("the feed started")
        schedule(cadence) { [weak self] in
            self?.tick()
        }
    }

    /// Stop the timer and end the stream with the session's audio. Everything accumulated is
    /// flushed **regardless of the sub-minimum** — a sub-minimum whole session still reaches the
    /// engine, whose below-minimum empty answer ends the route `.emptySkip` exactly as today —
    /// then `remainder` (the audio ``MicrophoneSource/endCapture()`` already converted, so no
    /// conversion happens here) is appended as the final chunk. An empty remainder — the feed
    /// just drained everything — is skipped: no empty chunk is ever appended. Idempotent: a
    /// second `terminate` (or a `cancel`, or a `start`) is a no-op.
    public func terminate(with remainder: AudioBuffer?) {
        guard !stopped else { return }
        stopped = true
        unschedule()
        logger.info(
            "the feed stopped; remainder \(remainder?.samples.count ?? 0, privacy: .public) samples")
        if !pending.isEmpty {
            yieldPending()
        }
        if let remainder, !remainder.samples.isEmpty {
            continuation.yield(remainder)
        }
        continuation.finish()
    }

    /// Stop the timer and end the stream with nothing appended — the cancelled session's shape
    /// (the router never routes a cancelled outcome through the streaming route; the stream is
    /// simply closed so no consumer waits on it). Idempotent: a second `cancel` (or a
    /// `terminate`, or a `start`) is a no-op.
    public func cancel() {
        guard !stopped else { return }
        stopped = true
        unschedule()
        logger.info("the feed was cancelled")
        continuation.finish()
    }

    /// One turn of the timer. Asserts the main actor — the timer fires on the main run loop
    /// (the ``MainRunLoopTimer`` contract), and the SPSC warrant's serialized-consumer claim
    /// depends on it. **Consults `stopped` before draining** — a stray fire after the terminal
    /// must not read the ring ("nothing is read while idle"). Empty drains are skipped: no
    /// empty ``AudioBuffer`` is ever yielded.
    func tick() {
        MainActor.preconditionIsolated(
            "A SpeculativeFeed tick ran off the main actor. The timer fires on the main run "
                + "loop, and the ring's SPSC warrant requires the feed's tick and endCapture to "
                + "be serialized by the main actor.")
        guard !stopped else { return }
        let drained = ring.drain()
        guard !drained.isEmpty else { return }
        let converted: [Float]
        do {
            converted = try converter.convert(drained)
        } catch {
            // The one genuinely new failure mode (`speculative-feed` §6): a throw discards the
            // converter's stream state, so the session's audio is no longer continuable. Log
            // loudly, stop draining, and finish the stream — the route completes over whatever
            // audio was already fed. The trap belongs to `endCapture`, the session's last word
            // (`MicrophoneSource.swift:235-243`), where failure still traps unchanged.
            logger.error(
                "the feed's converter threw — the session's stream ends here: \(String(describing: error), privacy: .public)")
            stopped = true
            unschedule()
            continuation.finish()
            return
        }
        if !converted.isEmpty {
            pending.append(contentsOf: converted)
        }
        guard !pending.isEmpty else { return }
        guard subMinimum?(pending.count) != true else { return }
        yieldPending()
    }

    /// Yield the accumulated prefix as one chunk and clear the hold. A chunk is never empty:
    /// `tick` guards before calling, and `terminate` flushes only a non-empty hold.
    private func yieldPending() {
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        continuation.yield(
            AudioBuffer(samples: chunk, sampleRate: AudioBuffer.interchangeSampleRate))
    }
}