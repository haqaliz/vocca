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

/// The `loop-wiring` Task 2 lifecycle contract: **one engine for the process**, resolved from the
/// selection at the first preparation, warmed by a single-flight background `prepare()`, and
/// gated — `engineIfReady()` answers only once preparation succeeded.
///
/// Four promises are pinned here:
///
/// - **Resolve-once**: the injected ``EngineBuilding`` closure runs exactly once, with the
///   resolver's own ``EngineSelection``, no matter how many times `prepareIfNeeded()` is called
///   (PRD R2 — "resolves once at launch", `prd.md:73-78`).
/// - **Single-flight prepare**: two concurrent `prepareIfNeeded()` calls share one `prepare()`
///   on the engine — the second awaits the in-flight one, it never starts a second warm-up
///   (the ``ModelStore`` one-flight guard, `ModelStore.swift:59-62`, in the resolver's shape).
/// - **The readiness gate**: `engineIfReady()` is `nil` and `isPrepared` is `false` until
///   `prepare()` has succeeded — an unprepared engine refuses honestly (PRD R5's
///   `.modelUnavailable`) *before* the session opens the microphone.
/// - **A prepare failure surfaces its reason and does not poison the next attempt**: the
///   caller receives the underlying error intact; readiness stays `nil`; and a later
///   `prepareIfNeeded()` retries on the **same** engine — resolve-once holds across failures.
///
/// The engine double is scripted per test (park-at-a-gate for the single-flight proof, a fixed
/// failure for the refusal row) and is an actor for the repo's boundary doctrine
/// (`ASRTestDoubles.swift:36-38`); the builder ledger records every invocation so "exactly once"
/// is a count, not an assumption.
final class DictationEngineResolverTests: XCTestCase {

    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition did not hold within 2 seconds")
    }

    // MARK: - Resolve-once

    /// The builder runs exactly once, with the resolver's own selection, no matter how many
    /// times preparation is asked for — a second `prepareIfNeeded()` after success is a no-op.
    /// The readiness gate answers the **same** engine object the builder produced.
    func testTheBuilderRunsExactlyOnceAcrossRepeatedPrepares() async throws {
        let ledger = BuilderLedger()
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })

        let notPrepared = await resolver.isPrepared
        XCTAssertFalse(notPrepared)
        let notReady = await resolver.engineIfReady()
        XCTAssertNil(notReady)

        try await resolver.prepareIfNeeded()
        try await resolver.prepareIfNeeded()

        let selections = await ledger.selections
        XCTAssertEqual(selections, [.defaultSelection],
            "the builder is called exactly once, with the resolver's own selection")
        let built = await ledger.built as? StubEngine
        XCTAssertNotNil(built)
        let prepareCalls = await built?.prepareCount
        XCTAssertEqual(prepareCalls, 1, "a repeated prepare must not re-warm an engine")
        let isPrepared = await resolver.isPrepared
        XCTAssertTrue(isPrepared)
        let ready = await resolver.engineIfReady() as? StubEngine
        XCTAssertTrue(ready === built,
            "the readiness gate answers the one engine the process resolved, not a copy")
    }

    /// The selection the resolver was given is the selection the builder sees — the root wires
    /// the picker's answer through, so a non-default selection must arrive intact.
    func testTheBuildersSelectionIsTheResolversOwn() async throws {
        let ledger = BuilderLedger()
        let selection = EngineSelection(tier: .whisperTurbo)
        let resolver = DictationEngineResolver(
            selection: selection,
            building: { selection in await ledger.build(selection) })

        try await resolver.prepareIfNeeded()

        let selections = await ledger.selections
        XCTAssertEqual(selections, [selection],
            "the resolver hands the builder exactly the selection it was given")
        let built = await ledger.built
        XCTAssertNotNil(built)
    }

    // MARK: - Single-flight

    /// Two concurrent `prepareIfNeeded()` calls share one prepare: while the first is parked
    /// inside the engine's `prepare()`, no second call may start another — the count stays one
    /// — and both callers complete when the gate opens. Without the one-flight guard the second
    /// call runs `prepare()` too and the parked count is two (the ``ModelStore`` proof shape,
    /// `ModelStoreTests.swift:290-322`).
    func testTwoConcurrentPreparesAreSingleFlight() async throws {
        let engine = GatedPrepareEngine(behavior: .park)
        let ledger = BuilderLedger(engine: engine)
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })

        async let first: Void = resolver.prepareIfNeeded()
        async let second: Void = resolver.prepareIfNeeded()

        await waitUntil {
            let calls = await engine.prepareCalls
            let parked = await engine.parkedPreparations
            return calls == 1 && parked == 1
        }
        let countWhileParked = await engine.prepareCalls
        XCTAssertEqual(
            countWhileParked, 1,
            "while the first prepare is parked in the engine, no second prepare may start")
        let buildsWhileParked = await ledger.buildCount
        XCTAssertEqual(buildsWhileParked, 1,
            "the one-flight guard covers resolution too — the builder must not re-run")

        await engine.openGate()
        try await first
        try await second

        let countAfterBoth = await engine.prepareCalls
        XCTAssertEqual(countAfterBoth, 1,
            "two concurrent prepareIfNeeded calls must result in exactly one prepare")
        let isPrepared = await resolver.isPrepared
        XCTAssertTrue(isPrepared)
    }

    // MARK: - The readiness gate

    /// Readiness flips only after `prepare()` succeeded — never before, and the gate answers
    /// the engine that was prepared.
    func testReadinessFlipsOnlyAfterPrepareSucceeds() async throws {
        let ledger = BuilderLedger()
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })

        let before = await resolver.engineIfReady()
        XCTAssertNil(before, "an unprepared engine must refuse honestly — the mic never opens")
        let isPrepared = await resolver.isPrepared
        XCTAssertFalse(isPrepared)

        try await resolver.prepareIfNeeded()

        let ready = await resolver.engineIfReady()
        XCTAssertNotNil(ready)
        let readyAfter = await resolver.isPrepared
        XCTAssertTrue(readyAfter)
    }

    // MARK: - Failure: refusal with a reason, and a retry that works

    /// A failed `prepare()` surfaces its reason to the caller — the underlying error intact,
    /// never stringified — and keeps the gate closed: `engineIfReady()` stays `nil` and
    /// `isPrepared` stays `false`.
    func testAPrepareFailureKeepsReadinessNilAndSurfacesTheReason() async throws {
        let ledger = BuilderLedger()
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })
        await ledger.makeNextEngineFail()

        do {
            try await resolver.prepareIfNeeded()
            XCTFail("the prepare failure must surface to the caller")
        } catch let error as ResolverTestError {
            XCTAssertEqual(error, .prepareBoom)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let ready = await resolver.engineIfReady()
        XCTAssertNil(ready, "a failed prepare must not open the readiness gate")
        let isPrepared = await resolver.isPrepared
        XCTAssertFalse(isPrepared)
    }

    /// A failure does not poison the next attempt: a later `prepareIfNeeded()` retries on the
    /// **same** engine — the builder is not called again (resolve-once holds across failures) —
    /// and readiness opens the moment the retry succeeds.
    func testAPrepareFailureDoesNotPoisonTheNextAttempt() async throws {
        let ledger = BuilderLedger()
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })
        await ledger.makeNextEngineFail()

        do { try await resolver.prepareIfNeeded() } catch {}

        try await resolver.prepareIfNeeded()

        let builds = await ledger.buildCount
        XCTAssertEqual(builds, 1, "a failed prepare retries on the same engine — never a rebuild")
        let built = await ledger.built as? FailingStubEngine
        let prepareCalls = await built?.prepareCalls
        XCTAssertEqual(prepareCalls, 2, "the retry re-runs prepare on the resolved engine")
        let ready = await resolver.engineIfReady() as? FailingStubEngine
        XCTAssertTrue(ready === built, "the gate answers the one engine the process resolved")
        let isPrepared = await resolver.isPrepared
        XCTAssertTrue(isPrepared)
    }
}

