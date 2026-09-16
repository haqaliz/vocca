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

/// **The microphone behind the voice loop: the `ContinuousAudioSource` conformance.**
///
/// `streaming-capture` of `turn-taking-barge-in` (C10 — the P3 voice loop). The loop's capture is
/// **continuous, never started at interrupt time**: this type opens the microphone once and yields
/// 16 kHz mono chunks on a 50 ms drain tick until `stop()` — owned separately from the dictation
/// rings, on its own graph (a third graph instance, following the two-graphs precedent of
/// `AppBootstrap`; composed by `barge-in-loop`, never by this type).
///
/// ## One instance, one graph, one ring, one converter, one consumer — by construction
///
/// The constructor takes the graph through ``CaptureGraphSeam`` and builds this type's own
/// ``AudioFormatConverter`` from the graph's `captureFormat` — never a graph rebuild, never a
/// second ring, exactly the ``MicrophoneSource`` allocation shape. The ring's
/// single-producer/single-consumer warrant holds per ring: this ring has its own interleaver (its
/// own producer) and its own consumer, and the consumer role's two occupants — the drain tick and
/// the `stop()` remainder drain — are both main-actor, serialized by the actor. A second `start()`
/// while the first stream is live is refused (``ContinuousAudioSourceError/alreadyStarted``), the
/// API-level refusal that keeps "at most one consumer thread at a time" true for this ring.
///
/// ## Where this type runs, and where it does not
///
/// Not annotated `@MainActor`, for the same reason ``MicrophoneSource`` is not: the seam
/// (`ContinuousAudioSource`) is nonisolated, and the annotation would make the conformance
/// unconstructable at its legitimate construction sites. The confinement is a fact about how it is
/// *used* — `start()`/`stop()` are called by the loop in its domain (and `start()` is **not**
/// called from any realtime thread; the `CaptureStartTiming.whenTheOwnerAsks` discipline is the
/// loop's, documented here so the conformance's caller knows it), and the timer fires on the main
/// run loop — and ``tick()`` asserts it with `MainActor.preconditionIsolated`, the
/// ``SpeculativeFeed`` precedent. That is what keeps the ring's warrant intact: the tick never
/// touches the realtime thread, and nothing in a tick takes a lock beyond the ring's own read.
/// Unlike the graph (executed by nothing in CI), this type is executed for real, driven by a fake
/// graph over a real ring.
///
/// ## `stop()`: release first, then the remainder
///
/// **The device is released first** — `graph.stop()` before anything else, the ``endCapture``
/// ordering, so the refusal counter (producer-written) is stable when the remainder is drained and
/// the return is never a lie about the release. Then the ring's remainder is drained and converted
/// with ``AudioFormatConverter/finish(_:)`` — the resampler's tail flush included — and yielded as
/// the final chunk if non-empty (no empty chunk ever); then the stream finishes, exactly once.
///
/// ## The `endCapture` trap is deliberately not inherited
///
/// `MicrophoneSource.endCapture()` traps on a conversion failure because its return is the
/// machine's "released and done" claim over a transcript that was owed. This stop path owes no
/// hand-over, and the release has already happened — the final-drain conversion cannot leave a hot
/// mic — so a conversion failure here logs loudly and finishes the stream rather than trapping.
///
/// ## The mid-stream converter throw (the one genuinely new failure mode)
///
/// A `convert` throw mid-stream discards the converter's stream state, so the capture is no longer
/// continuable. The answer is the ``SpeculativeFeed`` converter-error path (`SpeculativeFeed.swift:
/// 200-211`) plus the release this type must add because capture does not end at a session
/// boundary: log loudly, **stop the graph (the device is released — never a silent hot mic)**,
/// unschedule, mark stopped, and finish the stream. Not headlessly drivable — the real converter
/// cannot be made to throw in a test, and the plan rejects fabricating an injection seam to fake
/// it; the drivable invariants of the path (every terminal releases the device, streams finish
/// exactly once) are pinned by the stop-path and restart tests.
///
/// ## Missing samples, and the ceiling that does not apply
///
/// The chunks carry `missingSampleCount == 0`: a continuous slice is not a hand-over, so the
/// completeness link has no transcript meaning per chunk — the countable loss lives on
/// ``refusedSampleCount``, the ring's lifetime refusals minus the baseline read at `start()`.
/// And the 120 s ceiling does **not** apply here: it is a dictation-machine fact; the voice loop
/// is unbounded by design (`ARCHITECTURE.md:571`), and this type carries no ceiling logic — the
/// ring's capacity is the loop's composition decision, not this conformance's.
public final class StreamingCapture: ContinuousAudioSource {

