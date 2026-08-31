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

import VoccaASR
import VoccaCore
import XCTest

@testable import VoccaAudio

/// The speculative feed's unit tests (`speculative-feed` phase (b)): the ring's mid-session
/// consumer — the object that drains the ring on its 50 ms tick, converts each drain through the
/// same `AudioFormatConverter` `MicrophoneSource` finishes at `endCapture`, and yields
/// `AsyncStream<AudioBuffer>` chunks into the streaming route.
///
/// Everything is headless by construction: a scripted growing ring, a fake `RepeatingTimer`
/// (the `FakeTimer` shape) whose manual fires stand in for the real main-run-loop timer, and the
/// real `AudioFormatConverter`. The tests pin the four load-bearing properties of the feed:
///
/// - **Batch-equivalence at the feed's interface** — the chunks the feed yielded, concatenated
///   with the `endCapture`-shaped remainder, equal a single conversion of the whole input
///   (the `testChunkedConversionProducesExactlyTheSameAudioAsASingleCall` precedent, at the
///   feed's interface).
/// - **`terminate(with:)` semantics** — the remainder is the last chunk, the stream ends, and a
///   stopped feed is inert: further `start`/`terminate`/`cancel` are no-ops and nothing is ever
///   yielded after the finish.
/// - **A terminal cannot strand a chunk** — the chunks yielded before the terminal are exactly
///   the stream, remainder last, nothing after.
/// - **Empty drains are skipped** — no empty `AudioBuffer` is ever yielded.
final class SpeculativeFeedTests: XCTestCase {

    // MARK: - Batch-equivalence at the feed's interface

    /// **The batch-equivalence precondition.** A scripted growing ring drained in chunks by the
    /// feed's tick, with the tail left in the ring for `endCapture`'s remainder, must convert to
    /// exactly the audio a single conversion of the whole input would produce — the
    /// `testChunkedConversionProducesExactlyTheSameAudioAsASingleCall` precedent, driven through
    /// the feed. This is the property the end-to-end "final equals the batch result for the same
    /// audio" acceptance rests on.
    @MainActor
    func testChunkedDrainsThroughTheFeedAreContiguousWithAWholeConversion() async throws {
        let format = CapturedAudioFormat(sampleRate: 48_000, channelCount: 1)
        let signal = Self.sine(frequency: 1000, sampleRate: 48_000, frames: 48_000)
        let (whole, _) = try Self.captureWhole(signal, from: format)

        let ring = AudioRingBuffer(capacity: 1 << 17)
        let converter = try AudioFormatConverter(inputFormat: format)
        let timer = FakeTimer()
        let feed = SpeculativeFeed(
            ring: ring, converter: converter,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() })

        feed.start()
        // The session: the fixture lands in the ring in three blocks; the first two are drained
        // by ticks, the third is left for the remainder — the `endCapture` shape.
        write(Array(signal[0..<16_000]), to: ring)
        timer.tick()
        write(Array(signal[16_000..<32_000]), to: ring)
        timer.tick()
        write(Array(signal[32_000..<48_000]), to: ring)

        let remainder = try converter.finish(ring.drain())
        feed.terminate(with: AudioBuffer(samples: remainder, sampleRate: 16_000))

