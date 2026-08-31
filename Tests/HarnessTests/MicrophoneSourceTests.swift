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

@testable import VoccaAudio

/// **The `SessionAudioSource` conformance over the capture graph — driven with a fake graph and a
/// real ring.**
///
/// This is Phase 5 of `audio-capture`, and its RED is the plan's three clauses, verbatim
/// (`plan_20260806.md` §Phase 5):
///
/// > a source whose ring refused samples hands over audio marked incomplete **and the number it
/// > carries equals the ring's `refusedSampleCount`**; a source that refused none hands over audio
/// > marked complete. All three clauses, because a one-bit flag satisfies "marked incomplete"
/// > exactly as written and throws away N — and *countable*, not merely *flagged*, is the entire
/// > justification for drop-newest. The negative case is there because "always incomplete" passes
/// > a one-sided test.
///
/// The conformance is written against ``CaptureGraphSeam`` — a protocol over `AudioCaptureGraph` —
/// precisely so that this file can execute it. The graph's own file is the one place
/// AVFoundation may be named and is executed by nothing in CI; the conformance names no
/// AVFoundation type, takes the graph through the seam, and so runs here for real, with a fake
/// graph in the engine's place and the **real** ring and the **real** converter in the path. The
/// fake graph is a ledger — "the device was released" is read off `stopCalls`, never off a
/// believed call, the way `project-skeleton`'s review demanded of every custody claim.
///
/// ## What the three clauses require of the design, and the tests that pin each
///
/// - **Clause 1 (refused → incomplete with the exact number)**:
///   ``testARingThatRefusedSamplesHandsOverAudioMarkedIncompleteWithTheExactCount``, and its
///   multi-channel form ``testARefusedBlockIsCarriedVerbatimInTheRingsOwnUnits``.
/// - **Clause 2 (the number is the count, not a flag)** is the *same* assertion — `missingSampleCount`
///   must equal the ring's counter, which a one-bit flag cannot.
/// - **Clause 3 (refused none → complete)**:
///   ``testARingThatRefusedNothingHandsOverAudioMarkedComplete`` — the negative case that fails an
///   "always incomplete" implementation — and its cross-session form
///   ``testRefusalsInOneSessionNeverMarkTheNextSessionIncomplete``, which pins that the count
///   carried is **this session's** refusal count and not the ring's lifetime total (the ring's
///   counter is cumulative since creation, so a naive pass-through marks every later session
///   incomplete after the first overrun).
final class MicrophoneSourceTests: XCTestCase {

    // MARK: - The three clauses, verbatim