    /// **The voice-loop drain tick — the one file that names it.** A 50 ms drain cadence, the
    /// ``SpeculativeFeed`` cadence precedent: against a 100 ms-scale pipeline, 50 ms is a smooth
    /// chunk cadence for the barge-in loop, and the ring's own doc sanctions ~10 ms consumer
    /// polls. The composition root and the tests consume this constant.
    public static let cadence: Duration = .milliseconds(50)

    /// The graph, through the seam. See ``CaptureGraphSeam`` for the release contract: `stop()`
    /// returns only when the device is released, which is what makes this type's stop ordering
    /// sound.
    private let graph: any CaptureGraphSeam

    /// This type's own ring — the graph's ring, one consumer per ring by construction.
    private let ring: AudioRingBuffer

    /// Converts the ring's hardware-rate interleaved samples to the 16 kHz mono interchange
    /// format. Allocated once for the object's lifetime; `beginSession()` resets it per capture.
    private let converter: AudioFormatConverter

    /// The drain timer as the ``RepeatingTimer`` seam's two operations — the closure pair, for
    /// the module rules (`VoccaAudio` may not import `VoccaHotkey`). The composition root wires
    /// the shipped `MainRunLoopTimer` behind the pair.
    private let schedule: (Duration, @escaping () -> Void) -> Void
    private let unschedule: () -> Void

    /// The drain tick; defaults to ``cadence``.
    private let cadence: Duration

    /// The live stream's continuation — `nil` between captures (a stream exists only from
    /// `start()` to `stop()`).
    private var continuation: AsyncStream<AudioBuffer>.Continuation?

    /// Whether capture is open: set true only after `graph.start()` succeeded, set false by
    /// `stop()` and by the converter-error path. The guard that makes `stop()` idempotent, a
    /// second `start()` a refusal, and a stray tick a no-op.
    private var running = false

    /// The ring's refusal counter when the current capture began — the baseline that makes
    /// ``refusedSampleCount`` this capture's loss rather than the ring's lifetime total. Read at
    /// `start()`, before `graph.start()`, while no producer can write.
    private var refusedAtStart = 0

    private let logger = Logger(subsystem: "dev.vocca.Vocca", category: "streaming-capture")

    /// - Parameters:
    ///   - graph: the capture graph, already constructed with its configuration-change callback
    ///     (a device switch mid-capture is the composition root's wiring and the loop's trigger,
    ///     not this type's — the ``MicrophoneSource`` stance).
    ///   - schedule: arms the repeating timer — `RepeatingTimer.start(every:_:)`'s operation.
    ///   - unschedule: stops the timer — `RepeatingTimer.stop()`'s operation.
    ///   - cadence: the drain tick; defaults to ``cadence``.
    /// - Throws: ``AudioFormatConversionError`` if the graph's format cannot be converted to the
    ///   interchange format.
    public init(
        graph: any CaptureGraphSeam,
        schedule: @escaping (Duration, @escaping () -> Void) -> Void,
        unschedule: @escaping () -> Void,
        cadence: Duration = StreamingCapture.cadence
    ) throws {
        self.graph = graph
        self.ring = graph.ring
        self.converter = try AudioFormatConverter(inputFormat: graph.captureFormat)
        self.schedule = schedule
        self.unschedule = unschedule
        self.cadence = cadence
    }