        let chunks = await Self.collect(feed.chunks)
        XCTAssertEqual(
            chunks.flatMap(\.samples), whole,
            """
            The feed's stream — the drained chunks plus the terminate-appended remainder — must \
            equal one whole conversion. Draining the ring in chunks must produce exactly the \
            audio converting it whole would — the resampler's filter state survives across ticks, \
            or the totals agree while every chunk boundary splices a discontinuity.
            """)
        XCTAssertEqual(
            chunks.last?.samples, remainder,
            "the remainder `terminate(with:)` appended is the stream's last chunk — the engine "
                + "still receives the whole audio, in order")
    }

    // MARK: - The terminal's shape

    /// `terminate(with:)` appends the remainder as the stream's last chunk, finishes the stream,
    /// and a feed that has stopped is inert: a second `terminate`, a `cancel` and a `start` are
    /// all no-ops, and no chunk is ever yielded after the finish.
    @MainActor
    func testTerminateWithARemainderFinishesTheStreamAndFurtherCallsAreNoOps() async throws {
        let ring = AudioRingBuffer(capacity: 1 << 12)
        let converter = try AudioFormatConverter(inputFormat: .interchange)
        let timer = FakeTimer()
        let feed = SpeculativeFeed(
            ring: ring, converter: converter,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() })

        feed.start()
        XCTAssertEqual(timer.startCount, 1, "the timer is armed once, at start")
        write([1, 2, 3], to: ring)
        timer.tick()
        write([4, 5], to: ring)
        timer.tick()

        feed.terminate(with: AudioBuffer(samples: [6, 7], sampleRate: 16_000))

        let chunks = await Self.collect(feed.chunks)
        XCTAssertEqual(
            chunks.map(\.samples), [[1, 2, 3], [4, 5], [6, 7]],
            "each tick's conversion is one chunk in order, and the remainder is the last")
        XCTAssertEqual(timer.stopCount, 1, "the timer is stopped exactly once, at terminate")

        // The idempotence rows: a second terminate, a cancel and a start are all no-ops.
        feed.terminate(with: AudioBuffer(samples: [9], sampleRate: 16_000))
        feed.cancel()
        feed.start()
        let after = await Self.collect(feed.chunks)
        XCTAssertTrue(
            after.isEmpty,
            "a second terminate or cancel yields nothing — the stream was finished exactly once")
        XCTAssertEqual(timer.stopCount, 1, "an idempotent terminate/cancel does not stop again")
        XCTAssertEqual(timer.startCount, 1, "a terminated feed is never re-armed")
    }

    /// **A mid-tick terminal cannot strand a chunk.** The timer fires once (one chunk yielded),
    /// then the terminal lands — the stream ends with exactly the chunks yielded before it, the
    /// remainder as the last element, and nothing after; a stale fire after the terminal is a
    /// no-op ("nothing is read while idle").
    @MainActor
    func testATerminalMidSessionCannotStrandAChunkAndStaleFiresReadNothing() async throws {
        let ring = AudioRingBuffer(capacity: 1 << 12)
        let converter = try AudioFormatConverter(inputFormat: .interchange)
        let timer = FakeTimer()
        let feed = SpeculativeFeed(
            ring: ring, converter: converter,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() })

        feed.start()
        write([1, 2, 3], to: ring)
        timer.tick()
        // Captured but never ticked — the terminal lands mid-drain, before the next tick.
        write([4, 5], to: ring)

        feed.terminate(with: AudioBuffer(samples: [4, 5], sampleRate: 16_000))

        let chunks = await Self.collect(feed.chunks)
        XCTAssertEqual(
            chunks.map(\.samples), [[1, 2, 3], [4, 5]],
            "the stream ends with exactly the chunks yielded before the terminal, remainder last")

        timer.tick()
        let after = await Self.collect(feed.chunks)
        XCTAssertTrue(after.isEmpty, "a stale fire after the terminal reads nothing")
    }

    // MARK: - Empty drains

    /// A tick with nothing in the ring yields nothing — empty drains are skipped, and no empty
    /// `AudioBuffer` is ever yielded.
    @MainActor
    func testEmptyDrainTicksYieldNothing() async throws {
        let ring = AudioRingBuffer(capacity: 1 << 12)
        let converter = try AudioFormatConverter(inputFormat: .interchange)
        let timer = FakeTimer()
        let feed = SpeculativeFeed(
            ring: ring, converter: converter,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() })

        feed.start()
        timer.tick()
        timer.tick()
        write([1], to: ring)
        timer.tick()
        feed.terminate(with: nil)

        let chunks = await Self.collect(feed.chunks)
        XCTAssertEqual(
            chunks.map(\.samples), [[1]],
            "empty drains are skipped — no empty chunk is ever yielded")
    }

    // MARK: - Sub-minimum suppression (phase (e))

    /// **The sub-minimum hold.** With `subMinimum` wired, ticks below the threshold accumulate
    /// and yield nothing; the first tick at or past the crossing yields the **whole accumulated
    /// prefix** — every sample reaches the engine, in order (batch-equivalence preserved), and
    /// no partial exists before the threshold.
    @MainActor
    func testSubMinimumHoldsTicksBelowTheThresholdAndTheFirstChunkCarriesTheWholePrefix() async throws {
        let ring = AudioRingBuffer(capacity: 1 << 12)
        let converter = try AudioFormatConverter(inputFormat: .interchange)
        let timer = FakeTimer()
        let feed = SpeculativeFeed(
            ring: ring, converter: converter,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() },
            subMinimum: { $0 < 4 })
        feed.start()

        write([1, 2], to: ring)
        timer.tick()
        write([3], to: ring)
        timer.tick()
        write([4], to: ring)
        timer.tick()

        feed.terminate(with: AudioBuffer(samples: [], sampleRate: 16_000))

        let chunks = await Self.collect(feed.chunks)
        XCTAssertEqual(
            chunks.map(\.samples), [[1, 2, 3, 4]],
            """
            Below the threshold nothing is yielded; the first chunk after the crossing carries \
            the whole accumulated prefix — asserted on both the sample count and the samples \
            themselves, so the engine still receives every sample, in order.
            """)
    }

    /// **A whole session below the minimum.** `terminate(with:)` flushes everything accumulated
    /// regardless of the minimum — the stream's chunks concatenate to the full (short) audio —
    /// and the route over that stream, whose engine answers empty below its own minimum (the
    /// seam contract), ends `.emptySkip` exactly as today: the injector is untouched and the
    /// record class is `.emptySkip`, never a failure notice.
    @MainActor
    func testAWholeSessionBelowTheMinimumIsFlushedAtTerminateAndTheRouteEmptySkips() async throws {
        let ring = AudioRingBuffer(capacity: 1 << 12)
        let converter = try AudioFormatConverter(inputFormat: .interchange)
        let timer = FakeTimer()
        let feed = SpeculativeFeed(
            ring: ring, converter: converter,
            schedule: { timer.start(every: $0, $1) },
            unschedule: { timer.stop() },
            subMinimum: { $0 < 100_000 })
        feed.start()

        write([1, 2, 3], to: ring)
        timer.tick()
        write([4, 5], to: ring)
        let remainder = try converter.finish(ring.drain())
        feed.terminate(with: AudioBuffer(samples: remainder, sampleRate: 16_000))

        let chunks = await Self.collect(feed.chunks)
        XCTAssertEqual(
            chunks.map(\.samples), [[1, 2, 3], [4, 5]],
            "terminate flushes everything accumulated plus the remainder — the stream carries "
                + "the full short audio, nothing dropped")
        XCTAssertEqual(chunks.flatMap(\.samples), [1, 2, 3, 4, 5])

        let ledger = LatencyLedger()
        let sessionID = await ledger.beginSession()
        let engine = StreamingStubEngine(
            identity: EngineIdentity(
                id: "empty-final-stub", displayName: "Empty final stub", isLocal: true),
            partials: [], finalText: "")
        let injector = FeedTestInjector()
        let pipeline = DictationPipeline(
            engine: engine, injector: injector, holder: LedgerTranscriptHolder(),
            recorder: ledger, clock: ContinuousMonotonicClock())
        let target = TargetContext(
            bundleID: "com.example.Notes", windowTitle: "The Draft", isSecureInput: false)
        let stream = AsyncStream<AudioBuffer> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        let surface = await pipeline.routeStreaming(
            chunks: stream, target: target, sessionID: sessionID)

        XCTAssertEqual(surface, PipelineSurface.idle, "a sub-minimum whole session is skipped, not failed")
        let calls = await injector.callCount
        XCTAssertEqual(
            calls, 0,
            "the injector is untouched — `\"\"` is never pasted")
        let records = await ledger.snapshot()
        XCTAssertEqual(
            records.first?.outcome, .emptySkip,
            "the record class is `.emptySkip` exactly as today — never a failure, never a delivery")
    }

    // MARK: - The cadence, in exactly one file (phase (e))

    /// **The single-source scan.** The feed's 50 ms cadence must be named in exactly one file
    /// under `Sources/` — the "constants live in exactly one place" doctrine, the
    /// `ProvisionalCleanupTargets` scan shape — and that file's constant must be 50 ms.
    /// The needle is built from two parts so this very test does not trip its own scan.
    func testTheFeedCadenceLivesInExactlyOneFileAndIsFiftyMilliseconds() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let needle = "SpeculativeFeed" + ".cadence"

        var sightings: [String: Int] = [:]
        for file in SwiftSourceScanner.swiftFiles(under: root.appendingPathComponent("Sources")) {
            let content = try String(contentsOf: file, encoding: .utf8)
            if content.contains(needle) {
                sightings[file.lastPathComponent, default: 0] += 1
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), ["SpeculativeFeed.swift"],
            "the feed cadence must be named in exactly one file under Sources/, got: \(sightings)")
        let definition = try String(
            contentsOf: root.appendingPathComponent("Sources/VoccaAudio/SpeculativeFeed.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            definition.contains("static let cadence: Duration = .milliseconds(50)"),
            "the one file's constant is 50 ms — a different value must be a reviewed edit here")
    }

    // MARK: - Helpers

    /// The route's injector, as a counter — the sub-minimum whole-session row asserts the
    /// injector is untouched, and a counter is the honest witness.
    private actor FeedTestInjector: TextInjector {
        private(set) var callCount = 0

        func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
            callCount += 1
            return InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false, elapsed: .zero)
        }
    }

    /// The collected chunks of a finished stream — the stream is single-shot and buffers its
    /// yields, so iterating after `terminate`/`cancel` sees everything.
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

    /// Write `samples` into `ring` the way the realtime producer would — whole blocks, refused
    /// whole when there is no room.
    private func write(_ samples: [Float], to ring: AudioRingBuffer) {
        _ = samples.withUnsafeBufferPointer { pointer in
            ring.write(pointer.baseAddress!, count: pointer.count)
        }
    }
}