    /// **Clause 1 + 2.** A ring that refused samples hands over audio that is short by exactly
    /// that many — the count, not a flag.
    func testARingThatRefusedSamplesHandsOverAudioMarkedIncompleteWithTheExactCount() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)

        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)
        write([100, 101], to: graph.ring)
        XCTAssertEqual(graph.ring.refusedSampleCount, 2, "precondition: the second block was refused")

        let buffer = source.endCapture()

        XCTAssertEqual(
            buffer.missingSampleCount, 2,
            """
            The ring refused two samples and the hand-over must carry exactly that number — a count \
            that only says "incomplete" throws away N, which is the entire justification for \
            drop-newest being acceptable at all.
            """)
        XCTAssertEqual(buffer.samples, [0, 1, 2, 3, 4, 5, 6, 7], "the audio itself must be untouched")
        XCTAssertEqual(graph.stopCalls, 1, "the device must be released before the hand-over returns")
        XCTAssertFalse(graph.isRunning)
    }

    /// **Clause 3, the negative case.** A ring that refused nothing hands over audio marked
    /// complete — an implementation that marks everything incomplete passes the one-sided test
    /// and fails here.
    func testARingThatRefusedNothingHandsOverAudioMarkedComplete() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)

        let buffer = source.endCapture()

        XCTAssertEqual(graph.ring.refusedSampleCount, 0, "precondition: nothing was refused")
        XCTAssertEqual(buffer.missingSampleCount, 0)
        XCTAssertEqual(buffer.samples, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(buffer.sampleRate, AudioBuffer.interchangeSampleRate)
    }

    /// **Clause 3, across sessions.** The ring's refusal counter is cumulative since the ring was
    /// created, so a conformance that reads it once at `endCapture()` marks *every later* session
    /// incomplete after the first overrun. The hand-over must carry **this session's** refusals.
    func testRefusalsInOneSessionNeverMarkTheNextSessionIncomplete() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)
        write([100, 101], to: graph.ring)
        XCTAssertEqual(graph.ring.refusedSampleCount, 2)
        XCTAssertEqual(source.endCapture().missingSampleCount, 2, "the short session reports short")

        XCTAssertEqual(source.beginCapture(), .opened)
        write([200, 201, 202, 203], to: graph.ring)
        let second = source.endCapture()

        XCTAssertEqual(
            second.missingSampleCount, 0,
            """
            The second session refused nothing and must hand over audio marked complete. The ring's \
            counter still says 2 — a hand-over built from the lifetime total would fail this clause.
            """)
        XCTAssertEqual(second.samples, [200, 201, 202, 203])
    }

    // MARK: - The rest of the seam's contract

    /// An empty press is a legitimate answer (`SessionAudioSource.endCapture()`), and it is
    /// **complete** — nothing was captured, so nothing was lost.
    func testAnEmptyPressHandsOverAnEmptyCompleteBuffer() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        let buffer = source.endCapture()

        XCTAssertTrue(buffer.samples.isEmpty)
        XCTAssertEqual(buffer.missingSampleCount, 0)
        XCTAssertEqual(graph.stopCalls, 1)
    }

    /// `AVAudioEngine.start()` can throw, and a session that believes it is recording while
    /// nothing is captured is a lie. The conformance maps it to `.unavailable` and touches nothing
    /// else — no stop is owed for an open that never happened.
    func testAnEngineThatRefusesToStartIsUnavailableAndStaysClosed() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        graph.nextStart = .failure(StartRefused())
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .unavailable)
        XCTAssertEqual(graph.startAttempts, 1)
        XCTAssertFalse(graph.isRunning)
        XCTAssertEqual(graph.stopCalls, 0, "a start that failed owes no teardown")
    }

    // MARK: - A8 at the seam boundary

    /// **A8.** The seam boundary is 16 kHz mono Float32. A 48 kHz **stereo** capture — the ordinary
    /// built-in-input case — must arrive at the other side as 16 kHz mono, and the assertion that
    /// reads the rate off the *data* is the sample count: one second in, 16 000 samples out.
    func testTheHandOverAtTheSeamBoundaryIsExactlyTheInterchangeFormat() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 1 << 17),
            captureFormat: CapturedAudioFormat(sampleRate: 48_000, channelCount: 2))
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        write(Array(repeating: 0.5, count: 96_000), to: graph.ring)

        let buffer = source.endCapture()

        XCTAssertTrue(
            AudioBuffer.isValidFormat(sampleRate: buffer.sampleRate, channelCount: 1),
            "the hand-over must be exactly 16 kHz mono: got \(buffer.sampleRate) Hz")
        XCTAssertEqual(buffer.sampleRate, AudioBuffer.interchangeSampleRate)
        XCTAssertEqual(
            buffer.samples.count, 16_000,
            """
            one second at 48 kHz stereo must arrive as 16 000 mono frames — a rate or channel \
            regression changes this number and nothing else
            """)
        XCTAssertEqual(buffer.missingSampleCount, 0)
    }

    /// **The plan's clause 1, verbatim, at a non-trivial rate.** The number the hand-over carries
    /// *equals the ring's `refusedSampleCount`* — in the ring's own units, raw interleaved samples
    /// at the hardware rate. At 48 kHz stereo the ring counts 96 000 samples per second, and a
    /// refused block travels as that many raw samples, not a rescaling nobody has defined.
    func testARefusedBlockIsCarriedVerbatimInTheRingsOwnUnits() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 1 << 17),
            captureFormat: CapturedAudioFormat(sampleRate: 48_000, channelCount: 2))
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)
        write(Array(repeating: 0.5, count: 96_000), to: graph.ring)
        // A block larger than the remaining room: refused whole, so the drain still yields exactly
        // the 96 000 accepted samples — and the refused count is the block's own.
        write(Array(repeating: 0.25, count: 1 << 17), to: graph.ring)
        XCTAssertEqual(
            graph.ring.refusedSampleCount, 1 << 17, "precondition: the second block was refused")

        let buffer = source.endCapture()

        XCTAssertEqual(
            buffer.missingSampleCount, graph.ring.refusedSampleCount,
            "the plan's clause 1: the carried number equals the ring's counter, verbatim")
        XCTAssertEqual(buffer.samples.count, 16_000)
    }

    // MARK: - The machine holds it

    /// **The seam's own point, end to end:** `SessionMachine` holds this conformance as its
    /// `SessionAudioSource`, the hand-over it produces travels out of the machine's single custody
    /// funnel as a `VoccaCore.AudioBuffer` — the ASR seam's buffer, completeness link included —
    /// and the device is released before the machine goes `.idle`. This is the C1→C2 bridge the
    /// C2 seam recorded as gated on this merge.
    func testASessionThroughTheRealMachineCarriesTheCompletenessCountAndReleasesTheDevice() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)
        let machine = SessionMachine(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: TestClock(),
            audioSource: source)

        XCTAssertEqual(machine.observe(Self.keyEvent(.keyDown, at: .zero)).effect, .started)
        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)
        write([100, 101], to: graph.ring)

        let audio = try Self.endedAudio(
            machine.observe(Self.keyEvent(.keyUp, at: .zero)).effect)

        XCTAssertEqual(audio.missingSampleCount, 2)
        XCTAssertEqual(audio.samples, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(audio.sampleRate, AudioBuffer.interchangeSampleRate)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(graph.stopCalls, 1, "the machine's funnel must have released the device")
        XCTAssertFalse(graph.isRunning, "the machine went idle over a live microphone")
    }

    // MARK: - The mid-session consumer contract (speculative-feed phase (a))

    /// **The remainder contract, pinned before the feed exists.** The speculative feed's role,
    /// played by hand: a consumer drains part of the ring mid-"session", then `endCapture()` —
    /// the conformance must hand over exactly the *unconsumed* remainder, drained exactly once,
    /// with the refusal bookkeeping unchanged in meaning (this session's refusals,
    /// baseline-subtracted, exactly as the three-clause RED pins).
    ///
    /// This is green against today's implementation (a drain followed by `endCapture` has
    /// always left the remainder), and that is the point of the pin: it freezes the contract
    /// the feed will be built against — the ownership change is deliberate, documented in the
    /// same commit, and tested before the consumer that will actually drain mid-session exists.
    func testAMidSessionConsumerDrainLeavesEndCaptureTheExactRemainderDrainedOnce() throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 16), captureFormat: .interchange)
        let source = try MicrophoneSource(graph: graph)

        XCTAssertEqual(source.beginCapture(), .opened)

        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)
        // The feed's role: drain what is readable mid-session.
        XCTAssertEqual(graph.ring.drain(), [0, 1, 2, 3, 4, 5, 6, 7])
        // The session continues after the mid-session drain — the producer writes a full ring
        // and then one block too many, so the session's refusal count is non-zero.
        write(Array(100..<116).map(Float.init), to: graph.ring)
        write([200, 201], to: graph.ring)
        XCTAssertEqual(graph.ring.refusedSampleCount, 2, "precondition: the third block was refused")

        let buffer = source.endCapture()

        XCTAssertEqual(
            buffer.samples, Array(100..<116).map(Float.init),
            """
            The unconsumed remainder, and only it: the mid-session drain already took the first \
            half, so the hand-over must not re-serve it and must not miss the tail.
            """)
        XCTAssertEqual(
            buffer.missingSampleCount, 2,
            """
            The refusal bookkeeping is unchanged in meaning: the carried number is still this \
            session's refusals, baseline-subtracted — a mid-session consumer changes what is in \
            the ring, not what the hand-over must report.
            """)
        XCTAssertEqual(
            graph.ring.drain(), [],
            "the remainder is drained exactly once — a second endCapture-style drain finds nothing")
    }

    // MARK: - The feed's ownership (speculative-feed phase (b))

    /// **The real ownership behavior** — the phase (a) contract test, now with the actual feed:
    /// the feed drains two ticks through a real ring, `endCapture()` hands over exactly the
    /// unconsumed tail, the completeness bookkeeping is unchanged in meaning (the session's
    /// refusals, baseline-subtracted), and the stream plus the remainder concatenate to the
    /// whole audio — the batch-equivalence precondition the end-to-end final relies on.
    @MainActor
    func testEndCaptureWithTheLiveFeedHandsOverTheExactRemainderAndTheWholeAudio() async throws {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 16), captureFormat: .interchange)
        let timer = FakeTimer()
        let source = try MicrophoneSource(
            graph: graph,
            feedSchedule: (schedule: { timer.start(every: $0, $1) }, unschedule: { timer.stop() }))

        XCTAssertEqual(source.beginCapture(), .opened)
        source.feed.start()

        write(Array(1...8).map(Float.init), to: graph.ring)
        timer.tick()
        write(Array(9...16).map(Float.init), to: graph.ring)
        timer.tick()
        // The tail: written after the last tick, so it is the unconsumed remainder — and a block
        // too many, so the session's refusal count is non-zero.
        write(Array(17...32).map(Float.init), to: graph.ring)
        write([99, 100], to: graph.ring)
        XCTAssertEqual(graph.ring.refusedSampleCount, 2, "precondition: the final block was refused")

        let buffer = source.endCapture()
        source.feed.terminate(with: buffer)

        XCTAssertEqual(
            buffer.samples, Array(17...32).map(Float.init),
            "the unconsumed tail, and only it — the feed already drained the first two blocks")
        XCTAssertEqual(
            buffer.missingSampleCount, 2,
            "the completeness bookkeeping is unchanged in meaning — the session's refusals, "
                + "baseline-subtracted, exactly as without a mid-session consumer")
        let chunks = await Self.collect(source.feed.chunks)
        XCTAssertEqual(
            chunks.flatMap(\.samples), Array(1...32).map(Float.init),
            """
            The feed's stream — the drained chunks plus the terminate-appended remainder — \
            concatenates to the whole audio: batch-equivalence at the ownership seam, the \
            precondition the end-to-end "final equals the batch result for the same audio" \
            acceptance rests on.
            """)
        XCTAssertEqual(
            chunks.last?.samples, buffer.samples,
            "the endCapture remainder is the stream's last chunk — the engine receives the "
                + "whole audio, in order")
    }

    // MARK: - W3: capture-close measured on the stop path (loop-wiring Phase 2)

    /// **W3.** With an injected recorder, a hand-moved clock and a fixed id (minted via
    /// `beginSession`), `endCapture()` records a `captureClose` span whose elapsed **equals the
    /// fake graph's stop duration** — the span closes on the stop path, after `stop()` returns,
    /// never on the realtime thread (spec "Isolation decisions"). The fake graph makes `stop()`
    /// take a measurable time by advancing the injected clock, so the delta is exact.
    @MainActor
    func testEndCaptureRecordsTheCaptureCloseSpanWithExactlyTheStopPathDelta() async throws {
        let clock = TestClock()
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange,
            stopClock: clock, stopAdvance: .milliseconds(7))
        let recorder = LatencyLedger()
        let id = await recorder.beginSession()
        let source = try MicrophoneSource(
            graph: graph, recorder: recorder, clock: clock,
            sessionIDProvider: { id })

        _ = source.endCapture()
        // A main-actor barrier enqueued *after* the span's hand-over task: the main actor runs
        // them in enqueue order, so when the barrier completes the span has been handed to the
        // ledger — and the finalize below is ordered after it. (A bare `Task.yield()` is a
        // scheduling hint, not a barrier — this ordering must not depend on one.)
        await Task { @MainActor in }.value
        let finalized = await recorder.finalize(id: id, outcome: .aborted, engine: nil)
        XCTAssertTrue(
            finalized,
            "the finalize must be accepted — the span was recorded while the session was in flight")

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(
            snapshot[0].spans,
            [LatencySpan.recorded(name: .captureClose, elapsed: .milliseconds(7))],
            "the capture-close span must carry exactly the measured stop-path delta — never a "
                + "fabricated zero")
        XCTAssertEqual(graph.stopCalls, 1, "the span is recorded because the device was released")
    }

    /// **W3, the absence pin.** A source built with the defaulted recorder (`nil`) records
    /// nothing: the same endCapture, the same graph work, and the ledger's record carries no
    /// spans — `endCapture` is exactly what it was before the loop-wiring phase.
    @MainActor
    func testEndCaptureWithoutARecorderRecordsNothing() async throws {
        let clock = TestClock()
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange,
            stopClock: clock, stopAdvance: .milliseconds(7))
        let recorder = LatencyLedger()
        let id = await recorder.beginSession()
        let source = try MicrophoneSource(
            graph: graph, clock: clock, sessionIDProvider: { id })

        _ = source.endCapture()
        await Task { @MainActor in }.value
        let finalized = await recorder.finalize(id: id, outcome: .aborted, engine: nil)
        XCTAssertTrue(finalized)

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(
            snapshot[0].spans, [],
            "no recorder — the capture-close span is neither measured nor recorded")
        XCTAssertEqual(graph.stopCalls, 1, "the absence is about recording, not about the release")
    }

    /// **W3, the other absence pin.** The recorder is present, but the provider answers `nil` —
    /// no session began (the router never wrote the box) — so nothing is recorded. A session that
    /// never began must not fabricate a span under a record that was never minted.
    @MainActor
    func testEndCaptureWithAProviderAnsweringNilRecordsNothing() async throws {
        let clock = TestClock()
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 8), captureFormat: .interchange,
            stopClock: clock, stopAdvance: .milliseconds(7))
        let recorder = LatencyLedger()
        let id = await recorder.beginSession()
        let source = try MicrophoneSource(
            graph: graph, recorder: recorder, clock: clock,
            sessionIDProvider: { nil })

        _ = source.endCapture()
        await Task { @MainActor in }.value
        let finalized = await recorder.finalize(id: id, outcome: .aborted, engine: nil)
        XCTAssertTrue(finalized)

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(
            snapshot[0].spans, [],
            "a nil session id — nothing recorded, even with the recorder wired")
    }

    // MARK: - Helpers

    /// The graph, as a **ledger**. It uses a real `AudioRingBuffer`, because the conformance's
    /// end-to-end path — drain, convert, counter — is only real if the ring is; and it records
    /// every start and stop so that custody is asserted off the ledger, never off a believed call.
    private final class FakeCaptureGraph: CaptureGraphSeam {
        let ring: AudioRingBuffer
        let captureFormat: CapturedAudioFormat
        private(set) var startAttempts = 0
        private(set) var stopCalls = 0
        private(set) var isRunning = false
        /// The level surface the seam now carries (`MicrophoneLevelSource` reads it): a fixed 0 in
        /// this ledger — the peak accounting itself is `MicrophoneLevelTests`'s file, driven
        /// through the real interleaver.
        var levelPeak: Float = 0
        var nextStart: Result<Void, Error> = .success(())
        /// The W3 stop-duration fixture: `stop()` takes ``stopAdvance`` by moving the injected
        /// clock, so `endCapture`'s measured delta is exact and hand-asserted.
        private let stopClock: TestClock?
        private let stopAdvance: Duration

        init(
            ring: AudioRingBuffer,
            captureFormat: CapturedAudioFormat,
            stopClock: TestClock? = nil,
            stopAdvance: Duration = .zero
        ) {
            self.ring = ring
            self.captureFormat = captureFormat
            self.stopClock = stopClock
            self.stopAdvance = stopAdvance
        }

        func start() throws {
            startAttempts += 1
            switch nextStart {
            case .success:
                isRunning = true
            case .failure(let error):
                throw error
            }
        }

        func stop() {
            stopCalls += 1
            isRunning = false
            stopClock?.now += stopAdvance
        }
    }

    private struct StartRefused: Error {}

    /// Write `samples` into `ring` the way the realtime producer would — whole blocks, refused
    /// whole when there is no room.
    private func write(_ samples: [Float], to ring: AudioRingBuffer) {
        _ = samples.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: pointer.count)
        }
    }

    /// The collected chunks of a finished stream — the stream is single-shot and buffers its
    /// yields, so iterating after `terminate` sees everything.
    @MainActor
    private static func collect(_ stream: AsyncStream<AudioBuffer>) async -> [AudioBuffer] {
        var chunks: [AudioBuffer] = []
        for await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private static func keyEvent(_ kind: RawKeyEvent.Kind, at timestamp: Duration) -> RawKeyEvent {
        RawKeyEvent(
            kind: kind, keyCode: 49, modifiers: [.option], isAutorepeat: false, timestamp: timestamp)
    }

    /// The audio an ended session handed to custody, or a test failure.
    private static func endedAudio(_ effect: SessionEffect<AudioBuffer>) throws -> AudioBuffer {
        switch effect {
        case .ended(let outcome):
            switch outcome.content {
            case .completed(_, let audio, _):
                return audio
            case .cancelled:
                XCTFail("a key-up is not a cancellation: the audio it captured is owed downstream")
                throw XCTSkip("no audio")
            }
        case .unchanged, .started, .captureUnavailable, .opening:
            XCTFail("expected the session to end, got \(effect)")
            throw XCTSkip("no outcome")
        }
    }
}
