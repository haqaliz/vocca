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

import Foundation
import VoccaCore
import XCTest

/// The `widget-streaming` phase-1 decision table: what ``DictationPipeline/routeStreaming(chunks:target:sessionID:)``
/// does with a stream of transcripts — the permanent guard, the batch degradation, and the
/// closed set of failure rows.
///
/// Five promises are pinned here, each over the full shape it governs:
///
/// - **The guard (S2, load-bearing): zero injection before the final.** A streaming stub that
///   yields partials then one final transcript produces exactly one injector call, carrying the
///   final's text — never a partial's. The assertion is on the recorded calls, so a route that
///   injected a partial would leave a second row (or a wrong text) the test can see.
/// - **The degradation is the seam's, not a caller branch (S4):** a batch engine through the
///   same route yields zero partials, never touches the sink, and answers exactly like the
///   batch route. The no-branch pin at the bottom scans the route and this test source for the
///   seam's streaming flag — the batch default *is* the degradation.
/// - **Cancellation is an instruction (PRD R3, `PRODUCT_SPEC.md:129`):** Esc before the final
///   ends `.idle` with nothing injected and no sink touch after cancellation; Esc during
///   cleanup discards the cleaned text and injects nothing.
/// - **Empty text never reaches the injector:** an empty final routes `.idle` (`emptySkip`)
///   with the injector untouched — the empty-text guard of the batch table, kept.
/// - **A throwing stream is a reason-only notice (PRD R5):** `.reasonOnly(.transcriptionFailed)`
///   with the sink untouched — nothing was ever produced, so nothing is presented and nothing
///   is lost.
///
/// The engine double is the shared ``StreamingStubEngine`` (`ASRTestDoubles.swift`), whose
/// scripted partials and final are the ground truth the expected strings are written by hand
/// against; the batch shape drives ``StubEngine``'s seam default through the same route. The
/// injector and the sink are ledger doubles written below — every call recorded, so "never" is
/// an assertion on a counter rather than an absence the test cannot see.
final class DictationPipelineStreamingTests: XCTestCase {

    /// The streaming stub's identity — a dedicated id, so its transcripts are attributable to
    /// the engine that produced them and to no other.
    private func streamingIdentity() -> EngineIdentity {
        EngineIdentity(
            id: "streaming-stub-engine", displayName: "Streaming stub engine", isLocal: true)
    }

    /// One pipeline over a scripted streaming engine: engine, ledger injector, ledger holder
    /// and ledger sink, all fresh per test.
    private func makeStreamingPipeline(
        partials: [String],
        finalText: String,
        error: Error? = nil,
        gated: Bool = false,
        sink: LedgerPartialSink? = nil,
        cleanup: (any CleanupProvider)? = nil
    ) -> (
        pipeline: DictationPipeline, injector: LedgerInjectorDouble, sink: LedgerPartialSink
    ) {
        let engine = StreamingStubEngine(
            identity: streamingIdentity(), partials: partials, finalText: finalText,
            error: error, gated: gated)
        let sink = sink ?? LedgerPartialSink()
        let injector = LedgerInjectorDouble(result: deliveredResult())
        return (
            DictationPipeline(
                engine: engine, injector: injector, holder: LedgerTranscriptHolder(),
                cleanup: cleanup, partialSink: sink),
            injector,
            sink)
    }

    /// The fixed delivery answer every test's injector returns — a clipboard-paste rung, the
    /// P0 first rung (success under I1).
    private func deliveredResult() -> InjectionResult {
        InjectionResult(
            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false, elapsed: .zero)
    }

    /// The focused context the route is given — the root's key-down resolution, handed to the
    /// pipeline at key-up.
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

    /// The chunk producer: an `AsyncStream` of the given buffers — the smallest stream a caller
    /// can send, and enough for both the streaming stub and the batch default to answer.
    private func streamOf(_ chunks: [AudioBuffer]) -> AsyncStream<AudioBuffer> {
        AsyncStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    /// Waits until a condition holds — the gate tests' synchronisation, the
    /// `DictationPipelineTests.waitUntil` shape (2 s deadline, 1 ms sleep).
    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition did not hold within 2 seconds")
    }

