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

    init(
        segments: [WhisperSegment] = [],
        prepareError: Error? = nil,
        transcribeError: Error? = nil,
        clock: StubClock? = nil,
        prepareAdvance: Duration = .zero,
        transcribeAdvance: Duration = .zero
    ) {
        self.clock = clock
        self.prepareAdvance = prepareAdvance
        self.transcribeAdvance = transcribeAdvance
        lock.withLock { state in
            state.segments = segments
            state.prepareError = prepareError
            state.transcribeError = transcribeError
        }
    }

    var prepareCallCount: Int { lock.withLock { $0.prepareCallCount } }
    var transcribeCallCount: Int { lock.withLock { $0.transcribeCallCount } }
    var preparedModelFileURL: URL? { lock.withLock { $0.preparedModelFileURL } }

    var prepareError: Error? {
        get { lock.withLock { $0.prepareError } }
        set { lock.withLock { $0.prepareError = newValue } }
    }

    var transcribeError: Error? {
        get { lock.withLock { $0.transcribeError } }
        set { lock.withLock { $0.transcribeError = newValue } }
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
    private func makeEngine(
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

    private func buffer(_ samples: [Float] = [1, 2, 3]) -> AudioBuffer {
        AudioBuffer(samples: samples, sampleRate: 16_000)
    }

    // MARK: - Attribution

    /// Every transcript carries ``WhisperCppEngineIdentity/whisper`` — I1's attribution, now on
    /// the real engine — and the engine reports batch-only.
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
        XCTAssertFalse(
            engine.supportsStreaming,
            "the second engine is batch-only — streaming is C7's capability")
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

/// The hand-moved clock: the injected ``MonotonicClock`` the engine measures against — the
/// `TestClock` shape, `@unchecked Sendable` because the shared double is handed into the engine
/// actor (the `TableClock`/`SendableTestClock` precedent): the test — or the stub context it
/// drives — moves `now` by hand, and the engine's two clock reads straddle an exact, asserted
/// delta. Never the wall.
private final class StubClock: MonotonicClock, @unchecked Sendable {
    var now: Duration = .zero
}
