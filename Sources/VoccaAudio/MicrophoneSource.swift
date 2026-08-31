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

/// The engine half of a capture session, as ``MicrophoneSource`` is permitted to know it.
///
/// The one AVFoundation file in this aspect — ``AudioCaptureGraph`` — is executed by nothing in
/// CI: no hosted runner has a microphone, and `AVAudioSinkNode` has no offline equivalent. Its
/// decisions were lifted above it in Phase 4, and this protocol is the same move one level up:
/// ``MicrophoneSource`` is written against *this* surface, so a test drives the real conformance
/// end to end with a fake graph in the engine's place — the ring and the converter in the path
/// are real. Naming this protocol is what keeps the conformance out of the one file that may
/// import AVFoundation; the expected-importer set that bounds that import is unchanged.
///
/// ## The release contract, which is why `stop()` is on the seam
///
/// ``SessionAudioSource/endCapture()`` must not return until the input device is released. The
/// conformance discharges that by calling ``stop()`` *first*, before it reads anything back, and
/// by relying on one documented property of this seam: **`stop()` returns only when the device is
/// released**. `AVAudioEngine.stop()` is synchronous and non-throwing, so on the shipped graph
/// that property holds and the release cannot fail — which is the whole reason the conformance's
/// trap clause covers only the conversion (see ``MicrophoneSource``).
public protocol CaptureGraphSeam: AnyObject {
    /// Where the realtime producer writes. **The consumer role is handed over mid-session**
    /// (`speculative-feed`): the ``MicrophoneSource``'s own feed owns it while the session is
    /// recording — draining at the feed's cadence — and the conformance takes it back at
    /// ``MicrophoneSource/endCapture()``, which drains the *remainder* and reads
    /// ``AudioRingBuffer/refusedSampleCount`` from it. Both consumers are main-actor, so the
    /// handover is serialized; see `AudioRingBuffer`'s warrant, claim 1.
    var ring: AudioRingBuffer { get }

    /// What is actually in the ring, as a claim the rest of the package reads. The conformance
    /// builds its converter from this, so the converter's input format can never disagree with
    /// the graph's.
    var captureFormat: CapturedAudioFormat { get }

    /// The newest published input level, 0...1 — the widget's level source
    /// (`MicrophoneLevelSource`) reads it on the main actor. The realtime callback publishes it
    /// (`AudioBufferListInterleaver`'s atomic, `widget-live-states` Task 4); a stopped graph stops
    /// publishing, which is why ``isRunning`` sits on this seam too.
    var levelPeak: Float { get }

    /// Whether the engine is running — the graph's own answer, read off the engine rather than
    /// remembered (`AudioCaptureGraph.isRunning`). The level source reads it so `latestLevel()`
    /// answers 0 the moment the graph stops or is idle: a session's end closes the microphone,
    /// and a level left over from it would be a ghost the waveform draws.
    var isRunning: Bool { get }

    /// Open the microphone. May be slow; throws when the device refuses — the machine maps that
    /// to ``CaptureStart/unavailable``.
    func start() throws

    /// Close the microphone, **and do not return until it is closed.** See this protocol's
    /// header for why the conformance's whole release obligation rests on this line.
    func stop()
}

extension AudioCaptureGraph: CaptureGraphSeam {}