    // MARK: - The guard (S2, load-bearing): zero injection before the final

    /// A streaming stub yields partials then one final transcript; the route emits each partial
    /// to the sink in order, and the injector is called **exactly once, with the final's text**.
    ///
    /// The assertion is on the recorded calls: a route that injected a partial would show a
    /// second row or a wrong text — the ledger makes "zero injection before the final" a fact
    /// the test sees, not a claim the test assumes.
    func testTheGuardZeroInjectorCallsBeforeTheFinalAndExactlyOneWithTheFinalText() async {
        let partials = ["hel", "hello "]
        let finalText = "hello world"
        let (pipeline, injector, sink) = makeStreamingPipeline(
            partials: partials, finalText: finalText)
        let target = target()

        let surface = await pipeline.routeStreaming(
            chunks: streamOf([buffer([1, 2, 3])]), target: target)

        XCTAssertEqual(surface, .idle)
        let calls = await injector.calls
        XCTAssertEqual(
            calls.count, 1,
            "exactly one injector call per route — the final's, never a partial's")
        XCTAssertEqual(
            calls.first?.text, finalText,
            "the one call carries the final text — a partial reaching the injector would leave "
                + "a wrong-text row the ledger would show")
        XCTAssertTrue(
            calls.allSatisfy { !partials.contains($0.text) },
            "no partial text may ever appear in the injector's ledger")
        XCTAssertEqual(
            sink.partials, partials,
            "each partial reached the sink, in stream order — provisional text is a widget "
                + "matter, injection is not")
    }

    // MARK: - The batch degradation (S4): the seam's default, not a caller branch

    /// A batch engine through the streaming route: the seam's default yields one final and
    /// nothing else — zero partials, zero sink touches, and an outcome identical to the batch
    /// route's (same surface, same single injector call with the same text).
    func testBatchStubThroughTheStreamingRouteYieldsNoPartialsAndTheBatchOutcome() async {
        let sink = LedgerPartialSink()
        let injector = LedgerInjectorDouble(result: deliveredResult())
        let pipeline = DictationPipeline(
            engine: StubEngine.parakeet(), injector: injector,
            holder: LedgerTranscriptHolder(), partialSink: sink)
        let target = target()

        let surface = await pipeline.routeStreaming(
            chunks: streamOf([buffer([1, 2, 3])]), target: target)

        XCTAssertEqual(surface, .idle)
        XCTAssertEqual(
            sink.partials, [],
            "the batch default yields exactly one final — the sink is never touched")
        let calls = await injector.calls
        XCTAssertEqual(
            calls, [RecordedInjection(text: "1 2 3", target: target)],
            "the one final routes through the same decision table as the batch route's")

        let batchInjector = LedgerInjectorDouble(result: deliveredResult())
        let batchPipeline = DictationPipeline(
            engine: StubEngine.parakeet(), injector: batchInjector,
            holder: LedgerTranscriptHolder())
        let batchSurface = await batchPipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target)
        let batchCalls = await batchInjector.calls

