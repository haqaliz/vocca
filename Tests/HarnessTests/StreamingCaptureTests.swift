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

/// **The continuous-capture contract: the `ContinuousAudioSource` seam and its first
/// conformance, `StreamingCapture`.**
///
/// `streaming-capture` of `turn-taking-barge-in` (C10 — the P3 voice loop), the plan
/// `docs/planning/turn-taking-barge-in/streaming-capture/plan_20260915.md`. The seam is a new
/// protocol in `VoccaCore` (decision (a) of the plan's seam-shape checkpoint):
/// ``SessionAudioSource`` is not extended, not renamed, not touched — its per-session custody
/// contracts ("called exactly once … never while already open", the trap-on-failure release)
/// are machine-custody contracts a continuous conformance has no funnel to guarantee, and the
/// barge-in design's capture is **continuous, never started at interrupt time**
/// (`ARCHITECTURE.md:571`) — a `start()`/`stop()` lifecycle, not a hand-over.
///
/// Everything is headless by construction, the `MicrophoneSource` recipe
/// (`MicrophoneSourceTests.swift:453-499`): the **graph** is the one thing faked — the real
/// one is executed by nothing in CI — and the **ring and the converter in the path are real**,
/// so the conformance's end-to-end path (drain → convert → yield) is real. Ticks are driven by
/// the injected timer as the `(schedule, unschedule)` closure pair, the ``SpeculativeFeed``
/// shape (`FakeTimer`). The twelve tests are the contract `barge-in-loop` compiles against:
///
/// 1. `start()` opens the graph and returns a live stream.
/// 2. A refused graph maps to ``ContinuousAudioSourceError/unavailable`` with nothing scheduled
///    and no stream.
/// 3. Chunks are converted to the 16 kHz mono interchange format, contiguous, in order.
/// 4. One chunk per populated tick, nothing from an empty tick, and no empty `AudioBuffer` ever.
/// 5. `stop()` mid-stream finishes with the unconsumed remainder as the final chunk
///    (the `finish` flush included), after the device is released.
/// 6. A double `stop()` is a no-op.
/// 7. `stop()` before any `start()` is a no-op.
/// 8. A second `start()` while running throws ``ContinuousAudioSourceError/alreadyStarted`` and
///    leaves the first stream live — the ownership refusal that keeps "at most one consumer
///    thread at a time" true for the conformance's ring.
/// 9. `start()` after `stop()` begins a fresh stream with a fresh `beginSession()` reset and a
///    fresh refusal baseline.
/// 10. The countable loss lives on the conformance's `refusedSampleCount`, never on the chunks:
///    every yielded chunk carries `missingSampleCount == 0`.
/// 11. Two instances on two rings do not interfere.
/// 12. A consumer that drops the stream mid-capture does not stop capture; `stop()` still
///    releases the device and ends the stream exactly once.
///
/// Not drivable headlessly, recorded honestly (plan fact 7): the mid-stream converter-throw
/// path — the real `AudioFormatConverter` cannot be made to throw in a test, and the plan
/// rejects fabricating an injection seam to fake it. Its observable invariants — every terminal
/// releases the device, streams finish exactly once — are the ones tests 5, 6, 9 and 12 pin on
/// the drivable paths.
final class StreamingCaptureTests: XCTestCase {

    // MARK: - The ownership and stream contract

    /// `start()` returns the stream and the graph's ledger shows exactly one open — the
    /// microphone is opened once per start, and stays open until `stop()`.
    @MainActor
    func testStartOpensTheGraphAndYieldsTheStream() throws {
        let (capture, graph, timer) = try Self.makeCapture()

        let stream = try capture.start()

        XCTAssertEqual(graph.startAttempts, 1, "start() opens the microphone exactly once")
        XCTAssertTrue(graph.isRunning, "the graph is running from start() until stop()")
        XCTAssertEqual(timer.startCount, 1, "the drain tick is scheduled exactly once, at start")
        XCTAssertEqual(
            timer.cadencesRequested, [.milliseconds(50)],
            "the voice-loop drain tick runs at the shipped 50 ms cadence")

        write([1, 2, 3], to: graph.ring)
        timer.tick()
        capture.stop()

        XCTAssertEqual(graph.stopCalls, 1, "stop() closes the microphone exactly once")
        XCTAssertFalse(graph.isRunning, "stop() releases the microphone")
        XCTAssertNotNil(stream, "start() returned a stream")
    }

