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

/// The `rewarm-after-idle` phase (c) resolver ladder: `rewarmIfNeeded()` reaches a real re-warm
/// exactly once per idle window, single-flight against any in-flight prepare, on the currently
/// selected tier's engine — the ``DictationEngineResolverTests`` shapes, extended for the
/// re-warm rows.
///
/// Five promises are pinned here:
///
/// - **A prepared rewarmable engine re-warms exactly once** — and `prepareCount` stays 1, so
///   the launch pins' ledger stays unambiguous.
/// - **A prepare in flight is the warm-up**: `rewarmIfNeeded()` awaits it and performs no second
///   load — the spec's single-flight acceptance.
/// - **An unprepared engine takes the ordinary eager path** — nothing to re-warm.
/// - **A failing re-warm never closes the gate** — `isPrepared` stays true, the gate keeps
///   answering, and the next idle window retries (the resolver's retry-on-failure precedent).
/// - **A non-rewarmable engine refuses loudly** — `rewarmUnsupported`, never a silent no-op —
///   and the gate still answers.
/// - **Two concurrent re-warms share one flight** — the second awaits the first, never doubled.
final class DictationEngineResolverRewarmTests: XCTestCase {

    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition did not hold within 2 seconds")
    }

    /// A prepared rewarmable engine re-warms exactly once; the launch prepare count stays 1 and
    /// the readiness gate still answers the same engine.
    func testRewarmIfNeededOnAPreparedRewarmableEngineRewarmsExactlyOnce() async throws {
        let engine = GatedRewarmEngine()
        let ledger = RewarmBuilderLedger(engine: engine)
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })

        try await resolver.prepareIfNeeded()
        try await resolver.rewarmIfNeeded()

        let rewarms = await engine.rewarmCount
        XCTAssertEqual(rewarms, 1, "a prepared rewarmable engine re-warms exactly once")
        let prepares = await engine.prepareCalls
        XCTAssertEqual(prepares, 1, "the re-warm is not a prepare — the launch ledger stays 1")
        let ready = await resolver.engineIfReady() as? GatedRewarmEngine
        XCTAssertTrue(ready === engine, "the gate still answers the one engine the process resolved")
    }

    /// A prepare in flight **is** the warm-up: `rewarmIfNeeded()` awaits it and performs no
    /// second load (the spec's single-flight acceptance — a fresh prepare would only be doubled
    /// by a second one).
    func testRewarmIfNeededWhileAPrepareIsInFlightAwaitsItWithoutASecondLoad() async throws {
        let engine = GatedRewarmEngine(prepareBehavior: .park)
        let ledger = RewarmBuilderLedger(engine: engine)
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })

        let preparing = Task { try await resolver.prepareIfNeeded() }
        await waitUntil { await engine.parkedPreparations == 1 }

        let rewarm = Task { try await resolver.rewarmIfNeeded() }
        await engine.openGate()
        try await preparing.value
        try await rewarm.value

        let prepares = await engine.prepareCalls
        XCTAssertEqual(prepares, 1, "the in-flight prepare is the warm-up — no second load")
        let rewarms = await engine.rewarmCount
        XCTAssertEqual(rewarms, 0, "the re-warm path never ran — the fresh prepare was the warm-up")
        let ready = await resolver.engineIfReady()
        XCTAssertNotNil(ready, "the awaited prepare opened the gate")
    }

    /// An unprepared engine has nothing to re-warm: the ordinary eager path runs, and the gate
    /// opens with the fresh prepare (also the bounded auto-retry for a failed launch prepare).
    func testRewarmIfNeededOnAnUnpreparedEngineRunsTheOrdinaryPrepare() async throws {
        let engine = GatedRewarmEngine()
        let ledger = RewarmBuilderLedger(engine: engine)
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })

        try await resolver.rewarmIfNeeded()

        let prepares = await engine.prepareCalls
        XCTAssertEqual(prepares, 1, "nothing to re-warm — the ordinary eager path runs")
        let rewarms = await engine.rewarmCount
        XCTAssertEqual(rewarms, 0)
        let isPrepared = await resolver.isPrepared
        XCTAssertTrue(isPrepared)
    }

    /// A failing re-warm surfaces its error, leaves the gate open (`isPrepared` stays true, the
    /// gate keeps answering), and the next idle window retries — the resolver's retry-on-failure
    /// precedent, applied to the re-warm.
    func testAFailingRewarmLeavesTheGateOpenAndTheNextWindowRetries() async throws {
        let engine = GatedRewarmEngine(rewarmBehavior: .fail)
        let ledger = RewarmBuilderLedger(engine: engine)
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })
        try await resolver.prepareIfNeeded()

        do {
            try await resolver.rewarmIfNeeded()
            XCTFail("a failing re-warm must surface its error")
        } catch {
            XCTAssertEqual(error as? ResolverRewarmTestError, .rewarmBoom)
        }

        let isPrepared = await resolver.isPrepared
        XCTAssertTrue(isPrepared, "a failed re-warm never closes the gate")
        let ready = await resolver.engineIfReady()
        XCTAssertNotNil(ready, "the gate keeps answering after a failed re-warm")

        await engine.setRewarmBehavior(.complete)
        try await resolver.rewarmIfNeeded()
        let rewarms = await engine.rewarmCount
        XCTAssertEqual(rewarms, 2, "the next idle window retries — the retry-on-failure precedent")
    }

    /// A non-rewarmable engine refuses loudly — `rewarmUnsupported`, never a silent no-op — and
    /// the gate still answers: the refusal is the seam's, not the gate's.
    func testRewarmIfNeededOnANonRewarmableEngineThrowsLoudly() async throws {
        let engine = NonRewarmableEngine()
        let ledger = RewarmBuilderLedger(engine: engine)
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })
        try await resolver.prepareIfNeeded()

        do {
            try await resolver.rewarmIfNeeded()
            XCTFail("a non-rewarmable engine must refuse loudly, never no-op silently")
        } catch let error as DictationEngineResolverError {
            XCTAssertEqual(error, .rewarmUnsupported)
        }

        let ready = await resolver.engineIfReady()
        XCTAssertNotNil(ready, "the refusal never closes the gate")
    }

    /// Two concurrent `rewarmIfNeeded()` calls share one flight: the second awaits the first,
    /// the parked count stays 1, and both callers complete when the gate opens.
    func testTwoConcurrentRewarmIfNeededCallsShareOneFlight() async throws {
        let engine = GatedRewarmEngine(rewarmBehavior: .park)
        let ledger = RewarmBuilderLedger(engine: engine)
        let resolver = DictationEngineResolver(
            selection: .defaultSelection,
            building: { selection in await ledger.build(selection) })
        try await resolver.prepareIfNeeded()

        async let first: Void = resolver.rewarmIfNeeded()
        async let second: Void = resolver.rewarmIfNeeded()

        await waitUntil { await engine.parkedRewarms == 1 }
        await engine.openGate()
        try await first
        try await second

        let rewarms = await engine.rewarmCount
        XCTAssertEqual(rewarms, 1, "two concurrent re-warms share one flight")
        let parked = await engine.parkedRewarms
        XCTAssertEqual(parked, 1, "the second caller awaited the first — never doubled")
    }
}