/// **The microphone behind a session: the `SessionAudioSource` conformance.**
///
/// The seam the session machine has carried since `session-lifecycle`, made real. It owns the
/// capture graph and the format converter for their whole lives — never a graph rebuild per
/// press — and hands each session's audio to custody as ``AudioBuffer``, the ASR seam's own type.
///
/// ## The obligations this type exists to discharge (Phase 5, `plan_20260806.md`)
///
/// ### 1. The refusal count is read, and travels
///
/// ``AudioRingBuffer``'s overrun policy is drop-newest, and the entire reason that is acceptable
/// for a product whose invariant is *a transcript is never lost* is that the loss is **countable**:
/// `refusedSampleCount` says exactly how many samples the ring would not take. `endCapture()`
/// reads it and carries it on the hand-over as ``AudioBuffer/missingSampleCount`` — the
/// completeness link the ASR seam was built to receive — so a short session can never masquerade
/// as complete downstream. That is the C1→C2 bridge the asr seam recorded as gated on this merge.
///
/// **The carried number equals the ring's `refusedSampleCount`, verbatim** (the plan's RED), and
/// it is *this session's* refusals, not the ring's lifetime total: the ring's counter is
/// cumulative since creation, so the conformance reads a baseline at ``beginCapture()`` — before
/// `start()`, while no producer can be writing — and subtracts it from the final reading. A
/// session that refused nothing hands over audio marked complete even after an earlier session
/// overran; the three-clause RED is what pins that. The units are the ring's own: raw samples,
/// interleaved, at the hardware rate. Rescaling them into 16 kHz frames is a presentation choice
/// nobody owns yet and this phase deliberately does not invent one.
///
/// ### 2. `endCapture()` releases the device before it returns, and failure is loud
///
/// `endCapture()` is non-failable, and the machine goes `.idle` on its return — from that instant
/// the widget shows idle over whatever is actually happening, and nothing in this aspect ever
/// looks again. So the order is load-bearing: **`stop()` first** (the device is released, and the
/// refusal counter — producer-written — becomes stable), *then* drain, convert, and build the
/// hand-over. And the trap clause, documented here because the plan makes it this type's
/// obligation: **a conformance that can fail here must trap rather than return.** The only step
/// that can fail is the conversion (`AVAudioConverter` allocation or status), and `endCapture()`
/// has exactly one way to communicate — a return that claims "released, and here is the audio" —
/// so on a conversion failure it traps rather than lie. The release itself cannot fail:
/// ``CaptureGraphSeam/stop()`` is synchronous and non-throwing on the shipped graph, which is
/// what confines the trap to the conversion.
///
/// ### 3. The hand-over is the interchange format, by construction
///
/// `endCapture()` returns ``AudioBuffer``, whose initializer traps on anything other than
/// 16 kHz mono — the A8 regression is loud by construction — and the converter asserts the
/// format AVFoundation actually built before it converts a single sample.
///
/// ## Exactly once per session, and the machine as guarantor
///
/// The seam is called at most once per session and never while open; the machine's single custody
/// funnel is what guarantees it, from every one of its terminal paths. The converter's
/// ``AudioFormatConverter/beginSession()`` — the reset that keeps one session's audio from
/// reaching another's transcript — is anchored here, at the one point in a session's life that
/// cannot be skipped.
///
/// ## The remainder contract (`speculative-feed`, 2026-08-31)
///
/// `endCapture()` no longer drains the ring *whole*: since the feed landed, a mid-session
/// consumer (the ``feed``) has already drained part of it on its 50 ms tick. This method drains
/// the **rest** — exactly once, as the machine's funnel runs it synchronously at every terminal —
/// and the conversion is **contiguous with the feed's** because it is the same
/// ``AudioFormatConverter`` instance, chunked through `convert` during the session and finished
/// here. The refused-count bookkeeping is unchanged in meaning: the carried
/// ``AudioBuffer/missingSampleCount`` is still this session's refusals, baseline-subtracted —
/// a mid-session consumer changes what is in the ring, not what the hand-over must report.
///
/// ## Where this type runs, and where it does not
///
/// It names no AVFoundation type — everything below it is ``CaptureGraphSeam`` or Vocca's own
/// types — so unlike the graph itself it is executed by CI, driven by a fake graph over a real
/// ring. The session domain is the machine's; like the graph, this type belongs to it (the
/// `@MainActor` domain in the app) and is not `Sendable`.
public final class MicrophoneSource: SessionAudioSource {
    public typealias Buffer = AudioBuffer

    /// The graph, through the seam. See ``CaptureGraphSeam`` for the release contract.
    private let graph: any CaptureGraphSeam

    /// Converts the ring's hardware-rate interleaved samples to the 16 kHz mono interchange
    /// format. Allocated once for the object's lifetime; `beginSession()` resets it per session.
    private let converter: AudioFormatConverter

    /// The ring's refusal counter when the current session began — the baseline that makes the
    /// hand-over carry *this session's* refusals rather than the ring's lifetime total. Read at
    /// ``beginCapture()``, before ``CaptureGraphSeam/start()``, while no producer can write.
    private var refusedAtSessionStart = 0

    /// The latency ledger's seam, wired by the composition root — `nil` (the default) keeps
    /// `endCapture()` exactly as it was before the loop-wiring phase: no span is measured,
    /// nothing is recorded.
    private let recorder: (any LatencyRecorder)?

    /// The injected clock the capture-close span is measured with (the ``MonotonicClock``
    /// contract — this type reads no clock of its own); `nil` (the default) with the same
    /// absence effect as a nil recorder.
    private let clock: (any MonotonicClock)?