    /// The graph refused to open: `start()` throws ``ContinuousAudioSourceError/unavailable``,
    /// nothing is scheduled, the conformance is not running, and no stream exists. The loop maps
    /// this the way the machine maps ``CaptureStart/unavailable``.
    @MainActor
    func testStartThrowsUnavailableWhenTheGraphRefusesToOpen() throws {
        let (capture, graph, timer) = try Self.makeCapture()
        graph.nextStart = .failure(StartRefused())

        XCTAssertThrowsError(try capture.start()) { error in
            XCTAssertEqual(
                error as? ContinuousAudioSourceError, .unavailable,
                "a graph that refuses to open is the .unavailable analogue of CaptureStart.unavailable")
        }

        XCTAssertEqual(graph.startAttempts, 1, "the graph was asked and refused")
        XCTAssertFalse(graph.isRunning, "a refused graph is not running")
        XCTAssertEqual(timer.startCount, 0, "a refused open schedules nothing")
        XCTAssertEqual(timer.stopCount, 0, "a refused open unschedules nothing")
    }

    /// The chunk stream is 16 kHz mono **in order and contiguous**: the chunks' concatenation
    /// equals one whole conversion of the captured audio — the resampler's filter state survives
    /// across ticks (the `SpeculativeFeed` batch-equivalence precedent), so a chunk boundary is
    /// never a discontinuity.
    @MainActor
    func testChunksAreConvertedToTheInterchangeFormatInOrder() async throws {
        let format = CapturedAudioFormat(sampleRate: 48_000, channelCount: 1)
        let signal = Self.sine(frequency: 1000, sampleRate: 48_000, frames: 48_000)
        let (whole, _) = try Self.captureWhole(signal, from: format)

        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 1 << 17), captureFormat: format)
        let timer = FakeTimer()
        let capture = try StreamingCapture(
            graph: graph,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() })
        let stream = try capture.start()

        write(Array(signal[0..<16_000]), to: graph.ring)
        timer.tick()
        write(Array(signal[16_000..<32_000]), to: graph.ring)
        timer.tick()
        write(Array(signal[32_000..<48_000]), to: graph.ring)
        timer.tick()

        capture.stop()

        let chunks = await Self.collect(stream)
        XCTAssertEqual(
            chunks.flatMap(\.samples), whole,
            """
            The chunks' concatenation must equal one whole conversion. Draining the ring in \
            chunks must produce exactly the audio converting it whole would — the resampler's \
            filter state survives across ticks, or the totals agree while every chunk boundary \
            splices a discontinuity (the SpeculativeFeed batch-equivalence standard).
            """)
        XCTAssertTrue(
            chunks.allSatisfy { $0.sampleRate == AudioBuffer.interchangeSampleRate },
            "every chunk is the interchange format — AudioBuffer's initializer traps otherwise")
        XCTAssertFalse(chunks.contains { $0.samples.isEmpty }, "no empty chunk is ever yielded")
    }

    /// An empty-ring tick yields nothing; a populated tick yields exactly one chunk; no empty
    /// `AudioBuffer` is ever yielded — the drain-and-skip shape of the feed's tick, at the
    /// continuous conformance.
    @MainActor
    func testOneChunkPerNonEmptyTickAndNoEmptyChunks() async throws {
        let (capture, graph, timer) = try Self.makeCapture()
        let stream = try capture.start()

        timer.tick()  // empty ring: nothing drained, nothing yielded
        write([1, 2, 3], to: graph.ring)
        timer.tick()  // one populated tick: exactly one chunk
        timer.tick()  // empty ring again: nothing yielded
        capture.stop()

        let chunks = await Self.collect(stream)
        XCTAssertEqual(
            chunks.map(\.samples), [[1, 2, 3]],
            "exactly one chunk, from the one populated tick — and it is never empty")
    }

    /// `stop()` mid-stream releases the device first (the `endCapture` ordering), then drains the
    /// unconsumed remainder and converts it with `finish` — the resampler's tail flush included —
    /// as the stream's final chunk; the stream then ends.
    @MainActor
    func testStopMidStreamFinishesWithTheRemainderAsTheFinalChunk() async throws {
        let format = CapturedAudioFormat(sampleRate: 48_000, channelCount: 1)
        let first = Self.sine(frequency: 440, sampleRate: 48_000, frames: 480)
        let second = Self.sine(frequency: 880, sampleRate: 48_000, frames: 960)

        // The expected chunks, from a converter driven through the identical sequence
        // (beginSession, convert(first), finish(second)) — the conformance's exact path.
        let expected = try AudioFormatConverter(inputFormat: format)
        expected.beginSession()
        let expectedFirst = try expected.convert(first)
        let expectedFinal = try expected.finish(second)

        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 1 << 12), captureFormat: format)
        let timer = FakeTimer()
        let capture = try StreamingCapture(
            graph: graph,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() })
        let stream = try capture.start()

        write(first, to: graph.ring)
        timer.tick()
        write(second, to: graph.ring)
        capture.stop()

        let chunks = await Self.collect(stream)
        XCTAssertEqual(chunks.count, 2, "the tick's chunk, then the remainder as the final chunk")
        XCTAssertEqual(chunks[0].samples, expectedFirst)
        XCTAssertEqual(
            chunks.last?.samples, expectedFinal,
            """
            The final chunk is the unconsumed remainder, converter.finish flush included — the \
            resampler's tail from the ticked conversion must reach the stream, or the voice loop \
            loses the last words of every exchange.
            """)
        XCTAssertEqual(graph.stopCalls, 1, "the graph's ledger shows the stop")
        XCTAssertFalse(
            graph.isRunning,
            "the device is released before the final chunk is observed — release precedes drain")
    }

    /// A second `stop()` is a no-op: it neither drains again, nor finishes a second stream, nor
    /// touches the graph or the timer.
    @MainActor
    func testDoubleStopIsANoOp() async throws {
        let (capture, graph, timer) = try Self.makeCapture()
        let stream = try capture.start()

        write([1, 2, 3], to: graph.ring)
        timer.tick()
        capture.stop()
        capture.stop()

        let chunks = await Self.collect(stream)
        XCTAssertEqual(
            chunks.map(\.samples), [[1, 2, 3]],
            "a second stop neither drains again nor duplicates a chunk")
        XCTAssertEqual(graph.stopCalls, 1, "the second stop never touches the graph")
        XCTAssertEqual(timer.stopCount, 1, "the second stop never unschedules again")
        XCTAssertFalse(graph.isRunning)
    }

    /// `stop()` on a fresh conformance is a no-op: no graph call, no timer call, nothing to end.
    @MainActor
    func testStopBeforeStartIsANoOp() throws {
        let (capture, graph, timer) = try Self.makeCapture()

        capture.stop()

        XCTAssertEqual(graph.startAttempts, 0, "a stop before any start never opens the microphone")
        XCTAssertEqual(graph.stopCalls, 0, "a stop before any start never closes it either")
        XCTAssertEqual(timer.stopCount, 0, "a stop before any start never unschedules a tick")
    }

    /// **The ownership pin.** A second `start()` while the first stream is live throws
    /// ``ContinuousAudioSourceError/alreadyStarted`` and changes nothing: the graph is not asked
    /// again, nothing new is scheduled, and the first stream stays live — one instance owns one
    /// microphone, the API-level refusal that keeps the SPSC warrant's "at most one consumer
    /// thread at a time" true for the conformance's ring.
    @MainActor
    func testASecondStartWhileRunningIsRefused() async throws {
        let (capture, graph, timer) = try Self.makeCapture()
        let stream = try capture.start()

        write([1, 2, 3], to: graph.ring)
        timer.tick()

        XCTAssertThrowsError(try capture.start()) { error in
            XCTAssertEqual(
                error as? ContinuousAudioSourceError, .alreadyStarted,
                "a second stream would be a second consumer on one ring — the SPSC violation")
        }

        write([4, 5], to: graph.ring)
        timer.tick()
        capture.stop()

        let chunks = await Self.collect(stream)
        XCTAssertEqual(
            chunks.map(\.samples), [[1, 2, 3], [4, 5]],
            "the refused second start leaves the first stream live — one more tick still yields")
        XCTAssertEqual(graph.startAttempts, 1, "the refused second start never re-opens the graph")
        XCTAssertEqual(timer.startCount, 1, "the refused second start schedules nothing new")
    }

    /// `start()` after `stop()` begins a **fresh** stream: the converter's `beginSession()` reset
    /// anchors at the start that cannot be skipped (a converter flushed to end-of-stream and not
    /// reset produces zero frames for the next session — the measured stale-converter defect,
    /// `AudioFormatConverter.swift:131-135`), and the refusal baseline is re-read, so the second
    /// capture's countable loss excludes the first capture's.
    @MainActor
    func testStartAfterStopBeginsANewStreamWithAFreshBaseline() async throws {
        let format = CapturedAudioFormat(sampleRate: 48_000, channelCount: 1)
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 1 << 4), captureFormat: format)
        let timer = FakeTimer()
        let capture = try StreamingCapture(
            graph: graph,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() })

        // Session 1: fills the 16-sample ring, then an 8-sample block is refused whole.
        let firstStream = try capture.start()
        write(Array(repeating: 1, count: 16), to: graph.ring)
        write(Array(repeating: 2, count: 8), to: graph.ring)
        XCTAssertEqual(graph.ring.refusedSampleCount, 8, "precondition: session 1 refused 8")
        XCTAssertEqual(capture.refusedSampleCount, 8, "session 1's loss is counted on the conformance")
        capture.stop()
        _ = await Self.collect(firstStream)

        // Session 2: a fresh baseline — its own zero refusals must not inherit session 1's 8.
        let secondStream = try capture.start()
        XCTAssertEqual(
            capture.refusedSampleCount, 0,
            "the second capture starts from a fresh refusal baseline — session 1's loss is not its own")
        let session2 = Self.sine(frequency: 660, sampleRate: 48_000, frames: 24)
        write(Array(session2[0..<12]), to: graph.ring)
        timer.tick()
        write(Array(session2[12..<24]), to: graph.ring)
        timer.tick()
        capture.stop()

        let (whole, _) = try Self.captureWhole(session2, from: format)
        let chunks = await Self.collect(secondStream)
        XCTAssertEqual(
            chunks.flatMap(\.samples), whole,
            """
            The second capture converts its own audio whole — a converter that was flushed at the \
            first capture's stop and not reset produces zero frames here, the measured \
            stale-converter defect. beginSession() anchors the reset at the start that cannot be \
            skipped.
            """)
        XCTAssertEqual(graph.stopCalls, 2, "each capture releases the device exactly once")
    }

    /// The countable loss lives on the conformance, never on the chunks: a continuous slice is
    /// not a hand-over, so every chunk carries `missingSampleCount == 0` (plan fact 9) while
    /// `refusedSampleCount` reports exactly the baseline-subtracted delta.
    @MainActor
    func testTheLossIsCountedOnTheConformanceNotTheChunks() async throws {
        let (capture, graph, timer) = try Self.makeCapture(capacity: 8)
        let stream = try capture.start()

        XCTAssertEqual(capture.refusedSampleCount, 0, "precondition: a fresh baseline")
        write([0, 1, 2, 3, 4, 5, 6, 7], to: graph.ring)  // fills the ring
        write([100, 101], to: graph.ring)  // refused whole — the ring takes nothing partial
        XCTAssertEqual(graph.ring.refusedSampleCount, 2, "precondition: the second block was refused")

        timer.tick()
        XCTAssertEqual(
            capture.refusedSampleCount, 2,
            "the countable loss is exposed on the conformance, baseline-subtracted")

        write([200, 201, 202, 203], to: graph.ring)
        timer.tick()
        capture.stop()

        let chunks = await Self.collect(stream)
        XCTAssertEqual(
            chunks.map(\.samples), [[0, 1, 2, 3, 4, 5, 6, 7], [200, 201, 202, 203]],
            "the audio itself is untouched")
        XCTAssertTrue(
            chunks.allSatisfy { $0.missingSampleCount == 0 },
            """
            A continuous slice is not a hand-over — the completeness link has no transcript \
            meaning on a per-chunk value, so chunks carry 0 and the countable loss lives on \
            refusedSampleCount.
            """)
        XCTAssertEqual(capture.refusedSampleCount, 2, "exactly the baseline-subtracted delta")
    }

    /// Two conformance instances on two rings do not interfere: one instance's tick never drains
    /// the other's ring — the "owned separately from the dictation rings" fact at the unit level
    /// (the composition-level proof is the no-touch pin: the dictation files never meet
    /// `StreamingCapture`).
    @MainActor
    func testTwoInstancesOnTwoRingsDoNotInterfere() async throws {
        let graphA = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 1 << 8), captureFormat: .interchange)
        let graphB = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: 1 << 8), captureFormat: .interchange)
        let timerA = FakeTimer()
        let timerB = FakeTimer()
        let captureA = try StreamingCapture(
            graph: graphA,
            schedule: { timerA.start(every: $0, $1) },
            unschedule: { timerA.stop() })
        let captureB = try StreamingCapture(
            graph: graphB,
            schedule: { timerB.start(every: $0, $1) },
            unschedule: { timerB.stop() })

        let streamA = try captureA.start()
        let streamB = try captureB.start()

        write([1, 2, 3], to: graphA.ring)
        write([7, 8, 9], to: graphB.ring)
        timerA.tick()  // A's tick must not touch B's ring
        captureB.stop()

        let chunksB = await Self.collect(streamB)
        XCTAssertEqual(
            chunksB.map(\.samples), [[7, 8, 9]],
            "B's audio is still in B's ring when B stops — A's tick never drained it")

        write([4, 5], to: graphA.ring)
        timerA.tick()
        captureA.stop()

        let chunksA = await Self.collect(streamA)
        XCTAssertEqual(
            chunksA.map(\.samples), [[1, 2, 3], [4, 5]],
            "A's stream carries exactly A's audio, in order")
    }

    /// The "stream cancelled vs stopped" edge: a consumer that stops iterating mid-capture does
    /// **not** stop capture — the lifecycle is `stop()`'s and the loop owns it; yields after the
    /// drop are buffered by the stream. `stop()` then still releases the device and ends the
    /// stream, exactly once, without a trap.
    @MainActor
    func testTheStreamEndsExactlyOnceAcrossConsumerDropAndStop() async throws {
        let (capture, graph, timer) = try Self.makeCapture()
        let stream = try capture.start()

        write([1, 2, 3], to: graph.ring)
        timer.tick()

        // The consumer drops the stream mid-capture: one chunk, then iteration ends.
        let consumer = Task { @MainActor in
            var first: AudioBuffer?
            for await chunk in stream {
                first = chunk
                break
            }
            return first
        }
        let first = await consumer.value
        XCTAssertEqual(first?.samples, [1, 2, 3], "the drop happens after the first chunk")

        // The drop does not stop capture — capture continues, buffering for a consumer.
        write([4, 5], to: graph.ring)
        timer.tick()
        XCTAssertTrue(graph.isRunning, "a dropped consumer never releases the microphone")

        capture.stop()
        XCTAssertEqual(graph.stopCalls, 1, "stop() releases the device exactly once, after the drop")
        XCTAssertEqual(timer.stopCount, 1, "the tick is unscheduled exactly once")
        XCTAssertFalse(graph.isRunning, "a stream that ends is never a microphone that stayed open")
    }

    // MARK: - Helpers

    /// The graph, as a **ledger** — the `MicrophoneSourceTests` recipe, fresh for this aspect. It
    /// uses a real `AudioRingBuffer`, because the conformance's end-to-end path — drain, convert,
    /// yield — is only real if the ring is; and it records every start and stop so that custody
    /// is asserted off the ledger, never off a believed call.
    private final class FakeCaptureGraph: CaptureGraphSeam {
        let ring: AudioRingBuffer
        let captureFormat: CapturedAudioFormat
        private(set) var startAttempts = 0
        private(set) var stopCalls = 0
        private(set) var isRunning = false
        /// The level surface the seam carries — a fixed 0 in this ledger; the peak accounting is
        /// `MicrophoneLevelTests`'s file, not this aspect's.
        var levelPeak: Float = 0
        /// The scriptable open answer: `.success` opens the microphone, `.failure` refuses it.
        var nextStart: Result<Void, Error> = .success(())

        init(ring: AudioRingBuffer, captureFormat: CapturedAudioFormat) {
            self.ring = ring
            self.captureFormat = captureFormat
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
        }
    }

    private struct StartRefused: Error {}

    /// A capture over a fresh ledger graph, with the injected timer captured. The default
    /// `captureFormat` is the interchange format, so the default tests exercise the pass-through
    /// regime; the 48 kHz tests build their own graph to exercise the resampler.
    @MainActor
    private static func makeCapture(
        format: CapturedAudioFormat = .interchange, capacity: Int = 1 << 12
    ) throws -> (capture: StreamingCapture, graph: FakeCaptureGraph, timer: FakeTimer) {
        let graph = FakeCaptureGraph(
            ring: AudioRingBuffer(capacity: capacity), captureFormat: format)
        let timer = FakeTimer()
        let capture = try StreamingCapture(
            graph: graph,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() })
        return (capture, graph, timer)
    }

    /// Write `samples` into `ring` the way the realtime producer would — whole blocks, refused
    /// whole when there is no room.
    private func write(_ samples: [Float], to ring: AudioRingBuffer) {
        _ = samples.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: pointer.count)
        }
    }

    /// The collected chunks of a finished stream — the stream is single-shot and buffers its
    /// yields, so iterating after `stop()` sees everything.
    private static func collect(_ stream: AsyncStream<AudioBuffer>) async -> [AudioBuffer] {
        var chunks: [AudioBuffer] = []
        for await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    /// A synthetic sine — the `AudioFormatConverterTests` fixture, so the expected frequencies
    /// and the count-versus-ratio discipline stay shared.
    private static func sine(frequency: Double, sampleRate: Double, frames: Int) -> [Float] {
        (0..<frames).map { index in
            Float(sin(2.0 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    /// One whole conversion: convert, then flush — the `captureWhole` shape.
    private static func captureWhole(
        _ samples: [Float], from format: CapturedAudioFormat
    ) throws -> (audio: [Float], converter: AudioFormatConverter) {
        let converter = try AudioFormatConverter(inputFormat: format)
        var audio = try converter.convert(samples)
        audio += try converter.finish()
        return (audio, converter)
    }
}