    /// Open the microphone and return the chunk stream.
    ///
    /// The order is load-bearing, mirroring ``MicrophoneSource/beginCapture()``: the refusal
    /// baseline is read and ``AudioFormatConverter/beginSession()`` runs **before** `graph.start()`
    /// — the reset anchors at the start that cannot be skipped, and a converter left holding the
    /// previous capture's state would emit that audio ahead of this one's (the measured
    /// stale-converter defect). If the graph refuses to open, `start()` throws
    /// ``ContinuousAudioSourceError/unavailable`` and nothing has happened: nothing is scheduled,
    /// this type is not running, and no stream exists. Only after the open succeeds is the stream
    /// created, `running` set, and the tick scheduled.
    ///
    /// A second `start()` while running throws ``ContinuousAudioSourceError/alreadyStarted`` and
    /// changes nothing — the first stream stays live.
    public func start() throws -> AsyncStream<AudioBuffer> {
        guard !running else {
            throw ContinuousAudioSourceError.alreadyStarted
        }
        refusedAtStart = ring.refusedSampleCount
        converter.beginSession()
        do {
            try graph.start()
        } catch {
            throw ContinuousAudioSourceError.unavailable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioBuffer.self)
        self.continuation = continuation
        running = true
        schedule(cadence) { [weak self] in
            self?.tick()
        }
        return stream
    }

    /// Close the microphone and end the stream.
    ///
    /// Idempotent, and a no-op before any `start()`. **Order: the device is released first** —
    /// `graph.stop()` before anything else, so the refusal counter (producer-written) is stable
    /// when the remainder is drained — then `running = false`, the tick is unscheduled, the
    /// ring's remainder is drained and converted with `finish` (the resampler's tail flush
    /// included), and the converted remainder is yielded as the final chunk if non-empty — no
    /// empty chunk ever — before the stream finishes, **exactly once**.
    ///
    /// The final-drain conversion cannot fail the release (the release already happened), and no
    /// hand-over is owed, so a conversion failure here logs loudly and finishes the stream — the
    /// ``endCapture`` trap is deliberately not inherited.
    public func stop() {
        guard running else { return }
        graph.stop()
        running = false
        unschedule()
        let raw = ring.drain()
        let converted: [Float]
        do {
            converted = try converter.finish(raw)
        } catch {
            logger.error(
                "the streaming-capture stop path could not convert the remainder — the stream ends here: \(String(describing: error), privacy: .public)")
            continuation?.finish()
            continuation = nil
            return
        }
        if !converted.isEmpty {
            continuation?.yield(
                AudioBuffer(samples: converted, sampleRate: AudioBuffer.interchangeSampleRate))
        }
        continuation?.finish()
        continuation = nil
    }

    /// **The countable loss over the capture life**, baseline-subtracted: the ring's lifetime
    /// refusals minus the value read at `start()` — this capture's loss, never the ring's total.
    /// The chunks themselves carry `missingSampleCount == 0` (a continuous slice is not a
    /// hand-over); this is where the loss is counted.
    public var refusedSampleCount: Int {
        ring.refusedSampleCount - refusedAtStart
    }

    /// One turn of the timer. Asserts the main actor — the timer fires on the main run loop, and
    /// the ring's single-consumer discipline depends on it. **Consults `running` before draining**
    /// — a stray fire after the terminal must not read the ring. Empty drains are skipped: no
    /// empty ``AudioBuffer`` is ever yielded.
    ///
    /// A converter throw here ends the capture: log loudly, **stop the graph — the device is
    /// released, never a silent hot mic** — unschedule, mark stopped, and finish the stream. See
    /// this type's header for why.
    func tick() {
        MainActor.preconditionIsolated(
            "A StreamingCapture tick ran off the main actor. The timer fires on the main run "
                + "loop, and the ring's single-consumer discipline requires the tick and the stop "
                + "remainder drain to be serialized by the main actor.")
        guard running else { return }
        let drained = ring.drain()
        guard !drained.isEmpty else { return }
        let converted: [Float]
        do {
            converted = try converter.convert(drained)
        } catch {
            logger.error(
                "the streaming-capture converter threw — capture ends here and the device is released: \(String(describing: error), privacy: .public)")
            graph.stop()
            unschedule()
            running = false
            continuation?.finish()
            continuation = nil
            return
        }
        if !converted.isEmpty {
            continuation?.yield(
                AudioBuffer(samples: converted, sampleRate: AudioBuffer.interchangeSampleRate))
        }
    }
}