/// What a scripted prepare failure is. The specific error is the engine's business — the
/// resolver must surface it intact, not stringify it.
private enum ResolverTestError: Error, Equatable {
    case prepareBoom
}

/// **An engine whose prepare the test scripts** — the single-flight and failure rows of the
/// table, which ``StubEngine`` cannot produce (its `prepare` is a counter and nothing else).
/// An actor, for the boundary doctrine `ASRTestDoubles.swift:36-38` names: `ASREngine` is a
/// `Sendable` protocol, and a double on that boundary must cross it honestly.
actor GatedPrepareEngine: ASREngine {
    /// What a scripted `prepare()` does.
    enum Behavior: Sendable {
        /// Answer normally.
        case complete
        /// Park until the test opens the gate — the single-flight proof's suspension point.
        case park
        /// Throw ``ResolverTestError/prepareBoom``.
        case fail
    }

    let identity = EngineIdentity(
        id: "gated-engine", displayName: "Gated engine", isLocal: true)
    let supportsStreaming = false

    private let behavior: Behavior
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var prepareCalls = 0
    private(set) var parkedPreparations = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func prepare() async throws {
        prepareCalls += 1
        switch behavior {
        case .complete:
            return
        case .park:
            parkedPreparations += 1
            await withCheckedContinuation { gate = $0 }
        case .fail:
            throw ResolverTestError.prepareBoom
        }
    }

    func openGate() {
        gate?.resume()
        gate = nil
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        Transcript(
            text: "", segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}

/// **The builder, with a ledger** — every invocation recorded with the selection it received,
/// and the engine it produced kept so the tests can prove the readiness gate answers the *same*
/// object. An actor, because the ``EngineBuilding`` closure crosses into the resolver actor.
actor BuilderLedger {
    private(set) var buildCount = 0
    private(set) var selections: [EngineSelection] = []
    private(set) var built: (any ASREngine)?
    private var engineToBuild: (any ASREngine)?

    init(engine: (any ASREngine)? = nil) {
        self.engineToBuild = engine
    }

    /// The next build's engine fails its prepare — the refusal row, injected through the ledger
    /// because the resolver only ever sees the seam.
    func makeNextEngineFail() {
        engineToBuild = FailingStubEngine()
    }

    func build(_ selection: EngineSelection) -> any ASREngine {
        buildCount += 1
        selections.append(selection)
        let engine = engineToBuild ?? StubEngine.parakeet()
        built = engine
        return engine
    }
}

/// A `StubEngine` twin whose `prepare()` fails **once, then succeeds** — the launch-time
/// transient (a model still downloading), which is exactly the shape the retry row exists for.
/// Kept out of `ASRTestDoubles.swift` because it is the resolver's own double, not the ASR
/// seam's.
private actor FailingStubEngine: ASREngine {
    let identity = EngineIdentity(
        id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isLocal: true)
    let supportsStreaming = false
    private var prepared = false
    private(set) var prepareCalls = 0

    func prepare() async throws {
        prepareCalls += 1
        if !prepared {
            prepared = true
            throw ResolverTestError.prepareBoom
        }
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        Transcript(
            text: "", segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}
