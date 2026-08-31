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

import CryptoKit
import Foundation
import Synchronization
import VoccaASR
import VoccaCore
import XCTest

/// The engine's test double: a ``WhisperContext`` that records its calls and answers from
/// injected state — the same role `StubEngine` plays for the seam, one level down. Every engine
/// behavior test drives this instead of ``WhisperCAPI``, so no model file, no GPU and no C call
/// ever enter the suite.
///
/// The double is `Sendable` (its state lives behind a `Mutex` — the conformance is explicit,
/// because implicit inference does not fire through the noncopyable `Mutex`), since the tests
/// live on the main actor and hand it into the engine actor — while the protocol itself stays
/// deliberately non-`Sendable`, exactly as the production bridge requires. The seam's honesty is
/// the protocol's; the double's convenience is its own.
private final class StubWhisperContext: WhisperContext, Sendable {

    private struct State {
        var prepareCallCount = 0
        var transcribeCallCount = 0
        var preparedModelFileURL: URL?
        var prepareError: Error?
        var transcribeError: Error?
        var segments: [WhisperSegment]
        var streamedScript: [[WhisperSegment]] = []
        var streamedError: Error?
        var transcribeStreamingCallCount = 0
        var streamedSampleCounts: [Int] = []
    }

    private let lock = Mutex<State>(
        State(prepareCallCount: 0, transcribeCallCount: 0, preparedModelFileURL: nil,
              prepareError: nil, transcribeError: nil, segments: []))

    /// The shared hand-moved clock the W4 timing tests drive: `prepare`/`transcribe` advance it
    /// by their fixed steps inside the seam, so the engine's two clock reads straddle an exact,
    /// asserted delta — the `FakeCaptureGraph` stop-advance precedent, one level up.
    private let clock: StubClock?
    private let prepareAdvance: Duration
    private let transcribeAdvance: Duration
    /// The clock advance per `transcribeStreaming` call — the streaming timing row's fixed step,
    /// in the `transcribeAdvance` shape.
    private let streamAdvance: Duration

    init(
        segments: [WhisperSegment] = [],
        prepareError: Error? = nil,
        transcribeError: Error? = nil,
        clock: StubClock? = nil,
        prepareAdvance: Duration = .zero,
        transcribeAdvance: Duration = .zero,
        streamedScript: [[WhisperSegment]] = [],
        streamedError: Error? = nil,
        streamAdvance: Duration = .zero
    ) {
        self.clock = clock
        self.prepareAdvance = prepareAdvance
        self.transcribeAdvance = transcribeAdvance
        self.streamAdvance = streamAdvance
        lock.withLock { state in
            state.segments = segments
            state.prepareError = prepareError
            state.transcribeError = transcribeError
            state.streamedScript = streamedScript
            state.streamedError = streamedError
        }
    }

    var prepareCallCount: Int { lock.withLock { $0.prepareCallCount } }
    var transcribeCallCount: Int { lock.withLock { $0.transcribeCallCount } }
    var preparedModelFileURL: URL? { lock.withLock { $0.preparedModelFileURL } }
    var transcribeStreamingCallCount: Int { lock.withLock { $0.transcribeStreamingCallCount } }
    var streamedSampleCounts: [Int] { lock.withLock { $0.streamedSampleCounts } }

    var prepareError: Error? {
        get { lock.withLock { $0.prepareError } }
        set { lock.withLock { $0.prepareError = newValue } }
    }

    var transcribeError: Error? {
        get { lock.withLock { $0.transcribeError } }
        set { lock.withLock { $0.transcribeError = newValue } }
    }

    var streamedError: Error? {
        get { lock.withLock { $0.streamedError } }
        set { lock.withLock { $0.streamedError = newValue } }
    }

    func prepare(modelFileURL: URL) throws {
        let error: Error? = lock.withLock { state in
            state.prepareCallCount += 1
            state.preparedModelFileURL = modelFileURL
            if let clock { clock.now += prepareAdvance }
            return state.prepareError
        }
        if let error { throw error }
    }

    func transcribe(samples: [Float]) throws -> [WhisperSegment] {
        let answer: (error: Error?, segments: [WhisperSegment]) = lock.withLock { state in
            state.transcribeCallCount += 1
            if let clock { clock.now += transcribeAdvance }
            return (state.transcribeError, state.segments)
        }
        if let error = answer.error { throw error }
        return answer.segments
    }

    /// The streaming half of the scripted seam: records the call and the buffer size it saw,
    /// advances the shared clock by the injected step, throws `streamedError` when set, and
    /// answers from `streamedScript` — one entry per call index, the last entry repeated when
    /// the script is shorter than the call count (the engine's every-chunk decoding outruns a
    /// short script, and the repetition keeps the answer well-defined rather than a trap).
    func transcribeStreaming(samples: [Float]) throws -> [WhisperSegment] {
        let answer: (error: Error?, segments: [WhisperSegment]) = lock.withLock { state in
            let callIndex = state.transcribeStreamingCallCount
            state.transcribeStreamingCallCount += 1
            state.streamedSampleCounts.append(samples.count)
            if let clock { clock.now += streamAdvance }
            let scripted = state.streamedScript
            let segments = scripted.isEmpty
                ? []
                : scripted[min(callIndex, scripted.count - 1)]
            return (state.streamedError, segments)
        }
        if let error = answer.error { throw error }
        return answer.segments
    }
}

/// The stub's own failure vocabulary — sentinels the engine's error mapping must carry intact.
private enum StubContextError: Error, Equatable {
    case prepareRefused
    case transcribeFailed
}

