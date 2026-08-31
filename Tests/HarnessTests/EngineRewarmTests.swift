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
import Dispatch
import Foundation
import Synchronization
import VoccaASR
import VoccaCore
import XCTest

/// The `rewarm-after-idle` phase (b) contract: the engines' genuine re-warm path behind the new
/// ``EngineRewarmable`` seam — load-new-then-swap, a failure leaves the previous load usable,
/// the first transcribe after a re-warm is warm and recorded as `.warmTranscribe` (never
/// `.firstAfterLaunch` — the 1.2 launch bound stays launch-pure), and a transcription arriving
/// mid-re-warm waits for the in-flight re-warm.
///
/// The whisper engine is driven headlessly through the ``StubRewarmContext`` seam double (the
/// ``WhisperEngineTests`` shape — no model file, no C call, ever), so the whole mechanism is
/// pinned in CI. The Parakeet engine's `prepare`/`transcribe` remain executed by nothing in CI
/// (the tap-adapter precedent — its model loader returns the SDK's ``AsrModels``, which cannot
/// be fabricated without real CoreML models), so its rows pin what is reachable headlessly: the
/// strict unloaded guard, the `.rewarm` ledger round-trip, and the load-state accounting that
/// makes "a re-attempt never unloads a resident model" a property of the pure bookkeeping.
final class EngineRewarmTests: XCTestCase {

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

    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition did not hold within 2 seconds")
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-rewarm-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        tempRoots.append(root)
        return root
    }

    private func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// The whisper engine over a real store, a stub transport, a hand-moved clock, a shared
    /// timing ledger and the stub context — the ``WhisperEngineTests/makeEngine`` shape.
    private func makeEngine(
        context: StubRewarmContext,
        timing: EngineTiming = EngineTiming()
    ) -> (engine: WhisperCppEngine, root: URL) {
        let root = makeRoot()
        let store = ModelStore(rootURL: root)
        let manifest = ModelManifest(engineID: engineID, version: version, files: [
            ManifestFile(name: modelFile, sha256: sha256Hex([0x01]), byteCount: 1),
        ])
        let engine = WhisperCppEngine(
            store: store,
            manifest: manifest,
            transport: StubTransport(files: [modelFile: [0x01]]),
            clock: RewarmTestClock(),
            timing: timing,
            context: context)
        return (engine, root)
    }

    /// The Parakeet engine for the guard row: a real store over a temp root, the shipped
    /// manifest, the unused transport — never loaded, so only the strict guard is reachable.
    private func makeParakeetEngine() throws -> ParakeetEngine {
        let manifestURL = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaASR/Models/Manifests/parakeet-tdt-0.6b-v3.json")
        let manifest = try ModelManifest.load(from: Data(contentsOf: manifestURL))
        return ParakeetEngine(
            store: ModelStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("vocca-rewarm-parakeet-\(UUID().uuidString)")),
            manifest: manifest,
            transport: DefaultModelTransport(baseURL: URL(string: "https://unused.invalid")!),
            clock: RewarmTestClock())
    }

    /// A 16 kHz mono buffer of the given samples.
    private func buffer(_ samples: [Float] = [1, 2, 3]) -> AudioBuffer {
        AudioBuffer(samples: samples, sampleRate: 16_000)
    }

    // MARK: - Whisper: the five re-warm rows over the stub context

    /// The re-warm re-runs the context's re-prepare exactly once (never a second `prepare`) and
    /// records exactly one `.rewarm` sample — the load-once ledger's fourth kind.
    func testWhisperRewarmReloadsTheContextExactlyOnceAndRecordsTheRewarmRow() async throws {
        let context = StubRewarmContext()
        let timing = EngineTiming()
        let (engine, _) = makeEngine(context: context, timing: timing)

        try await engine.prepare()
        try await engine.rewarm()

        XCTAssertEqual(context.prepareCallCount, 1, "the re-warm must not re-run prepare")
        XCTAssertEqual(context.reprepareCallCount, 1, "the re-warm re-prepares the context exactly once")
        let samples = await timing.samples(for: .rewarm)
        XCTAssertEqual(samples.count, 1, "the re-warm records exactly one .rewarm row")
        let transcript = try await engine.transcribe(buffer())
        XCTAssertEqual(
            transcript.engine, WhisperCppEngineIdentity.whisper,
            "the engine stays fully usable after the re-warm")
    }

    /// The first transcribe **after** a re-warm is warm: `transcribedSinceLoad` is not reset by
    /// the re-warm, so `.firstAfterLaunch` stays launch-only — a re-warm can never pollute the
    /// 1.2 launch bound — while a transcribe before any re-warm still records `.firstAfterLaunch`.
    func testWhisperTheFirstTranscribeAfterARewarmIsWarmNotFirstAfterLaunch() async throws {
        let context = StubRewarmContext()
        let timing = EngineTiming()
        let (engine, _) = makeEngine(context: context, timing: timing)

        try await engine.prepare()
        _ = try await engine.transcribe(buffer())
        try await engine.rewarm()
        _ = try await engine.transcribe(buffer())

        let first = await timing.samples(for: .firstAfterLaunch)
        let warm = await timing.samples(for: .warmTranscribe)
        let rewarm = await timing.samples(for: .rewarm)
        XCTAssertEqual(first.count, 1, "a transcribe before any re-warm still records .firstAfterLaunch")
        XCTAssertEqual(
            warm.count, 1,
            "the first transcribe after a re-warm is .warmTranscribe — never a second .firstAfterLaunch")
        XCTAssertEqual(rewarm.count, 1)
    }

    /// A failing re-warm surfaces as `modelUnavailable` and leaves the previous load fully
    /// usable — the old context survives untouched (swap-on-success).
    func testWhisperAFailingRewarmLeavesTheOldContextUsable() async throws {
        let context = StubRewarmContext()
        let (engine, _) = makeEngine(context: context)
        try await engine.prepare()
        _ = try await engine.transcribe(buffer())

        context.reprepareError = StubRewarmError.reprepareRefused
        do {
            try await engine.rewarm()
            XCTFail("a refusing re-prepare must fail the re-warm")
        } catch let error as VoccaError {
            guard case .modelUnavailable = error else {
                XCTFail("expected modelUnavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("expected VoccaError.modelUnavailable, got \(error)")
        }

        context.reprepareError = nil
        let transcript = try await engine.transcribe(buffer())
        XCTAssertEqual(
            transcript.engine, WhisperCppEngineIdentity.whisper,
            "after a failed re-warm the old context must still transcribe")
    }

    /// A transcription arriving mid-re-warm waits for the in-flight re-warm — the Q5 ordering
    /// pin, engine half: while the re-prepare is parked, the transcribe cannot complete; it does
    /// only after the re-warm does.
    func testWhisperATranscribeArrivingMidRewarmWaitsForIt() async throws {
        let context = StubRewarmContext(parkReprepare: true)
        let (engine, _) = makeEngine(context: context)
        try await engine.prepare()

        let rewarm = Task { try await engine.rewarm() }
        await waitUntil { context.reprepareCallCount == 1 }

        let done = Mutex(false)
        let samples = buffer()
        let transcribe = Task { () -> Transcript in
            defer { done.withLock { $0 = true } }
            return try await engine.transcribe(samples)
        }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(
            done.withLock { $0 },
            "a transcription arriving mid-re-warm must wait for it — the first dictation after idle is deterministically warm")

        context.openReprepareGate()
        try await rewarm.value
        let transcript = try await transcribe.value
        XCTAssertEqual(transcript.engine, WhisperCppEngineIdentity.whisper)
    }

    /// The strict guard: `rewarm()` on an engine that has never loaded throws — the resolver
    /// routes the unprepared case, and a silent no-op is never an option.
    func testWhisperRewarmOnAnUnloadedEngineThrows() async throws {
        let (engine, _) = makeEngine(context: StubRewarmContext())
        do {
            try await engine.rewarm()
            XCTFail("a re-warm without a load must throw")
        } catch let error as VoccaError {
            guard case .modelUnavailable = error else {
                XCTFail("expected modelUnavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("expected VoccaError.modelUnavailable, got \(error)")
        }
    }

    // MARK: - Parakeet: the headless-reachable rows

    /// The strict guard, on the real Parakeet engine — the one row of its re-warm surface CI can
    /// reach: the engine has never loaded, so `rewarm()` throws `modelUnavailable` loudly.
    func testParakeetRewarmOnAnUnloadedEngineThrows() async throws {
        let engine = try makeParakeetEngine()
        do {
            try await engine.rewarm()
            XCTFail("a re-warm without a load must throw")
        } catch let error as VoccaError {
            guard case .modelUnavailable = error else {
                XCTFail("expected modelUnavailable, got \(error)")
                return
            }
        } catch {
            XCTFail("expected VoccaError.modelUnavailable, got \(error)")
        }
    }

    /// The load-state accounting the re-warm runs on: a re-attempt on a loaded engine counts
    /// (the ledger shows two attempts) while `hasLoaded` stays true throughout — and a failed
    /// re-warm never reads as an unloaded engine, so the next transcribe keeps working.
    func testParakeetLoadStateCountsARewarmAttemptWithoutLosingLoaded() {
        var state = ParakeetLoadState()
        state.beginAttempt()
        state.complete()
        XCTAssertTrue(state.hasLoaded)
        XCTAssertEqual(state.loadAttempts, 1)

        state.beginAttempt()
        XCTAssertEqual(state.loadAttempts, 2, "the re-warm's attempt counts in the ledger")
        XCTAssertTrue(state.hasLoaded, "a re-warm attempt must never unload a resident model")

        state.fail()
        XCTAssertTrue(state.hasLoaded, "a failed re-warm leaves the previous load usable")
    }

    /// The whisper load state's documented promise (`WhisperLoadState.swift:48-55`): a
    /// re-`prepare` on `.prepared` is a no-op and never unloads a resident model, and a failed
    /// re-warm never regresses a completed load.
    func testWhisperLoadStateKeepsAResidentModelResidentAcrossARewarmAttempt() {
        var state = WhisperLoadState()
        state.beginAttempt()
        state.complete()
        XCTAssertTrue(state.hasLoaded)

        state.beginAttempt()
        XCTAssertTrue(state.hasLoaded, "a re-attempt on a prepared engine is a no-op and never unloads")

        state.fail()
        XCTAssertTrue(state.hasLoaded, "a failed re-warm never regresses a completed load")
    }

    // MARK: - The ledger

    /// The `.rewarm` kind round-trips what `record(.rewarm, ...)` wrote, and lives beside the
    /// other kinds without touching them — the fourth `EngineTiming.Kind`, recorded never gated.
    func testTheRewarmSampleRoundTripsThroughTheLedger() async {
        let timing = EngineTiming()
        let elapsed: Duration = .milliseconds(123)
        await timing.record(.rewarm, elapsed: elapsed)
        let samples = await timing.samples(for: .rewarm)
        XCTAssertEqual(samples, [elapsed])
        let coldLoad = await timing.samples(for: .coldLoad)
        let firstAfterLaunch = await timing.samples(for: .firstAfterLaunch)
        XCTAssertTrue(coldLoad.isEmpty, "a .rewarm row is its own kind")
        XCTAssertTrue(firstAfterLaunch.isEmpty)
    }
}

/// The whisper context double with a re-prepare half — the ``WhisperEngineTests``
/// ``StubWhisperContext`` shape, extended for the re-warm rows: call counts, scripted errors,
/// and a park gate so the mid-re-warm ordering row has a deterministic suspension point.
private final class StubRewarmContext: WhisperContext, Sendable {

    private struct State {
        var prepareCallCount = 0
        var reprepareCallCount = 0
        var transcribeCallCount = 0
        var prepareError: Error?
        var reprepareError: Error?
        var parkReprepare = false
        var segments: [WhisperSegment]
    }

    private let lock = Mutex<State>(
        State(
            prepareCallCount: 0, reprepareCallCount: 0, transcribeCallCount: 0,
            prepareError: nil, reprepareError: nil, parkReprepare: false,
            segments: []))
    /// The park gate: a semaphore the re-prepare blocks on while armed — the queue-pin's
    /// deterministic suspension point (the engine actor is parked inside the sync seam call,
    /// so a transcribe queued behind it cannot complete until the gate opens).
    private let reprepareGate = DispatchSemaphore(value: 0)

    init(parkReprepare: Bool = false) {
        lock.withLock { $0.parkReprepare = parkReprepare }
    }

    var prepareCallCount: Int { lock.withLock { $0.prepareCallCount } }
    var reprepareCallCount: Int { lock.withLock { $0.reprepareCallCount } }

    var reprepareError: Error? {
        get { lock.withLock { $0.reprepareError } }
        set { lock.withLock { $0.reprepareError = newValue } }
    }

    func prepare(modelFileURL: URL) throws {
        let error: Error? = lock.withLock { state in
            state.prepareCallCount += 1
            return state.prepareError
        }
        if let error { throw error }
    }

    func reprepare(modelFileURL: URL) throws {
        let shouldPark: Bool = lock.withLock { state in
            state.reprepareCallCount += 1
            return state.parkReprepare
        }
        if let error = lock.withLock({ $0.reprepareError }) { throw error }
        if shouldPark {
            reprepareGate.wait()
        }
    }

    func transcribe(samples: [Float]) throws -> [WhisperSegment] {
        lock.withLock { state in
            state.transcribeCallCount += 1
            return state.segments
        }
    }

    func openReprepareGate() {
        reprepareGate.signal()
    }
}

/// The re-prepare's own failure vocabulary — the engine's error mapping must carry it intact.
private enum StubRewarmError: Error, Equatable {
    case reprepareRefused
}

/// The hand-moved clock the engine rows use — `@unchecked Sendable` because it crosses into the
/// engine actors, the ``WhisperEngineTests`` ``StubClock`` shape.
private final class RewarmTestClock: MonotonicClock, @unchecked Sendable {
    var now: Duration = .zero
}