        XCTAssertEqual(
            batchSurface, surface,
            "the batch engine's streaming answer is the batch route's answer")
        XCTAssertEqual(
            batchCalls, calls,
            "the batch engine's streaming route leaves the same injector ledger as the batch "
                + "route — one call, same text, same target")
    }

    // MARK: - Cancellation: an instruction, never an accident

    /// Esc before the final: the route task is cancelled while the stream is parked ahead of
    /// its final transcript. `.idle`, nothing injected, and the sink holds exactly the partials
    /// presented before the cancellation — no touch after it.
    func testCancellationBeforeTheFinalFinalizesAbortedAndTouchesNothingAfterCancellation() async {
        let sink = LedgerPartialSink()
        let injector = LedgerInjectorDouble(result: deliveredResult())
        let engine = StreamingStubEngine(
            identity: streamingIdentity(), partials: ["hel", "hello "],
            finalText: "hello world", gated: true)
        let pipeline = DictationPipeline(
            engine: engine, injector: injector, holder: LedgerTranscriptHolder(),
            partialSink: sink)
        let target = target()
        let chunks = streamOf([buffer([1, 2, 3])])

        let task = Task {
            await pipeline.routeStreaming(chunks: chunks, target: target)
        }
        await waitUntil { await engine.parkedStreams == 1 }
        task.cancel()
        // The stream is parked ahead of the final — the gate is what lets the route finish.
        // (The route ends on its own if the stream observes the cancellation first; opening the
        // gate then is a harmless no-op.)
        await engine.openGate()
        let surface = await task.value

        XCTAssertEqual(surface, .idle, "a cancelled stream is a discard, not a failure")
        let calls = await injector.calls
        XCTAssertEqual(calls, [], "a cancelled route must never inject")
        XCTAssertEqual(
            sink.partials, ["hel", "hello "],
            "the partials presented before the cancellation are the only sink touches — "
                + "nothing is presented after it")
    }

    // MARK: - Empty final: no paste of ""

    /// The engine's stream can end in an empty final even after non-empty partials; whatever
    /// the engine called silence, `""` is not pasted — the empty-text guard of the batch table
    /// applies to the streaming final too. `.idle`, injector untouched.
    func testAnEmptyFinalIsEmptySkippedWithoutAnInjectorCall() async {
        let (pipeline, injector, sink) = makeStreamingPipeline(
            partials: ["hel"], finalText: "")
        let target = target()

        let surface = await pipeline.routeStreaming(
            chunks: streamOf([buffer([1, 2, 3])]), target: target)

        XCTAssertEqual(surface, .idle)
        let calls = await injector.calls
        XCTAssertEqual(calls, [], "an empty final must not reach the injector")
        XCTAssertEqual(
            sink.partials, ["hel"],
            "the partials were presented — the emptiness is the final's, not the stream's")
    }

    // MARK: - Failure: a reason-only notice, nothing presented

    /// A stream that throws surfaces `.reasonOnly(.transcriptionFailed)` (PRD R5): nothing was
    /// ever produced, so the injector is never called **and the sink is never touched** — the
    /// throwing shape of this stub yields nothing before the failure.
    func testAThrowingStreamSurfacesTranscriptionFailedAndNeverTouchesTheSink() async {
        let (pipeline, injector, sink) = makeStreamingPipeline(
            partials: [], finalText: "hello world", error: FakeStreamingError.boom)
        let target = target()

        let surface = await pipeline.routeStreaming(
            chunks: streamOf([buffer([1, 2, 3])]), target: target)

        XCTAssertEqual(surface, .reasonOnly(.transcriptionFailed))
        let calls = await injector.calls
        XCTAssertEqual(calls, [])
        XCTAssertEqual(
            sink.partials, [],
            "a stream that fails before any partial must never touch the sink — nothing was "
                + "ever produced")
    }

    // MARK: - Post-cleanup cancellation

    /// Esc during the cleanup stage of the streaming route: the cleaned text is discarded,
    /// nothing is injected — the post-cleanup re-check of the shared decision table, on the
    /// streaming path.
    func testCancellationDuringCleanupInjectsNothing() async {
        let provider = HangingCleanupProvider()
        let (pipeline, injector, _) = makeStreamingPipeline(
            partials: ["hel"], finalText: "hello world", cleanup: provider)
        let target = target()
        let chunks = streamOf([buffer([1, 2, 3])])

        let task = Task {
            await pipeline.routeStreaming(chunks: chunks, target: target)
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
    }

    // MARK: - Nil sink: byte-for-byte today (the B2 precedent)

    /// A pipeline built **without a sink** behaves identically to today's: the batch route
    /// injects the raw transcript exactly as before, and the streaming route over a streaming
    /// engine (whose partials have nowhere to go) answers with the same surface and the same
    /// single injector call. Nil is today, byte for byte.
    func testANilSinkPipelineBehavesByteForByteLikeToday() async {
        let target = target()

        let batchInjector = LedgerInjectorDouble(result: deliveredResult())
        let batchPipeline = DictationPipeline(
            engine: StubEngine.parakeet(), injector: batchInjector,
            holder: LedgerTranscriptHolder())
        let batchSurface = await batchPipeline.route(
            SessionEffect<AudioBuffer>.ended(outcome(.retained(.keyUp), [1, 2, 3])),
            target: target)

        let streamingInjector = LedgerInjectorDouble(result: deliveredResult())
        let streamingPipeline = DictationPipeline(
            engine: StreamingStubEngine(
                identity: streamingIdentity(), partials: ["hel", "hello "], finalText: "1 2 3"),
            injector: streamingInjector, holder: LedgerTranscriptHolder())
        let streamingSurface = await streamingPipeline.routeStreaming(
            chunks: streamOf([buffer([1, 2, 3])]), target: target)

        XCTAssertEqual(
            streamingSurface, batchSurface,
            "a nil-sink pipeline's surface is today's surface")
        let batchCalls = await batchInjector.calls
        let streamingCalls = await streamingInjector.calls
        XCTAssertEqual(
            streamingCalls, batchCalls,
            "a nil-sink pipeline's injector ledger is today's ledger — one call, same text, "
                + "same target")
    }

    // MARK: - The no-branch pin (the EngineSwapTests pattern)

    /// The degradation is the seam's default, not a caller branch: neither the route file nor
    /// this streaming test source may name the seam's streaming flag. The needle is built from
    /// two parts so this very test does not trip its own scan; the assertion is on the
    /// contiguous token, which is what a caller branch would have to write.
    func testTheRouteAndStreamingTestSourceContainNoBranchOnTheSeamsStreamingFlag() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let files = [
            "Sources/VoccaCore/DictationPipeline.swift",
            "Tests/HarnessTests/DictationPipelineStreamingTests.swift",
        ]
        let flag = "supports" + "Streaming"

        for relative in files {
            let url = root.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(
                source.contains(flag),
                "\(relative) must never branch on the seam's streaming flag — the batch default "
                    + "IS the degradation, and a caller branch would split the pipeline in two")
        }
    }
}