/// The whisper engine's testable behavior (`whisper-engine` plan Phase 3): the engine over an
/// **injected** context — every claim the adapter makes, verified against a stub, with the
/// shipped store and transport in a temporary directory.
///
/// This is `ASREngineSeamTests`'s contract applied to the real second engine, in
/// `ParakeetCoreTests`'s shape: attribution (every transcript carries
/// ``WhisperCppEngineIdentity/whisper``), the empty-buffer policy (a valid empty transcript, and
/// the context is not touched), prepare idempotence (load-once, transport included), and
/// attributable errors (`modelUnavailable` for every prepare failure, `transcriptionFailed` with
/// the underlying cause intact for every transcribe failure).
final class WhisperEngineTests: XCTestCase {

    private let engineID = "whisper-large-v3-turbo"
    private let version = "1"
    private let modelFile = "ggml-large-v3-turbo.bin"

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    /// A fresh temporary store root, cleaned up after the test.
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-whisper-engine-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        return root
    }

    private func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// The engine the tests drive: a real ``ModelStore`` over a stub transport, a stub context,
    /// a hand-moved clock, and a shared ``EngineTiming`` the W4 tests read samples from — the
    /// shipped store/transport shape, the injected context, clock and ledger.
    ///
    /// `fileprivate` so the streaming contract rows in ``WhisperEngineStreamingTests`` (same
    /// file, same seam double) drive the same factory with an explicit root.
    fileprivate func makeEngine(
        context: StubWhisperContext,
        transport: StubTransport,
        root: URL? = nil,
        clock: StubClock = StubClock(),
        timing: EngineTiming = EngineTiming()
    ) -> (engine: WhisperCppEngine, root: URL) {
        let root = root ?? makeRoot()
        let store = ModelStore(rootURL: root)
        let manifest = ModelManifest(engineID: engineID, version: version, files: [
            ManifestFile(name: modelFile, sha256: sha256Hex([0x01]), byteCount: 1),
        ])
        let engine = WhisperCppEngine(
            store: store,
            manifest: manifest,
            transport: transport,
            clock: clock,
            timing: timing,
            context: context)
        return (engine, root)
    }

    /// Pre-commits the model version directly on disk (marker + file), so `downloadIfMissing`
    /// reads present and the transport is never touched.
    private func makePresentModel(under root: URL) {
        let directory = root
            .appendingPathComponent(engineID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! Data([0x01]).write(to: directory.appendingPathComponent(modelFile))
        try! Data().write(to: directory.appendingPathComponent(ModelStore.markerFileName))
    }

    /// The file a happy-path download lands at: `<root>/<engineID>/<version>/<file>`.
    private func resolvedModelURL(under root: URL) -> URL {
        root
            .appendingPathComponent(engineID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent(modelFile)
    }

    /// A 16 kHz mono buffer of the given samples.
    private func buffer(_ samples: [Float] = [1, 2, 3]) -> AudioBuffer {
        AudioBuffer(samples: samples, sampleRate: 16_000)
    }

    // MARK: - Attribution

    /// Every transcript carries ``WhisperCppEngineIdentity/whisper`` — I1's attribution, now on
    /// the real engine — and the engine streams: partials then one final, batch-by-construction.
    func testEveryTranscriptIsAttributedToTheWhisperEngine() async throws {
        let (engine, _) = makeEngine(
            context: StubWhisperContext(segments: [
                WhisperSegment(text: "hello", start: 0.0, end: 0.5, tokenProbability: nil),
            ]),
            transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let transcript = try await engine.transcribe(buffer())

        XCTAssertEqual(transcript.engine, WhisperCppEngineIdentity.whisper)
        XCTAssertEqual(
            transcript.text, "hello",
            "the segment text must reach the transcript — the bridge's answer is the transcript's answer")
        XCTAssertEqual(
            transcript.segments[0].range, 0.0..<0.5,
            "the bridge's seconds must flow through the mapper unaltered")
        XCTAssertTrue(transcript.isFinal)
        XCTAssertEqual(
            transcript.audioDuration, 3.0 / 16_000,
            "the duration comes from the buffer, never from the segments' span")
        XCTAssertEqual(transcript.missingSampleCount, 0)
        XCTAssertTrue(
            engine.supportsStreaming,
            "the second engine streams — partials then one final, the final batch-by-construction")
        XCTAssertEqual(engine.identity, WhisperCppEngineIdentity.whisper)
    }

    // MARK: - Empty buffer

    /// An empty buffer is a valid empty transcript — never an error, and the context is **not
    /// touched** for it: the C layer's answer to empty samples is not something this adapter
    /// should rely on (`ASREngine.swift:28-30`), and the early return happens above the seam.
    func testAnEmptyBufferIsAValidEmptyTranscriptWithoutTouchingTheContext() async throws {
        let context = StubWhisperContext(segments: [WhisperSegment(text: "noise", start: 0, end: 1, tokenProbability: nil)])
        let (engine, _) = makeEngine(context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let transcript = try await engine.transcribe(buffer([]))

        XCTAssertEqual(transcript.text, "")
        XCTAssertEqual(transcript.segments, [])
        XCTAssertEqual(transcript.audioDuration, 0)
        XCTAssertTrue(transcript.isFinal)
        XCTAssertEqual(transcript.engine, WhisperCppEngineIdentity.whisper)
        XCTAssertEqual(
            context.transcribeCallCount, 0,
            "an empty buffer must be answered above the context — no C call for silence")
    }

    /// Transcribing before `prepare()` is the caller's error, surfaced as `modelUnavailable`
    /// (the Parakeet shape): the engine never fabricates a model.
    func testTranscribeBeforePrepareSurfacesAsModelUnavailable() async throws {
        let context = StubWhisperContext()
        let (engine, _) = makeEngine(context: context, transport: StubTransport(files: [:]))

        do {
            _ = try await engine.transcribe(buffer())
            XCTFail("transcribing an unprepared engine must throw")
        } catch let error as VoccaError {
            guard case .modelUnavailable(let identity, let reason) = error else {
                XCTFail("expected modelUnavailable, got \(error)")
                return
            }
            XCTAssertEqual(identity, WhisperCppEngineIdentity.whisper)
            XCTAssertFalse(reason.isEmpty, "the reason must say what is missing")
        } catch {
            XCTFail("expected VoccaError.modelUnavailable, got \(error)")
        }
        XCTAssertEqual(
            context.transcribeCallCount, 0,
            "an unprepared engine must not reach the context at all")
    }

    // MARK: - Prepare

    /// `prepare()` is load-once: the second call no-ops at every layer — no second store
    /// download, no second context initialisation.
    func testPrepareIsIdempotentAndLoadsOnce() async throws {
        let context = StubWhisperContext()
        let transport = StubTransport(files: [modelFile: [0x01]])
        let (engine, _) = makeEngine(context: context, transport: transport)

        try await engine.prepare()
        try await engine.prepare()

        let downloadCount = await transport.downloadCallCount
        XCTAssertEqual(
            downloadCount, 1,
            "the store must download exactly once — the second prepare is a no-op")
        XCTAssertEqual(
            context.prepareCallCount, 1,
            "the context must be created exactly once")
    }

    /// The model file URL handed to the context is exactly `<version-dir>/<file>` — the engine
    /// resolves the store's layout, the bridge never guesses a path.
    func testPrepareHandsTheContextTheResolvedModelFileURL() async throws {
        let context = StubWhisperContext()
        let (engine, root) = makeEngine(context: context, transport: StubTransport(files: [modelFile: [0x01]]))

        try await engine.prepare()

        XCTAssertEqual(
            context.preparedModelFileURL, resolvedModelURL(under: root),
            "the context must receive the store's version directory plus the manifest's file name")
    }

    /// A model that is already present and verified is not downloaded again: zero transport calls
    /// in `prepare` — the store's presence truth, honoured by the engine.
    func testPrepareDoesNotDownloadWhenTheModelIsPresent() async throws {
        let context = StubWhisperContext()
        let root = makeRoot()
        makePresentModel(under: root)
        let transport = StubTransport(files: [:])
        let (engine, _) = makeEngine(context: context, transport: transport, root: root)

        try await engine.prepare()

        let downloadCount = await transport.downloadCallCount
        XCTAssertEqual(
            downloadCount, 0,
            "a verified model must never be downloaded again")
        XCTAssertEqual(context.prepareCallCount, 1)
    }

    /// A failed `prepare` retries on the next call: a transient failure is an honest
    /// `modelUnavailable`, not a permanent dead end (`WhisperLoadState`'s failed state).
    func testAFailedPrepareRetriesOnTheNextCall() async throws {
        let context = StubWhisperContext(prepareError: StubContextError.prepareRefused)
        let transport = StubTransport(files: [modelFile: [0x01]])
        let (engine, _) = makeEngine(context: context, transport: transport)

        do {
            try await engine.prepare()
            XCTFail("a refusing context must fail prepare")
        } catch let error as VoccaError {
            guard case .modelUnavailable = error else {
                XCTFail("expected modelUnavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("expected VoccaError.modelUnavailable, got \(error)")
        }

        context.prepareError = nil
        try await engine.prepare()
        let transcript = try await engine.transcribe(buffer())
        XCTAssertEqual(
            transcript.engine, WhisperCppEngineIdentity.whisper,
            "after a retried prepare the engine must be fully usable")
    }

    // MARK: - Error mapping

    /// A store failure (the transport refused the file) surfaces as `modelUnavailable` with the
    /// engine's identity and a reason — never as a bare transport error leaking past the seam.
    func testAStoreFailureSurfacesAsModelUnavailable() async throws {
        let (engine, _) = makeEngine(
            context: StubWhisperContext(),
            transport: StubTransport(files: [:]))

        do {
            try await engine.prepare()
            XCTFail("a store that cannot deliver the model must fail prepare")
        } catch let error as VoccaError {
            guard case .modelUnavailable(let identity, let reason) = error else {
                XCTFail("expected modelUnavailable, got \(error)")
                return
            }
            XCTAssertEqual(identity, WhisperCppEngineIdentity.whisper)
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("expected VoccaError.modelUnavailable, got \(error)")
        }
    }

    /// A context prepare failure (the model file is missing or corrupt at the C layer) surfaces
    /// as `modelUnavailable` with a reason — the Parakeet shape for every prepare-path failure.
    func testAContextPrepareFailureSurfacesAsModelUnavailable() async throws {
        let context = StubWhisperContext(prepareError: StubContextError.prepareRefused)
        let (engine, _) = makeEngine(context: context, transport: StubTransport(files: [modelFile: [0x01]]))

        do {
            try await engine.prepare()
            XCTFail("a refusing context must fail prepare")
        } catch let error as VoccaError {
            guard case .modelUnavailable(let identity, let reason) = error else {
                XCTFail("expected modelUnavailable, got \(error)")
                return
            }
            XCTAssertEqual(identity, WhisperCppEngineIdentity.whisper)
            XCTAssertFalse(reason.isEmpty, "the reason must carry the underlying cause")
        } catch {
            XCTFail("expected VoccaError.modelUnavailable, got \(error)")
        }
    }

    /// A transcribe failure surfaces as `transcriptionFailed` **with the underlying error intact**
    /// — not stringified, because stringifying throws away the thing a caller needs to diagnose
    /// (`VoccaError.swift:31-33`).
    func testATranscribeFailureSurfacesAsTranscriptionFailedWithTheCauseIntact() async throws {
        let context = StubWhisperContext(transcribeError: StubContextError.transcribeFailed)
        let (engine, _) = makeEngine(context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        do {
            _ = try await engine.transcribe(buffer())
            XCTFail("a failing context must fail transcribe")
        } catch let error as VoccaError {
            guard case .transcriptionFailed(let identity, let underlying) = error else {
                XCTFail("expected transcriptionFailed, got \(error)")
                return
            }
            XCTAssertEqual(identity, WhisperCppEngineIdentity.whisper)
            XCTAssertEqual(
                underlying as? StubContextError, .transcribeFailed,
                "the underlying error must arrive intact, not as a string")
        } catch {
            XCTFail("expected VoccaError.transcriptionFailed, got \(error)")
        }
    }

    // MARK: - Timing (W4: whisper parity)

    /// **W4, cold load.** `prepare()` records a `.coldLoad` sample on the engine's
    /// ``EngineTiming`` whose elapsed equals the injected clock's delta **exactly** — the stub
    /// context makes the load take a measurable time by advancing the shared clock inside
    /// `prepare` (the `FakeCaptureGraph` stop-advance precedent), and the pre-set base proves
    /// the sample is the delta, never an absolute reading.
    func testPrepareRecordsColdLoadWithExactlyTheClockDelta() async throws {
        let clock = StubClock()
        clock.now = .milliseconds(1_000)
        let timing = EngineTiming()
        let context = StubWhisperContext(clock: clock, prepareAdvance: .milliseconds(40))
        let (engine, _) = makeEngine(
            context: context,
            transport: StubTransport(files: [modelFile: [0x01]]),
            clock: clock, timing: timing)

        try await engine.prepare()

        let cold = await timing.samples(for: .coldLoad)
        XCTAssertEqual(
            cold, [.milliseconds(40)],
            "the cold-load sample must equal the clock's delta across the load — never a "
                + "fabricated zero, never an absolute reading")
    }

    /// **W4, failure records nothing.** A failed `prepare` records no `.coldLoad` — Parakeet's
    /// rule (the sample is recorded only on the success path), mirrored exactly.
    func testAFailedPrepareRecordsNoColdLoad() async throws {
        let clock = StubClock()
        let timing = EngineTiming()
        let context = StubWhisperContext(
            prepareError: StubContextError.prepareRefused,
            clock: clock, prepareAdvance: .milliseconds(40))
        let (engine, _) = makeEngine(
            context: context,
            transport: StubTransport(files: [modelFile: [0x01]]),
            clock: clock, timing: timing)

        do {
            try await engine.prepare()
            XCTFail("a refusing context must fail prepare")
        } catch is VoccaError {
        } catch {
            XCTFail("expected VoccaError, got \(error)")
        }

        let cold = await timing.samples(for: .coldLoad)
        XCTAssertEqual(
            cold, [],
            "a failed load must not record a cold-load sample")    }

    /// **W4, the first-transcribe split.** The first successful transcription records
    /// `.firstAfterLaunch`; every later one records `.warmTranscribe` — the same
    /// `transcribedSinceLoad` split Parakeet draws, driven with the same clock-delta discipline.
    func testFirstTranscribeRecordsFirstAfterLaunchAndLaterOnesRecordWarm() async throws {
        let clock = StubClock()
        let timing = EngineTiming()
        let context = StubWhisperContext(clock: clock, transcribeAdvance: .milliseconds(5))
        let (engine, _) = makeEngine(
            context: context,
            transport: StubTransport(files: [modelFile: [0x01]]),
            clock: clock, timing: timing)
        try await engine.prepare()

        _ = try await engine.transcribe(buffer())
        _ = try await engine.transcribe(buffer())

        let first = await timing.samples(for: .firstAfterLaunch)
        let warm = await timing.samples(for: .warmTranscribe)
        XCTAssertEqual(
            first, [.milliseconds(5)],
            "the first transcription after launch is measured apart from the warm steady state")
        XCTAssertEqual(warm, [.milliseconds(5)])
        XCTAssertEqual(
            first.count, 1,
            "only the first transcription may claim firstAfterLaunch — the split is one-shot")
        XCTAssertEqual(
            warm.count, 1,
            "the second transcription must land in the warm ledger, not the first column")
    }

    /// **W4, the empty-buffer silence.** An empty buffer is answered above the seam — no clock
    /// read, no transcription, nothing recorded: the ledger must not count a non-transcription.
    func testAnEmptyBufferTranscribeRecordsNoTiming() async throws {
        let clock = StubClock()
        let timing = EngineTiming()
        let context = StubWhisperContext(clock: clock, transcribeAdvance: .milliseconds(5))
        let (engine, _) = makeEngine(
            context: context,
            transport: StubTransport(files: [modelFile: [0x01]]),
            clock: clock, timing: timing)
        try await engine.prepare()

        let transcript = try await engine.transcribe(buffer([]))

        XCTAssertEqual(transcript.text, "")
        let first = await timing.samples(for: .firstAfterLaunch)
        let warm = await timing.samples(for: .warmTranscribe)
        XCTAssertEqual(first, [])
        XCTAssertEqual(warm, [])
    }

    /// **W4, a failed transcription records nothing — and does not consume the first slot.** A
    /// transcribe failure records no sample, and the next successful transcription is still
    /// `firstAfterLaunch` — the split flips only on success, exactly as Parakeet's
    /// `transcribedSinceLoad` bookkeeping draws it.
    func testAFailedTranscribeRecordsNothingAndDoesNotConsumeTheFirstSlot() async throws {
        let clock = StubClock()
        let timing = EngineTiming()
        let context = StubWhisperContext(
            transcribeError: StubContextError.transcribeFailed,
            clock: clock, transcribeAdvance: .milliseconds(5))
        let (engine, _) = makeEngine(
            context: context,
            transport: StubTransport(files: [modelFile: [0x01]]),
            clock: clock, timing: timing)
        try await engine.prepare()

        do {
            _ = try await engine.transcribe(buffer())
            XCTFail("a failing context must fail transcribe")
        } catch is VoccaError {
        } catch {
            XCTFail("expected VoccaError, got \(error)")
        }

        var first = await timing.samples(for: .firstAfterLaunch)
        var warm = await timing.samples(for: .warmTranscribe)
        XCTAssertEqual(first, [])
        XCTAssertEqual(warm, [])

        context.transcribeError = nil
        _ = try await engine.transcribe(buffer())

        first = await timing.samples(for: .firstAfterLaunch)
        warm = await timing.samples(for: .warmTranscribe)
        XCTAssertEqual(
            first, [.milliseconds(5)],
            "a failed transcription must not consume the one-shot firstAfterLaunch slot")
        XCTAssertEqual(warm, [])
    }

    // MARK: - Offline

    /// Transcription never touches the transport: the store is the only path to the outside
    /// world, and it is not on the transcribe path (`spec.md` acceptance criterion 5).
    func testTranscribeNeverCallsTheTransport() async throws {
        let transport = StubTransport(files: [modelFile: [0x01]])
        let (engine, _) = makeEngine(context: StubWhisperContext(), transport: transport)
        try await engine.prepare()
        let afterPrepare = await transport.downloadCallCount
        XCTAssertEqual(afterPrepare, 1)

        _ = try await engine.transcribe(buffer([1, 2, 3]))
        _ = try await engine.transcribe(buffer([4, 5]))

        let afterTranscribes = await transport.downloadCallCount
        XCTAssertEqual(
            afterTranscribes, afterPrepare,
            "transcribe must not cause a single transport call — the model is resident and the "
                + "engine's only contact with the outside world is the injected store")
    }
}

/// The whisper streaming contract rows (`whisper-streaming` plan Phase a): the engine's `stream`
/// over the same injected seam double, driven by `StubWhisperContext`'s scripted streaming half.
///
/// Every row is headless — no model file, no GPU, no C call, ever. What they prove is the
/// **engine half** of the streaming claim: partials then exactly one final; the final is the last
/// decode's segments, mapped identically to the batch path (the *C* half — same params ⇒ same
/// segments — is the by-construction claim, verified at `SMOKE_CHECKLIST.md` step 19, never in
/// CI); a stream ending mid-utterance terminates cleanly; empty streams answer empty without
/// touching the context; failures and cancellation terminate rather than hang; exactly one
/// timing sample records the final decode; the completeness count accumulates; the transport is
/// never called; and an unprepared engine refuses at the stream's start.
final class WhisperEngineStreamingTests: XCTestCase {

    private let engineID = "whisper-large-v3-turbo"
    private let version = "1"
    private let modelFile = "ggml-large-v3-turbo.bin"

    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    /// A fresh temporary store root, cleaned up after the test — the `WhisperEngineTests`
    /// pattern, owned here so the shared factory is always handed an explicit root (a foreign
    /// instance's own bookkeeping would otherwise leak the directory).
    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-whisper-engine-streaming-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        return root
    }

    /// The chunk producer every row drives: a bounded `AsyncStream` yielding the buffers then
    /// finishing — the seam's only end signal.
    private func chunkStream(_ buffers: [AudioBuffer]) -> AsyncStream<AudioBuffer> {
        AsyncStream { continuation in
            for buffer in buffers {
                continuation.yield(buffer)
            }
            continuation.finish()
        }
    }

    /// A 16 kHz mono buffer of the given samples — the `WhisperEngineTests` helper, local here.
    private func buffer(_ samples: [Float] = [1, 2, 3]) -> AudioBuffer {
        AudioBuffer(samples: samples, sampleRate: 16_000)
    }

    /// Consumes a stream to its terminal, collecting the yields and the terminal error — the
    /// same shape every row asserts on, so no row can forget to drain.
    private func collect(
        _ stream: AsyncThrowingStream<Transcript, Error>
    ) async -> (yields: [Transcript], error: Error?) {
        var yields: [Transcript] = []
        var terminal: Error?
        do {
            for try await transcript in stream {
                yields.append(transcript)
            }
        } catch {
            terminal = error
        }
        return (yields, terminal)
    }

    /// The engine under test: the shared factory, driven with an explicit root.
    private func makeEngine(
        context: StubWhisperContext,
        transport: StubTransport,
        clock: StubClock = StubClock(),
        timing: EngineTiming = EngineTiming()
    ) -> (engine: WhisperCppEngine, root: URL) {
        WhisperEngineTests().makeEngine(
            context: context, transport: transport, root: makeRoot(), clock: clock, timing: timing)
    }

    // MARK: - The contract rows

    /// **Partials then one final.** The scripted seam answers two decodes; three chunks are
    /// fed, the third empty — silence past the answer, which must not decode (no C call for
    /// silence, the batch empty-buffer policy in stream shape). The yielded order is
    /// partial("hello"), partial("hello world"), final("hello world"): exactly one final, the
    /// last element, every partial non-final, nothing after the final, every transcript
    /// attributed to whisper, and the decodes saw the growing buffer (3, then 6 samples).
    func testPartialsThenOneFinalInOrder() async throws {
        let context = StubWhisperContext(streamedScript: [
            [WhisperSegment(text: "hello", start: 0.0, end: 0.4, tokenProbability: nil)],
            [
                WhisperSegment(text: "hello", start: 0.0, end: 0.4, tokenProbability: nil),
                WhisperSegment(text: "world", start: 0.4, end: 0.9, tokenProbability: nil),
            ],
        ])
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let (yields, error) = await collect(engine.stream(chunkStream([
            buffer([1, 2, 3]),
            buffer([4, 5, 6]),
            buffer([]),
        ])))

        XCTAssertNil(error)
        XCTAssertEqual(
            yields.map(\.text), ["hello", "hello world", "hello world"],
            "partials then exactly one final, in order")
        XCTAssertEqual(
            yields.map(\.isFinal), [false, false, true],
            "exactly one final and it is the last element; every partial is non-final")
        XCTAssertTrue(
            yields.allSatisfy { $0.engine == WhisperCppEngineIdentity.whisper },
            "every transcript carries the whisper attribution (I1)")
        XCTAssertEqual(
            context.transcribeStreamingCallCount, 2,
            "no decode for the trailing empty chunk — silence past the accumulated answer")
        XCTAssertEqual(
            context.streamedSampleCounts, [3, 6],
            "each decode sees the whole buffer grown so far")
    }

    /// **Final equals batch by construction — the engine half.** The same audio two ways:
    /// `stream` over three chunks with the script's last decode answering the same segments the
    /// stub's batch `transcribe` returns for the whole buffer, then `transcribe` of the whole
    /// buffer. The stream's final must equal the batch transcript text-for-text and
    /// segment-for-segment, with attribution, duration and completeness equal.
    ///
    /// What this proves is the *engine* half only: the engine maps the last decode identically
    /// to batch. The *C* half — the streaming params are field-for-field identical to the batch
    /// params, so the same audio yields the same segments — is the by-construction claim,
    /// verified on real audio at `SMOKE_CHECKLIST.md` step 19, never in CI.
    func testTheStreamFinalEqualsTheBatchTranscriptionForTheSameAudio() async throws {
        let batchSegments = [
            WhisperSegment(text: "hello", start: 0.0, end: 0.4, tokenProbability: nil),
            WhisperSegment(text: "world", start: 0.4, end: 0.9, tokenProbability: nil),
        ]
        let context = StubWhisperContext(
            segments: batchSegments,
            streamedScript: [
                [WhisperSegment(text: "hello", start: 0.0, end: 0.4, tokenProbability: nil)],
                batchSegments,
            ])
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let (yields, error) = await collect(engine.stream(chunkStream([
            buffer([1, 2, 3]),
            buffer([4, 5, 6]),
            buffer([7, 8, 9]),
        ])))
        XCTAssertNil(error)
        let streamFinal = try XCTUnwrap(yields.last)
        let batchTranscript = try await engine.transcribe(buffer([1, 2, 3, 4, 5, 6, 7, 8, 9]))

        XCTAssertEqual(
            streamFinal.text, batchTranscript.text,
            "the streamed final's text must equal the batch transcript's text")
        XCTAssertEqual(
            streamFinal.segments, batchTranscript.segments,
            "segment-for-segment equality — the last decode maps identically to batch")
        XCTAssertEqual(streamFinal.engine, batchTranscript.engine)
        XCTAssertEqual(streamFinal.audioDuration, batchTranscript.audioDuration)
        XCTAssertEqual(streamFinal.missingSampleCount, batchTranscript.missingSampleCount)
        XCTAssertTrue(streamFinal.isFinal)
    }

    /// **A stream ending mid-utterance terminates cleanly.** The chunk source yields two chunks
    /// and finishes — no key-up, no cancellation — and the stream must end with the partials so
    /// far (one per decode), then exactly one final (the last decode's segments), without
    /// throwing.
    func testAStreamEndingMidUtteranceTerminatesCleanlyWithPartialsThenOneFinal() async throws {
        let context = StubWhisperContext(streamedScript: [
            [WhisperSegment(text: "hello", start: 0.0, end: 0.4, tokenProbability: nil)],
            [
                WhisperSegment(text: "hello", start: 0.0, end: 0.4, tokenProbability: nil),
                WhisperSegment(text: "world", start: 0.4, end: 0.9, tokenProbability: nil),
            ],
        ])
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let (yields, error) = await collect(engine.stream(chunkStream([
            buffer([1, 2, 3]),
            buffer([4, 5, 6]),
        ])))

        XCTAssertNil(error, "a chunk-source end is a clean finish, never a throw")
        XCTAssertEqual(
            yields.map(\.text), ["hello", "hello world", "hello world"],
            "partials so far, then exactly one final — the last decode's segments")
        XCTAssertEqual(yields.map(\.isFinal), [false, false, true])
    }

    /// **Empty stream:** zero chunks transcribe as one empty final, never a throw, and the
    /// context is never called — the batch empty-buffer policy (`ASREngine.swift:28-37`) in
    /// stream shape.
    func testAnEmptyStreamYieldsExactlyOneEmptyFinalWithoutTouchingTheContext() async throws {
        let context = StubWhisperContext(streamedScript: [
            [WhisperSegment(text: "noise", start: 0, end: 1, tokenProbability: nil)],
        ])
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let (yields, error) = await collect(engine.stream(chunkStream([])))

        XCTAssertNil(error)
        XCTAssertEqual(yields.count, 1)
        XCTAssertEqual(yields[0].text, "")
        XCTAssertEqual(yields[0].segments, [])
        XCTAssertTrue(yields[0].isFinal)
        XCTAssertEqual(
            context.transcribeStreamingCallCount, 0,
            "no C call for silence — the empty stream is answered above the context")
    }

    /// **All-empty chunks:** the same answer as an empty stream — no decode, one empty final,
    /// context untouched.
    func testAllEmptyChunksYieldOneEmptyFinalWithoutTouchingTheContext() async throws {
        let context = StubWhisperContext(streamedScript: [
            [WhisperSegment(text: "noise", start: 0, end: 1, tokenProbability: nil)],
        ])
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let (yields, error) = await collect(engine.stream(chunkStream([
            buffer([]),
            buffer([]),
            buffer([]),
        ])))

        XCTAssertNil(error)
        XCTAssertEqual(yields.count, 1)
        XCTAssertEqual(yields[0].text, "")
        XCTAssertTrue(yields[0].isFinal)
        XCTAssertEqual(context.transcribeStreamingCallCount, 0)
    }

    /// **A decode failure mid-stream** finishes the stream **throwing**
    /// ``VoccaError/transcriptionFailed(_:underlying:)`` with the underlying error intact, and
    /// nothing is yielded after the throw — no partial for the failing decode, no final (the
    /// `WhisperEngineTests.swift:405-425` shape, streamed).
    func testADecodeFailureMidStreamFinishesThrowingWithTheCauseIntact() async throws {
        let context = StubWhisperContext(streamedError: StubContextError.transcribeFailed)
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let (yields, error) = await collect(engine.stream(chunkStream([
            buffer([1, 2, 3]),
            buffer([4, 5, 6]),
            buffer([7, 8, 9]),
        ])))

        XCTAssertTrue(
            yields.isEmpty,
            "nothing is yielded after the throw — no partial for the failing decode, no final")
        guard case .transcriptionFailed(let identity, let underlying)? = error as? VoccaError else {
            XCTFail("expected transcriptionFailed, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(identity, WhisperCppEngineIdentity.whisper)
        XCTAssertEqual(
            underlying as? StubContextError, .transcribeFailed,
            "the underlying error must arrive intact, not as a string")
    }

    /// **Consumer cancellation** terminates the stream: bounded, no hang, no throw. The
    /// deterministic half is the mid-utterance row; this row pins the no-hang shape — a
    /// consumer that stops early cancels itself, the producer's cancellation yields its
    /// accumulated final into a terminated continuation (a no-op), and the stream ends. The
    /// iterator's own `CancellationError` is the consumer's self-inflicted exit, not a failure
    /// of the stream.
    func testCancellingTheConsumerTerminatesTheStreamWithoutHangingOrThrowing() async throws {
        let context = StubWhisperContext(streamedScript: [
            [WhisperSegment(text: "hello", start: 0.0, end: 0.4, tokenProbability: nil)],
        ])
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let stream = engine.stream(chunkStream([
            buffer([1, 2, 3]),
            buffer([4, 5, 6]),
            buffer([7, 8, 9]),
            buffer([10, 11, 12]),
        ]))
        let terminated = expectation(description: "the stream terminates after the consumer cancels")
        let unexpected = Mutex<Error?>(nil)
        _ = Task {
            do {
                for try await _ in stream {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            } catch is CancellationError {
                // Self-inflicted: the consumer cancelled itself mid-iteration.
            } catch {
                unexpected.withLock { $0 = error }
            }
            terminated.fulfill()
        }
        await fulfillment(of: [terminated], timeout: 5)
        XCTAssertNil(
            unexpected.withLock { $0 },
            "the stream must not throw a transcription error: \(String(describing: unexpected.withLock { $0 }))")
    }

    /// **Timing: exactly one sample — the final decode's.** Three decodes advance the shared
    /// clock by the injected step each; the ledger must hold exactly one sample, the last
    /// decode's elapsed, under `.firstAfterLaunch` for the first stream and `.warmTranscribe`
    /// after a prior transcription — and an all-empty-chunks stream records nothing and does
    /// not flip the split (the `transcribedSinceLoad` flip is success-only).
    func testTheStreamRecordsExactlyOneTimingSampleForTheFinalDecode() async throws {
        let clock = StubClock()
        let timing = EngineTiming()
        let context = StubWhisperContext(
            clock: clock,
            streamedScript: [
                [WhisperSegment(text: "hello", start: 0.0, end: 0.4, tokenProbability: nil)],
                [
                    WhisperSegment(text: "hello", start: 0.0, end: 0.4, tokenProbability: nil),
                    WhisperSegment(text: "world", start: 0.4, end: 0.9, tokenProbability: nil),
                ],
            ],
            streamAdvance: .milliseconds(5))
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [modelFile: [0x01]]),
            clock: clock, timing: timing)
        try await engine.prepare()

        _ = await collect(engine.stream(chunkStream([
            buffer([1, 2, 3]),
            buffer([4, 5, 6]),
            buffer([7, 8, 9]),
        ])))

        let first = await timing.samples(for: .firstAfterLaunch)
        let warm = await timing.samples(for: .warmTranscribe)
        XCTAssertEqual(
            first, [.milliseconds(5)],
            "exactly one sample, the final decode's clock delta — never the three decodes' sum")
        XCTAssertEqual(warm, [])

        // After a prior transcription the same stream records under the warm column.
        let clock2 = StubClock()
        let timing2 = EngineTiming()
        let context2 = StubWhisperContext(
            clock: clock2, transcribeAdvance: .milliseconds(3),
            streamedScript: [[WhisperSegment(text: "hi", start: 0, end: 0.3, tokenProbability: nil)]],
            streamAdvance: .milliseconds(5))
        let (engine2, _) = makeEngine(
            context: context2, transport: StubTransport(files: [modelFile: [0x01]]),
            clock: clock2, timing: timing2)
        try await engine2.prepare()
        _ = try await engine2.transcribe(buffer([1, 2, 3]))
        _ = await collect(engine2.stream(chunkStream([buffer([4, 5, 6])])))

        let warm2 = await timing2.samples(for: .warmTranscribe)
        XCTAssertEqual(warm2, [.milliseconds(5)])
        let first2 = await timing2.samples(for: .firstAfterLaunch)
        XCTAssertEqual(first2, [.milliseconds(3)])

        // An all-empty-chunks stream records nothing and does not flip the split: the next
        // real stream still lands in the first-after-launch column.
        let clock3 = StubClock()
        let timing3 = EngineTiming()
        let context3 = StubWhisperContext(
            clock: clock3,
            streamedScript: [[WhisperSegment(text: "hi", start: 0, end: 0.3, tokenProbability: nil)]],
            streamAdvance: .milliseconds(5))
        let (engine3, _) = makeEngine(
            context: context3, transport: StubTransport(files: [modelFile: [0x01]]),
            clock: clock3, timing: timing3)
        try await engine3.prepare()
        _ = await collect(engine3.stream(chunkStream([buffer([]), buffer([])])))
        _ = await collect(engine3.stream(chunkStream([buffer([1, 2, 3])])))

        let first3 = await timing3.samples(for: .firstAfterLaunch)
        let warm3 = await timing3.samples(for: .warmTranscribe)
        XCTAssertEqual(
            first3, [.milliseconds(5)],
            "a zero-decode stream records nothing and must not consume the one-shot slot")
        XCTAssertEqual(warm3, [])
    }

    /// **Missing-sample accumulation:** the completeness link (I1) survives streaming — the
    /// running sum of the chunks' `missingSampleCount`, capped at the samples it describes,
    /// is carried on every partial and on the final.
    func testMissingSampleCountsAccumulateAcrossPartialsAndTheFinal() async throws {
        let context = StubWhisperContext(streamedScript: [
            [WhisperSegment(text: "hi", start: 0.0, end: 0.3, tokenProbability: nil)],
        ])
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [modelFile: [0x01]]))
        try await engine.prepare()

        let (yields, error) = await collect(engine.stream(chunkStream([
            AudioBuffer(samples: [1], sampleRate: 16_000, missingSampleCount: 1),
            AudioBuffer(samples: [2], sampleRate: 16_000, missingSampleCount: 2),
            AudioBuffer(samples: [3], sampleRate: 16_000, missingSampleCount: 3),
        ])))

        XCTAssertNil(error)
        XCTAssertEqual(
            yields.dropLast().map(\.missingSampleCount), [1, 2, 3],
            "partials carry the running sum, one per decode")
        XCTAssertEqual(
            yields.last?.missingSampleCount, 3,
            "the final carries min(6, samples.count = 3) — the cap keeps the count honest")
    }

    /// **A stream never calls the transport** — the offline row: the model is resident after
    /// `prepare`, and streaming must not cause a single download call (`spec.md` criterion 5,
    /// stream-shaped).
    func testAStreamNeverCallsTheTransport() async throws {
        let transport = StubTransport(files: [modelFile: [0x01]])
        let (engine, _) = makeEngine(
            context: StubWhisperContext(streamedScript: [
                [WhisperSegment(text: "hello", start: 0, end: 0.4, tokenProbability: nil)],
            ]),
            transport: transport)
        try await engine.prepare()
        let afterPrepare = await transport.downloadCallCount
        XCTAssertEqual(afterPrepare, 1)

        _ = await collect(engine.stream(chunkStream([
            buffer([1, 2, 3]),
            buffer([4, 5, 6]),
        ])))

        let afterStream = await transport.downloadCallCount
        XCTAssertEqual(
            afterStream, afterPrepare,
            "a stream must not cause a single transport call — the stream touches only the "
                + "resident model and the injected context")
    }

    /// **Stream before prepare** finishes throwing ``VoccaError/modelUnavailable(_:reason:)``
    /// with the engine's identity and a non-empty reason, before consuming any chunk — the
    /// load-state guard, stream-shaped; the context is never called.
    func testAStreamOnAnUnpreparedEngineFinishesThrowingModelUnavailable() async throws {
        let context = StubWhisperContext()
        let (engine, _) = makeEngine(
            context: context, transport: StubTransport(files: [:]))

        let (yields, error) = await collect(engine.stream(chunkStream([buffer([1, 2, 3])])))

        XCTAssertTrue(yields.isEmpty)
        guard case .modelUnavailable(let identity, let reason)? = error as? VoccaError else {
            XCTFail("expected modelUnavailable, got \(String(describing: error))")
            return
        }
        XCTAssertEqual(identity, WhisperCppEngineIdentity.whisper)
        XCTAssertFalse(reason.isEmpty, "the reason must say what is missing")
        XCTAssertEqual(
            context.transcribeStreamingCallCount, 0,
            "an unprepared engine must not reach the context at all")
    }
}

/// The hand-moved clock: the injected ``MonotonicClock`` the engine measures against — the
/// `TestClock` shape, `@unchecked Sendable` because the shared double is handed into the engine
/// actor (the `TableClock`/`SendableTestClock` precedent): the test — or the stub context it
/// drives — moves `now` by hand, and the engine's two clock reads straddle an exact, asserted
/// delta. Never the wall.
private final class StubClock: MonotonicClock, @unchecked Sendable {
    var now: Duration = .zero
}