/// The resolver re-warm rows' own failure vocabulary — the engine's error must surface intact.
private enum ResolverRewarmTestError: Error, Equatable {
    case rewarmBoom
}

/// **An engine whose prepare and re-warm the test scripts** — the ``GatedPrepareEngine`` shape
/// from `DictationEngineResolverTests`, extended with the ``EngineRewarmable`` half. An actor,
/// for the boundary doctrine `ASRTestDoubles.swift:36-38` names.
private actor GatedRewarmEngine: ASREngine, EngineRewarmable {

    /// What a scripted call does.
    enum Behavior: Sendable {
        /// Answer normally.
        case complete
        /// Park until the test opens the gate — the single-flight proof's suspension point.
        case park
        /// Throw ``ResolverRewarmTestError/rewarmBoom``.
        case fail
    }

    let identity = EngineIdentity(
        id: "gated-rewarm-engine", displayName: "Gated re-warm engine", isLocal: true)
    let supportsStreaming = false

    private var prepareBehavior: Behavior
    private var rewarmBehavior: Behavior
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var prepareCalls = 0
    private(set) var parkedPreparations = 0
    private(set) var rewarmCount = 0
    private(set) var parkedRewarms = 0

    init(prepareBehavior: Behavior = .complete, rewarmBehavior: Behavior = .complete) {
        self.prepareBehavior = prepareBehavior
        self.rewarmBehavior = rewarmBehavior
    }

    func prepare() async throws {
        prepareCalls += 1
        switch prepareBehavior {
        case .complete:
            return
        case .park:
            parkedPreparations += 1
            await withCheckedContinuation { gate = $0 }
        case .fail:
            throw ResolverRewarmTestError.rewarmBoom
        }
    }

    func rewarm() async throws {
        rewarmCount += 1
        switch rewarmBehavior {
        case .complete:
            return
        case .park:
            parkedRewarms += 1
            await withCheckedContinuation { gate = $0 }
        case .fail:
            throw ResolverRewarmTestError.rewarmBoom
        }
    }

    func openGate() {
        gate?.resume()
        gate = nil
    }

    func setRewarmBehavior(_ behavior: Behavior) {
        rewarmBehavior = behavior
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        Transcript(
            text: "", segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}

/// The non-rewarmable row's double: an ``ASREngine`` that is deliberately **not**
/// ``EngineRewarmable`` — the `rewarmUnsupported` refusal's target.
private actor NonRewarmableEngine: ASREngine {
    let identity = EngineIdentity(
        id: "non-rewarmable-engine", displayName: "Non re-warmable engine", isLocal: true)
    let supportsStreaming = false
    private(set) var prepareCalls = 0

    func prepare() async throws {
        prepareCalls += 1
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        Transcript(
            text: "", segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}

/// The builder with a ledger — every invocation recorded, and the engine it produced kept so the
/// tests can prove the readiness gate answers the *same* object.
private actor RewarmBuilderLedger {
    private(set) var buildCount = 0
    private let engineToBuild: any ASREngine

    init(engine: any ASREngine) {
        self.engineToBuild = engine
    }

    func build(_ selection: EngineSelection) -> any ASREngine {
        buildCount += 1
        return engineToBuild
    }
}