/// What a scripted streaming failure is, for the throwing row of the table. The specific error
/// is the engine's business — the pipeline must not stringify it.
private enum FakeStreamingError: Error {
    case boom
}

/// **One recorded injection** — the injector ledger's row, `Equatable` so the tests can assert
/// the exact text and the exact context the pipeline handed the ladder.
fileprivate struct RecordedInjection: Equatable {
    let text: String
    let target: TargetContext
}

/// **The injector, with a ledger** — every call's text and target recorded in order, and one
/// fixed result. The ledger is what makes "never called" an assertion instead of an assumption.
actor LedgerInjectorDouble: TextInjector {
    private let result: InjectionResult
    fileprivate var calls: [RecordedInjection] = []

    init(result: InjectionResult) {
        self.result = result
    }

    func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        calls.append(RecordedInjection(text: text, target: target))
        return result
    }
}

/// **The widget-only sink, with a ledger** — every presented partial recorded in order, so
/// "never touched" is an assertion on a list rather than an absence the test cannot see.
///
/// The protocol's `presentPartial` is synchronous, so an actor double cannot witness it
/// honestly; `@unchecked Sendable` is the claim every test double with mutable storage makes,
/// confined to this file — the lock serializes the appends and the reads, and the list is only
/// read after the route completed.
final class LedgerPartialSink: PartialTranscriptSink, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var partials: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func presentPartial(_ partial: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(partial)
    }
}

/// **A cleanup provider the test scripts to hang** — the post-cleanup cancellation row: it
/// signals that `clean` started, then suspends cancellation-responsively, so the test can
/// cancel the route task mid-cleanup deterministically (the
/// `ScriptedCleanupProvider.signalAndHang` shape).
private actor HangingCleanupProvider: CleanupProvider {
    let identity = ProviderIdentity(id: "hanging-cleanup", displayName: "Hanging cleanup")
    let budget: Duration = .milliseconds(10)
    nonisolated var requiresNetwork: Bool { false }
    private(set) var cleanStarted = false

    func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        cleanStarted = true
        try await Task.sleep(for: .seconds(3600))
        return ""
    }
}