    /// Where the in-flight session's record id comes from at `endCapture()` — the router's
    /// ``LatencySessionBox`` at ship, a fixed id in a test. `nil` (the default) means no
    /// recording.
    private let sessionIDProvider: (@Sendable () -> SessionRecord.ID?)?

    /// - Parameter graph: the capture graph, already constructed with its configuration-change
    ///   callback (a device switch mid-session is the machine's trigger, not this type's).
    /// - Parameter recorder: the latency ledger's seam, `nil` by default — the loop-wiring
    ///   wiring decision, and the W3 absence pin.
    /// - Parameter clock: the injected clock the capture-close span is measured with, `nil` by
    ///   default with the same absence effect.
    /// - Parameter sessionIDProvider: where the in-flight session's record id comes from at
    ///   `endCapture()`, `nil` by default.
    /// - Throws: ``AudioFormatConversionError`` if the graph's format cannot be converted to the
    ///   interchange format.
    public init(
        graph: any CaptureGraphSeam,
        recorder: (any LatencyRecorder)? = nil,
        clock: (any MonotonicClock)? = nil,
        sessionIDProvider: (@Sendable () -> SessionRecord.ID?)? = nil
    ) throws {
        self.graph = graph
        self.converter = try AudioFormatConverter(inputFormat: graph.captureFormat)
        self.recorder = recorder
        self.clock = clock
        self.sessionIDProvider = sessionIDProvider
    }

    /// Open the microphone.
    ///
    /// The reset happens before the open, on every session: it is the one point in a session's
    /// life that cannot be skipped, and a converter left holding a previous session's filter
    /// state would emit that session's audio ahead of this one's. `start()` may take ~114 ms and
    /// may throw — the machine handles both, and this method may not return before the microphone
    /// is actually open, because the machine takes the return as the open.
    public func beginCapture() -> CaptureStart {
        refusedAtSessionStart = graph.ring.refusedSampleCount
        converter.beginSession()
        do {
            try graph.start()
            return .opened
        } catch {
            return .unavailable
        }
    }

    /// Close the microphone and hand over what was captured, as 16 kHz mono with the completeness
    /// link attached. See this type's header for the ordering and the trap clause.
    ///
    /// - **The device is released first.** `stop()` is synchronous and returns only once the
    ///   input is closed — see ``CaptureGraphSeam`` — and it must come before any read-back, both
    ///   so that the return is never a lie about the release and so that the refusal counter is
    ///   stable when it is read.
    /// - **Then the ring's *remainder* is drained and converted** — the ``feed`` has already
    ///   drained the ring's readable half on its ticks while the session was recording, so this
    ///   drain takes the rest, exactly once, and the conversion is contiguous with the feed's
    ///   because it is the same converter (`finish` flushes the resampler's tail).
    /// - **A failure anywhere in the conversion traps** (``preconditionFailure``): `endCapture()`
    ///   cannot report it, and a return would be the machine's "released and done" signal over
    ///   audio that was never produced.
    public func endCapture() -> AudioBuffer {
        // The capture-close span: measured on **this side of `stop()`** — the caller's side,
        // never inside the graph's realtime callback — as the delta between two reads of the
        // injected clock, and recorded only after the device is released (spec W3: the span
        // closes on the stop path).
        let stopStart = clock?.now
        graph.stop()
        if let recorder, let clock, let start = stopStart, let sessionID = sessionIDProvider?() {
            let elapsed = clock.now - start
            // The ledger is an actor and `endCapture()` is synchronous (the machine's funnel),
            // so the already-measured span is handed over in a task on the main actor — the stop
            // path runs in the machine's domain, and main-actor FIFO lands the span before the
            // `.ended` route finalizes the record.
            Task { @MainActor in
                _ = await recorder.recordSpan(
                    LatencySpan.recorded(name: .captureClose, elapsed: elapsed), for: sessionID)
            }
        }

        let raw = graph.ring.drain()

        let converted: [Float]
        do {
            converted = try converter.finish(raw)
        } catch {
            preconditionFailure(
                """
                endCapture() failed to convert the captured audio: \(error). endCapture() cannot \
                report failure — the machine takes its return as "the device is released and the \
                session is done" — so it must trap rather than claim completion over audio that \
                was never produced (plan_20260806.md, Phase 5: "make failure loud").
                """)
        }

        return AudioBuffer(
            samples: converted,
            sampleRate: AudioBuffer.interchangeSampleRate,
            missingSampleCount: graph.ring.refusedSampleCount - refusedAtSessionStart)
    }
}
