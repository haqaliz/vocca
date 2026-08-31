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
import VoccaAudio
import VoccaBootstrap
import VoccaCore
import VoccaInject
import XCTest

/// The `benchmark-gate` aspect's headless half (spec B1/B2/B4): a benchmark harness that drives
/// fixture-derived audio through the **composed route** — the `DictationCycleDrive` shape — with a
/// stub engine and fast fakes, then asserts the **span contract** on the latency ledger's records
/// and the **mechanism of the regression gate**.
///
/// The env-gated real half (spec B3) lives in `LatencyBenchmarkRealEngineTests.swift` and drives
/// the *same* harness — this file's types are shared with it (internal, not private) and the
/// harness carries a real-engine composition next to the seeded one.
///
/// ## What is measured, and what is not
///
/// Everything with a branch in it is real: the machine, the watchdog, the sink, the router and the
/// pipeline run through `DictationLoopRoot` exactly as the loop-wiring W2 cycles drive them — the
/// real `MicrophoneSource` over a fake graph, the real ledger, the real session box. What the
/// fakes stand in for is the half CI cannot execute (the tap-adapter precedent): the microphone
/// graph, the `CGEvent` tap, the AX reads, the pasteboard. The one clock the whole loop reads is
/// shared, hand-moved, and advanced **only** by the three fakes — the graph's `stop()`, the stub
/// engine's `transcribe`, and the injector's `inject` — each by a fixed seeded amount, so every
/// span's elapsed is exact and hand-asserted (the `MicrophoneSourceTests` stop-advance precedent).
///
/// ## The gate is test-only, and its mechanism is the load-bearing test
///
/// The gate (`LatencyBenchmarkGate`) is a pure check over `[SessionRecord]` + a threshold table —
/// a CI test concern, so it lives in this file, not in a module. The threshold table is injectable
/// (spec §2); `ciThresholds` — the single named set the runner consumes — is derived from the
/// provisional p50/p95 table (`ProvisionalTolerances`, B4, `ROADMAP.md:171`). The seeded-slow test
/// is the load-bearing one: **a gate that cannot fail proves nothing**, so a ~100 ms injector
/// against a ~10 ms inject budget must make the gate fail and name the inject span.
@MainActor
final class LatencyBenchmarkTests: XCTestCase {

    // MARK: - The seeded constants (the benchmark's one clock, three fixed advances)

    /// The capture-close delta: the fake graph's `stop()` takes this long (the W3 shape). Shared
    /// with the env-gated real run — its capture-close row is this same seeded fake, never a claim.
    static let captureCloseAdvance = Duration.milliseconds(3)
    /// The ASR delta: the stub engine's `transcribe` takes this long (the `TableEngine` shape).
    private static let asrAdvance = Duration.milliseconds(5)
    /// The fast injector's delta. Shared with the env-gated real run — its inject row is this same
    /// seeded fake: the harness has no real injector (no AX, no pasteboard on a hosted runner).
    static let fastInjectAdvance = Duration.milliseconds(7)
    /// The slow injector's delta — the B2 seed: ~100 ms against the ~10 ms mechanism threshold.
    private static let slowInjectAdvance = Duration.milliseconds(100)

    /// B2's injected mechanism table: the ~10 ms inject budget the slow seed must blow.
    private static let mechanismThresholds = BenchmarkThresholds(
        captureClose: .milliseconds(50),
        asr: .milliseconds(50),
        inject: .milliseconds(10))

    /// W4's span table: deliberately permissive — the whole-second seeded ASR costs (the exact-IEEE-
    /// division discipline, so the recorded ratio is asserted exactly) would blow a millisecond
    /// table, and this verdict's subject is the warm-start row, not the spans: the spans must pass
    /// so the warm-start row is the only thing that can fail the verdict.
    private static let warmStartThresholds = BenchmarkThresholds(
        captureClose: .seconds(60),
        asr: .seconds(60),
        inject: .seconds(60))

    // MARK: - B1: the span contract over fixture-derived cycles

    /// **B1.** Three fixture-derived cycles — the 200 ms, the clean and the 60 s clips — each leave
    /// exactly one record: `captureClose` then `asr` then `inject` in order, `cleanup` never
    /// recorded, attribution the stub engine's identity, and every span's elapsed **exactly** the
    /// seeded delta the fake advanced the shared clock by. Nothing stays in flight: three cycles,
    /// three records.
    func testFixtureDrivenCyclesLeaveExactRecordedSpansInOrder() async throws {
        let fixtures = try Self.fixtureCases()
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            asrAdvance: Self.asrAdvance,
            injectAdvance: Self.fastInjectAdvance)

        var mintedIDs: [SessionRecord.ID] = []
        for (index, fixture) in fixtures.enumerated() {
            let minted = await harness.runCycle(
                samples: fixture.buffer.samples, expectedRecords: index + 1)
            XCTAssertNotNil(minted, "\(fixture.name): the opening must mint the record's id")
            mintedIDs.append(minted ?? SessionRecord.ID(rawValue: -1))
        }

        let records = await harness.ledger.snapshot()
        XCTAssertEqual(
            records.count, fixtures.count,
            "one record per driven cycle — the ledger has nothing left in flight")
        XCTAssertEqual(
            records.map(\.id), mintedIDs,
            "begin/finalize symmetry: each record is the record its cycle's opening minted")

        for (record, fixture) in zip(records, fixtures) {
            XCTAssertEqual(
                record.spans.map(\.name), [.captureClose, .asr, .inject],
                "\(fixture.name): capture-close closes on the stop path, then asr, then inject")
            XCTAssertTrue(
                record.spans.allSatisfy { $0.presence == .recorded },
                "\(fixture.name): every span that ran is recorded — never a fabricated zero")
            XCTAssertNil(
                record.spans.first { $0.name == .cleanup },
                "\(fixture.name): cleanup never ran (C5 unbuilt) — never recorded")
            XCTAssertEqual(
                record.engine, StubEngine.parakeet().identity,
                "\(fixture.name): attribution is the stub engine's identity")
            XCTAssertEqual(
                record.spans[0].elapsed, Self.captureCloseAdvance,
                "\(fixture.name): capture-close equals the graph stop's seeded delta exactly")
            XCTAssertEqual(
                record.spans[1].elapsed, Self.asrAdvance,
                "\(fixture.name): the ASR span equals the engine transcribe's seeded delta exactly")
            XCTAssertEqual(
                record.spans[2].elapsed, Self.fastInjectAdvance,
                "\(fixture.name): the inject span equals the injector's measured elapsed exactly")
        }
    }

    // MARK: - B2: the gate's mechanism, proven

    /// **B2, the passing half.** The same fast-fake records pass the gate under the injected
    /// mechanism table (the ~10 ms inject budget) **and** under the named CI threshold set the
    /// runner consumes — a gate over the harness's own records, not over hand-built ones.
    func testFastFakeCyclesPassTheRegressionGate() async throws {
        let fixtures = try Self.fixtureCases()
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            asrAdvance: Self.asrAdvance,
            injectAdvance: Self.fastInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runCycle(samples: fixture.buffer.samples, expectedRecords: index + 1)
        }

        let records = await harness.ledger.snapshot()
        let mechanismVerdict = LatencyBenchmarkGate.evaluate(
            records, thresholds: Self.mechanismThresholds)
        XCTAssertTrue(
            mechanismVerdict.passed,
            "fast fakes must pass the injected mechanism table — every span under its budget")
        let ciVerdict = LatencyBenchmarkGate.evaluate(
            records, thresholds: LatencyBenchmarkGate.ciThresholds)
        XCTAssertTrue(
            ciVerdict.passed,
            "fast fakes must pass the named CI threshold set the runner consumes")
    }

    /// **B2, the failing half — the load-bearing test.** A seeded slow injector (~100 ms) against
    /// the ~10 ms inject budget must make the gate **fail**, and the verdict must name the inject
    /// span with the measured elapsed and the blown threshold. A gate that cannot fail proves
    /// nothing; this is the proof it can.
    func testASeededSlowInjectorFailsTheGateAndNamesTheInjectSpan() async throws {
        let fixtures = try Self.fixtureCases()
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            asrAdvance: Self.asrAdvance,
            injectAdvance: Self.slowInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runCycle(samples: fixture.buffer.samples, expectedRecords: index + 1)
        }

        let records = await harness.ledger.snapshot()
        let verdict = LatencyBenchmarkGate.evaluate(
            records, thresholds: Self.mechanismThresholds)
        XCTAssertFalse(
            verdict.passed,
            "a ~100 ms injector against a ~10 ms inject budget must fail the gate — a gate that "
                + "cannot fail proves nothing")
        let injectVerdicts = verdict.spans.filter { $0.span == .inject }
        XCTAssertEqual(
            injectVerdicts.count, fixtures.count,
            "one inject verdict per record — the verdict names every blown span")
        XCTAssertTrue(
            injectVerdicts.allSatisfy { !$0.passed },
            "every inject verdict must fail under the ~10 ms budget")
        XCTAssertEqual(
            injectVerdicts.first?.elapsed, Self.slowInjectAdvance,
            "the verdict carries the measured 100 ms, not a guess")
        XCTAssertEqual(
            injectVerdicts.first?.threshold, Self.mechanismThresholds.inject,
            "the verdict names the 10 ms threshold it blew")
    }

    // MARK: - W4: the gate's warm-start verdict

    /// **W4, the failing half — the warm-start row's load-bearing test.** A stub engine whose
    /// first-after-launch transcribe costs twice its steady-state transcribe must make the gate
    /// **fail**, and the verdict must name the measured ratio and the bound it blew. The span
    /// table is deliberately permissive so the spans pass: the warm-start row is the *only* thing
    /// that can fail this verdict — a gate that cannot fail on a cold first transcription proves
    /// nothing.
    func testTheWarmStartVerdictFailsWhenTheFirstTranscribeIsTwiceTheSteadyState() async throws {
        let fixtures = try Self.fixtureCases()
        let clock = BenchmarkClock()
        let engine = WarmStartRecordingEngine(
            clock: clock, firstCost: .seconds(20), steadyCost: .seconds(10))
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            engine: engine,
            injectAdvance: Self.fastInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runCycle(samples: fixture.buffer.samples, expectedRecords: index + 1)
        }

        let records = await harness.ledger.snapshot()
        let verdict = LatencyBenchmarkGate.evaluate(
            records,
            thresholds: Self.warmStartThresholds,
            warmStartFirstAfterLaunch: await engine.timing.samples(for: .firstAfterLaunch),
            warmStartSteadyState: await engine.timing.samples(for: .warmTranscribe))
        XCTAssertTrue(
            verdict.spans.allSatisfy(\.passed),
            "the spans pass — the warm-start row alone must fail this verdict")
        XCTAssertEqual(
            verdict.warmStart,
            .exceedsBound(
                ratio: 2.0, bound: WarmStartTargets.maxFirstAfterLaunchMultiple),
            "a 2x first transcription names the measured ratio and the bound it blew")
        XCTAssertFalse(
            verdict.passed,
            "a cold first transcription at 2x steady state must fail the gate — a gate that "
                + "cannot fail proves nothing")
    }

    /// **W4, the passing half.** A first transcription at 1.1x steady state passes the gate, and
    /// the verdict's warm-start row carries the measured ratio.
    func testTheWarmStartVerdictPassesWithinTheBound() async throws {
        let fixtures = try Self.fixtureCases()
        let clock = BenchmarkClock()
        let engine = WarmStartRecordingEngine(
            clock: clock, firstCost: .seconds(11), steadyCost: .seconds(10))
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            engine: engine,
            injectAdvance: Self.fastInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runCycle(samples: fixture.buffer.samples, expectedRecords: index + 1)
        }

        let records = await harness.ledger.snapshot()
        let verdict = LatencyBenchmarkGate.evaluate(
            records,
            thresholds: Self.warmStartThresholds,
            warmStartFirstAfterLaunch: await engine.timing.samples(for: .firstAfterLaunch),
            warmStartSteadyState: await engine.timing.samples(for: .warmTranscribe))
        guard case .withinBound(let ratio) = verdict.warmStart else {
            return XCTFail("1.1x steady state must be within the bound, got \(verdict.warmStart)")
        }
        XCTAssertEqual(ratio, 1.1, "the verdict carries the measured ratio")
        XCTAssertTrue(
            verdict.passed,
            "a first transcription within 20% of steady state must pass the gate")
    }

    /// **W4, the insufficient row.** An engine that never records a first-after-launch sample
    /// (the ``LatencySpan/Presence/notPresent`` shape) leaves the warm-start row **recorded as
    /// insufficient** — neither a pass nor a fail: the spans alone decide, and no ratio is
    /// fabricated.
    func testTheWarmStartVerdictIsInsufficientWithNoSamples() async throws {
        let fixtures = try Self.fixtureCases()
        let clock = BenchmarkClock()
        let engine = WarmStartRecordingEngine(
            clock: clock, firstCost: .seconds(20), steadyCost: .seconds(10),
            recordsFirstAfterLaunch: false)
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            engine: engine,
            injectAdvance: Self.fastInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runCycle(samples: fixture.buffer.samples, expectedRecords: index + 1)
        }

        let records = await harness.ledger.snapshot()
        let firstAfterLaunchSamples = await engine.timing.samples(for: .firstAfterLaunch)
        let verdict = LatencyBenchmarkGate.evaluate(
            records,
            thresholds: Self.warmStartThresholds,
            warmStartFirstAfterLaunch: firstAfterLaunchSamples,
            warmStartSteadyState: await engine.timing.samples(for: .warmTranscribe))
        XCTAssertEqual(
            firstAfterLaunchSamples, [],
            "the engine never recorded a first-after-launch sample")
        XCTAssertEqual(
            verdict.warmStart, .insufficientSamples,
            "no first-after-launch sample is recorded as insufficient — never a fabricated ratio")
        XCTAssertTrue(
            verdict.passed,
            "an insufficient warm-start row is neither a pass nor a fail — the spans alone decide")
    }

    /// **The guard-the-guard test.** The seeded-slow stub must genuinely produce a ratio past the
    /// bound — the 2x seed is verified against the engine's own recorded samples, through the
    /// shipped evaluator, before the failing-gate test's claim is worth anything. A gate that
    /// cannot fail proves nothing; a seed that does not fail it proves nothing either.
    func testTheSeededSlowFirstTranscribeGenuinelyExceedsTheBound() async throws {
        let fixtures = try Self.fixtureCases()
        let clock = BenchmarkClock()
        let engine = WarmStartRecordingEngine(
            clock: clock, firstCost: .seconds(20), steadyCost: .seconds(10))
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            engine: engine,
            injectAdvance: Self.fastInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runCycle(samples: fixture.buffer.samples, expectedRecords: index + 1)
        }

        let firstAfterLaunch = await engine.timing.samples(for: .firstAfterLaunch)
        let steadyState = await engine.timing.samples(for: .warmTranscribe)
        XCTAssertEqual(firstAfterLaunch, [.seconds(20)], "the first transcribe is the seeded 20 s")
        XCTAssertEqual(steadyState, [.seconds(10), .seconds(10)], "the rest are the seeded 10 s")
        let ratio = WarmStartRatio.evaluate(
            firstAfterLaunch: firstAfterLaunch, steadyState: steadyState)
        guard case .exceedsBound(let measured, _) = ratio else {
            return XCTFail("the seeded-slow stub must produce a ratio past the bound, got \(ratio)")
        }
        XCTAssertGreaterThan(
            measured, WarmStartTargets.maxFirstAfterLaunchMultiple,
            "the 2x seed must genuinely exceed the 20% bound — a gate that cannot fail proves "
                + "nothing")
    }

    // MARK: - B4: the provisional tolerances, in one place and consumed

    /// **The idle re-warm's benchmark row, recorded.** The seeded re-warm lands in the ledger
    /// with its exact cost — a `.rewarm` sample beside the warm-start rows — and the warm-start
    /// verdict is **identical with and without the sample present**: the runner passes only
    /// `.firstAfterLaunch`/`.warmTranscribe` into the verdict, so a `.rewarm` row is recorded,
    /// never gated, and the 1.2 launch bound is untouched.
    func testTheBenchmarkRecordsRewarmSamplesBesideTheWarmStartRows() async throws {
        let fixtures = try Self.fixtureCases()
        let clock = BenchmarkClock()
        let engine = WarmStartRecordingEngine(
            clock: clock, firstCost: .seconds(11), steadyCost: .seconds(10),
            rewarmCost: .seconds(3))
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            engine: engine,
            injectAdvance: Self.fastInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runCycle(samples: fixture.buffer.samples, expectedRecords: index + 1)
        }
        try await engine.rewarm()

        let rewarm = await engine.timing.samples(for: .rewarm)
        XCTAssertEqual(rewarm, [.seconds(3)], "the seeded re-warm lands in the ledger with its exact cost")

        let records = await harness.ledger.snapshot()
        let warmStartFirstAfterLaunch = await engine.timing.samples(for: .firstAfterLaunch)
        let warmStartSteadyState = await engine.timing.samples(for: .warmTranscribe)
        let withRewarmSample = LatencyBenchmarkGate.evaluate(
            records,
            thresholds: Self.warmStartThresholds,
            warmStartFirstAfterLaunch: warmStartFirstAfterLaunch,
            warmStartSteadyState: warmStartSteadyState)
        let withoutRewarmSample = LatencyBenchmarkGate.evaluate(
            records,
            thresholds: Self.warmStartThresholds,
            warmStartFirstAfterLaunch: warmStartFirstAfterLaunch,
            warmStartSteadyState: warmStartSteadyState)
        XCTAssertEqual(
            withRewarmSample.warmStart, withoutRewarmSample.warmStart,
            "a .rewarm row never enters the warm-start verdict — recorded, never gated")
        XCTAssertEqual(
            withRewarmSample.passed, withoutRewarmSample.passed,
            "the launch warm-start bound is untouched by the re-warm row")
    }

    /// **The vacuity half.** A benchmark that never re-warms records no `.rewarm` row at all —
    /// the ledger never fabricates the row, so the recorded row above is a genuine observation
    /// and not a default that would exist anyway.
    func testNoRewarmRunsRecordNoRewarmRow() async throws {
        let fixtures = try Self.fixtureCases()
        let clock = BenchmarkClock()
        let engine = WarmStartRecordingEngine(
            clock: clock, firstCost: .seconds(11), steadyCost: .seconds(10),
            rewarmCost: .seconds(3))
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            engine: engine,
            injectAdvance: Self.fastInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runCycle(samples: fixture.buffer.samples, expectedRecords: index + 1)
        }

        let rewarm = await engine.timing.samples(for: .rewarm)
        XCTAssertEqual(
            rewarm, [],
            "no re-warm ran — the ledger records no .rewarm row (a row that exists without a "
                + "re-warm would prove nothing)")
    }

    // MARK: - B4: the provisional tolerances, in one place and consumed

    /// **B4.** The provisional p50/p95 table (`ROADMAP.md:171`) is a single named constant set in
    /// this file, and the gate consumes it — the CI threshold set is derived from the p95 ceiling
    /// and the real-run set from the p50 budget, so the table cannot silently disappear.
    func testTheProvisionalTolerancesAreOneNamedTableAndTheGateConsumesIt() {
        XCTAssertEqual(
            ProvisionalTolerances.p50, .milliseconds(400),
            "ROADMAP.md:171 — the provisional p50 budget is 400 ms for a 10-second utterance")
        XCTAssertEqual(
            ProvisionalTolerances.p95, .milliseconds(800),
            "ROADMAP.md:171 — the provisional p95 ceiling is 800 ms for a 10-second utterance")
        XCTAssertEqual(
            LatencyBenchmarkGate.ciThresholds.captureClose, ProvisionalTolerances.p95,
            "the CI gate consumes the provisional p95 ceiling — deleting the table breaks the gate")
        XCTAssertEqual(
            LatencyBenchmarkGate.ciThresholds.asr, ProvisionalTolerances.p95,
            "the CI gate consumes the provisional p95 ceiling — deleting the table breaks the gate")
        XCTAssertEqual(
            LatencyBenchmarkGate.ciThresholds.inject, ProvisionalTolerances.p95,
            "the CI gate consumes the provisional p95 ceiling — deleting the table breaks the gate")
        XCTAssertEqual(
            LatencyBenchmarkGate.realRunThresholds.inject, ProvisionalTolerances.p50,
            "the real-run set consumes the provisional p50 budget — the tighter half of the table")
    }

    // MARK: - B2s: the gate's mechanism over the streaming variant (speculative-feed phase (f))

    /// **The named decision, pinned headlessly.** The benchmark gate and the closed four-span
    /// contract stay **post-key-up, unchanged**, with the feed live: `routeStreaming` measures
    /// the ASR span from its own entry (key-up), the feed's pre-key-up work is display and
    /// speculative accumulation — not a latency span, no claim — and the gate's closed-span
    /// checks and p95-derived budgets are untouched. What changed is the harness: the streaming
    /// variant writes the fixture to the ring in increments with the feed's fake timer firing
    /// between them, drives key-down → feed → key-up → `routeStreaming`, and must leave exactly
    /// the same closed span set — `[captureClose, asr, inject]` in order, no `cleanup` — with
    /// exact seeded deltas (the ASR span is the stream-consumption advance times the chunk
    /// count).
    func testStreamingCyclesLeaveExactRecordedSpansInOrder() async throws {
        let fixtures = try Self.fixtureCases()
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            streamChunkAdvance: .milliseconds(1),
            injectAdvance: Self.fastInjectAdvance)

        var mintedIDs: [SessionRecord.ID] = []
        for (index, fixture) in fixtures.enumerated() {
            let minted = await harness.runStreamingCycle(
                samples: fixture.buffer.samples, expectedRecords: index + 1)
            XCTAssertNotNil(minted, "\(fixture.name): the opening must mint the record's id")
            mintedIDs.append(minted ?? SessionRecord.ID(rawValue: -1))
        }

        let records = await harness.ledger.snapshot()
        XCTAssertEqual(
            records.count, fixtures.count,
            "one record per streaming cycle — nothing left in flight")
        XCTAssertEqual(
            records.map(\.id), mintedIDs,
            "begin/finalize symmetry holds on the streaming route too")

        for (record, fixture) in zip(records, fixtures) {
            XCTAssertEqual(
                record.spans.map(\.name), [.captureClose, .asr, .inject],
                "\(fixture.name): the closed four-span contract is unchanged with the feed live — "
                    + "capture-close, then asr (post-key-up, from routeStreaming's own entry), "
                    + "then inject")
            XCTAssertTrue(
                record.spans.allSatisfy { $0.presence == .recorded },
                "\(fixture.name): every span that ran is recorded — never a fabricated zero")
            XCTAssertNil(
                record.spans.first { $0.name == .cleanup },
                "\(fixture.name): cleanup never ran — never recorded")
            XCTAssertEqual(
                record.engine, StubEngine.parakeet().identity,
                "\(fixture.name): attribution is the stub engine's identity")
            XCTAssertEqual(
                record.spans[0].elapsed, Self.captureCloseAdvance,
                "\(fixture.name): capture-close is the graph stop's seeded delta, unchanged")
            XCTAssertEqual(
                record.spans[1].elapsed,
                Duration.milliseconds(Self.streamingChunkCount(fixture.buffer.samples.count)),
                "\(fixture.name): the ASR span is the stream-consumption advance times the chunk "
                    + "count — measured from routeStreaming's entry (key-up), never from the "
                    + "feed's start")
            XCTAssertEqual(
                record.spans[2].elapsed, Self.fastInjectAdvance,
                "\(fixture.name): the inject span is the injector's measured elapsed, unchanged")
        }
    }

    /// **The streaming variant passes the gate** — the same named threshold sets the batch
    /// harness passes, unchanged: the fast streaming fakes sit under the mechanism table's asr
    /// budget **and** under the CI threshold set the runner consumes. The gate was not moved to
    /// accommodate the feed; the feed's pre-key-up work simply never enters the measurement.
    func testFastStreamingFakesPassTheRegressionGate() async throws {
        let fixtures = try Self.fixtureCases()
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            streamChunkAdvance: .milliseconds(1),
            injectAdvance: Self.fastInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runStreamingCycle(
                samples: fixture.buffer.samples, expectedRecords: index + 1)
        }

        let records = await harness.ledger.snapshot()
        let mechanismVerdict = LatencyBenchmarkGate.evaluate(
            records, thresholds: Self.mechanismThresholds)
        XCTAssertTrue(
            mechanismVerdict.passed,
            "fast streaming fakes must pass the injected mechanism table — the variant's spans "
                + "are the batch harness's spans with the ASR span arriving through the stream")
        let ciVerdict = LatencyBenchmarkGate.evaluate(
            records, thresholds: LatencyBenchmarkGate.ciThresholds)
        XCTAssertTrue(
            ciVerdict.passed,
            "fast streaming fakes must pass the named CI threshold set — unchanged with the "
                + "feed live")
    }

    /// **The failing half — the load-bearing streaming row.** A seeded-slow streaming stub
    /// (100 ms per stream-consumed chunk) against the mechanism table's ~50 ms asr budget must
    /// make the gate **fail**, and the verdict must name the asr span with the measured elapsed.
    /// A gate that cannot fail proves nothing; this is the proof the streaming variant can fail
    /// it.
    func testASeededSlowStreamingStubFailsTheGateAndNamesTheAsrSpan() async throws {
        let fixtures = try Self.fixtureCases()
        let harness = try BenchmarkHarness(
            ringCapacity: Self.ringCapacity(for: fixtures),
            stopAdvance: Self.captureCloseAdvance,
            streamChunkAdvance: .milliseconds(100),
            injectAdvance: Self.fastInjectAdvance)
        for (index, fixture) in fixtures.enumerated() {
            _ = await harness.runStreamingCycle(
                samples: fixture.buffer.samples, expectedRecords: index + 1)
        }

        let records = await harness.ledger.snapshot()
        let verdict = LatencyBenchmarkGate.evaluate(
            records, thresholds: Self.mechanismThresholds)
        XCTAssertFalse(
            verdict.passed,
            "a ~100 ms-per-chunk streaming stub against a ~50 ms asr budget must fail the gate — "
                + "a gate that cannot fail proves nothing")
        let asrVerdicts = verdict.spans.filter { $0.span == .asr }
        XCTAssertEqual(
            asrVerdicts.count, fixtures.count,
            "one asr verdict per record — the verdict names every blown span")
        XCTAssertTrue(
            asrVerdicts.allSatisfy { !$0.passed },
            "every asr verdict must fail under the ~50 ms budget")
        XCTAssertEqual(
            asrVerdicts.first?.elapsed,
            Duration.milliseconds(100 * Self.streamingChunkCount(fixtures[0].buffer.samples.count)),
            "the verdict carries the measured 100 ms-per-chunk total, not a guess")
        XCTAssertEqual(
            asrVerdicts.first?.threshold, Self.mechanismThresholds.asr,
            "the verdict names the 50 ms asr threshold it blew")
    }

    /// The number of stream-consumed chunks a fixture produces at the streaming variant's chunk
    /// granularity — the ASR span's exact expected delta.
    private static func streamingChunkCount(_ samples: Int) -> Int {
        (samples + Self.streamingChunkSize - 1) / Self.streamingChunkSize
    }

    /// The streaming variant's chunk granularity: five seconds of interchange audio per feed
    /// tick. The gate's subject is the span contract, not the cadence granularity — the cadence
    /// itself is pinned elsewhere — so the chunks are sized to keep the fast variant's ASR span
    /// under the mechanism table's budget with exact arithmetic.
    static let streamingChunkSize = 80_000

    // MARK: - The composed benchmark harness

    /// One benchmark cycle through the composed root, recorded and clocked: the real
    /// `MicrophoneSource` over the scripted graph, the real pipeline over the stub engine and the
    /// ledger injector, and the one shared clock the machine, the microphone and the pipeline all
    /// read — exactly the loop-wiring W2 shape, with the clock in the loop so the spans carry
    /// exact seeded deltas instead of zeros.
    @MainActor
    struct BenchmarkHarness {
        let clock: BenchmarkClock
        let keyboard: Keyboard
        let graph: BenchmarkGraph
        let ledger: LatencyLedger
        let sessionBox: LatencySessionBox
        let root: DictationLoopRoot
        private let drainBudget: Int
        /// The feed's fake timer, when the composition wired the feed (`nil` in the batch
        /// compositions) — the streaming cycles tick it between fixture writes.
        let feedTimer: FakeTimer?

        /// The seeded (headless) composition: the stub engine with the clock in the loop.
        init(
            ringCapacity: Int,
            stopAdvance: Duration,
            asrAdvance: Duration,
            injectAdvance: Duration
        ) throws {
            let clock = BenchmarkClock()
            try self.init(
                ringCapacity: ringCapacity,
                stopAdvance: stopAdvance,
                engine: ClockAdvancingEngine(clock: clock, advance: asrAdvance),
                injectAdvance: injectAdvance,
clock: clock,
            drainBudget: 20_000)
        }

        /// The caller-built-engine composition (W4): any engine the test constructs, over a fresh
        /// shared clock — the warm-start gate tests build the recording engine themselves so they
        /// hold the ``EngineTiming`` handle the verdict is judged on.
        init(
            ringCapacity: Int,
            stopAdvance: Duration,
            engine: any ASREngine,
            injectAdvance: Duration,
            drainBudget: Int = 20_000
        ) throws {
            let clock = BenchmarkClock()
            try self.init(
                ringCapacity: ringCapacity,
                stopAdvance: stopAdvance,
                engine: engine,
                injectAdvance: injectAdvance,
                clock: clock,
                drainBudget: drainBudget)
        }

        /// The real-engine composition (spec B3, Phase 2): the *same* harness, with the real engine
        /// in place of the stub — the wrapper measures the engine's actual wall-clock transcription
        /// and advances the shared clock by exactly it, so the ASR span is the only real number on
        /// the run's rows; capture-close and inject stay the harness's seeded fakes.
        ///
        /// The drain budget is generous by default: the real 60 s fixture's transcription runs for
        /// a real second or more, and the drain must outlast it (the 20_000-turn budget was sized to
        /// the stub's string build, not to CoreML).
        init(
            ringCapacity: Int,
            stopAdvance: Duration,
            realEngine: any ASREngine,
            injectAdvance: Duration,
            drainBudget: Int = 500_000
        ) throws {
            let clock = BenchmarkClock()
            try self.init(
                ringCapacity: ringCapacity,
                stopAdvance: stopAdvance,
                engine: WallClockAdvancingEngine(inner: realEngine, clock: clock),
                injectAdvance: injectAdvance,
                clock: clock,
                drainBudget: drainBudget)
        }

        /// The streaming composition (`speculative-feed` phase (f)): the stub engine with the
        /// clock advanced **per stream-consumed chunk** (the `ClockAdvancingEngine` shape moved
        /// onto the streaming path), the feed wired over a fake timer, and the root holding the
        /// feed — so a streaming cycle measures the closed span set with the feed live, with the
        /// ASR span arriving through `routeStreaming`.
        init(
            ringCapacity: Int,
            stopAdvance: Duration,
            streamChunkAdvance: Duration,
            injectAdvance: Duration
        ) throws {
            let clock = BenchmarkClock()
            try self.init(
                ringCapacity: ringCapacity,
                stopAdvance: stopAdvance,
                engine: StreamingClockAdvancingEngine(clock: clock, chunkAdvance: streamChunkAdvance),
                injectAdvance: injectAdvance,
                clock: clock,
                drainBudget: 20_000,
                feedTimer: FakeTimer())
        }

        /// The real-engine streaming composition (spec B3's streaming half, phase (f)): the same
        /// harness with the real engine in place of the stub — the batch-default stream buffers
        /// the feed's chunks and transcribes once, the wrapper measuring the actual wall-clock
        /// transcription — and the feed live over the given fake timer.
        init(
            ringCapacity: Int,
            stopAdvance: Duration,
            realEngine: any ASREngine,
            injectAdvance: Duration,
            drainBudget: Int = 500_000,
            feedTimer: FakeTimer
        ) throws {
            let clock = BenchmarkClock()
            try self.init(
                ringCapacity: ringCapacity,
                stopAdvance: stopAdvance,
                engine: WallClockAdvancingEngine(inner: realEngine, clock: clock),
                injectAdvance: injectAdvance,
                clock: clock,
                drainBudget: drainBudget,
                feedTimer: feedTimer)
        }

        private init(
            ringCapacity: Int,
            stopAdvance: Duration,
            engine: any ASREngine,
            injectAdvance: Duration,
            clock: BenchmarkClock,
            drainBudget: Int,
            feedTimer: FakeTimer? = nil
        ) throws {
            let keyboard = Keyboard()
            let configuration = HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk)
            let toggleConfiguration = HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .toggle)
            let ledger = LatencyLedger()
            let sessionBox = LatencySessionBox()
            let graph = BenchmarkGraph(
                ring: AudioRingBuffer(capacity: ringCapacity),
                clock: clock, stopAdvance: stopAdvance)
            let feedSchedule = feedTimer.map { timer in
                (
                    schedule: { [timer] in timer.start(every: $0, $1) },
                    unschedule: { [timer] in timer.stop() }
                )
            }
            let microphone = try MicrophoneSource(
                graph: graph,
                recorder: ledger,
                clock: clock,
                sessionIDProvider: { sessionBox.sessionID },
                feedSchedule: feedSchedule)
            let injector = BenchmarkInjector(clock: clock, advance: injectAdvance)
            let holder = BenchmarkHolder()
            let pipeline = DictationPipeline(
                engine: engine, injector: injector, holder: holder,
                recorder: ledger, clock: clock)
            let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in engine }
            let focusedApp = FakeFocusedApp(
                identity: FocusedAppIdentity(
                    bundleID: "com.apple.Notes", windowTitle: "The Draft"))
            let targetResolution = TargetResolution(
                focusedApp: focusedApp, secureInput: FakeSecureInput())
            let panel = RecordingPanel(holder: holder)
            let root = DictationLoopRoot(
                configuration: configuration,
                ceiling: SessionCeiling.default,
                clock: clock,
                audioSource: microphone,
                keyState: TruthfulKeyState(keyboard),
                watchdogTimer: FakeTimer(),
                healthTimer: FakeTimer(),
                deferOpening: { $0() },
                tap: FakeHotkeyEventSource(),
                secureInput: FakeSecureInputState(),
                resolver: resolver,
                targetResolution: targetResolution,
                panel: panel,
                pipeline: pipeline,
                recorder: ledger,
                sessionBox: sessionBox,
                toggleConfiguration: toggleConfiguration,
                toggleSource: RecordingAudioSource(),
                toggleTimer: FakeTimer(),
                runningAppName: FakeRunningAppName(),
                widgetClock: FakeTimer(),
                liveLevel: BenchmarkLevelSource(level: 0),
                holdFeed: feedTimer == nil ? nil : microphone.feed)
            root.markEnginePrepared()
            // The shipped default mode is `.toggle`; the streaming cycles drive the hold-to-talk
            // machine, so the mode is switched first — the router's active feed follows the
            // mode (the speculative-feed §2c slot).
            if feedTimer != nil {
                root.setActiveMode(.holdToTalk)
            }

            self.clock = clock
            self.keyboard = keyboard
            self.graph = graph
            self.ledger = ledger
            self.sessionBox = sessionBox
            self.root = root
            self.feedTimer = feedTimer
            self.drainBudget = drainBudget
        }

        /// One full **streaming** hold-to-talk cycle carrying `samples` (`speculative-feed` phase
        /// (f)): press → the opening mints the record's id → the fixture lands in the ring **in
        /// increments with the feed's fake timer firing between them** → release → the router
        /// terminates the feed (appending the remainder `endCapture` drained) and routes the
        /// stream → the record finalizes through `routeStreaming`, the closed span set measured
        /// with the feed live.
        func runStreamingCycle(samples: [Float], expectedRecords: Int) async -> SessionRecord.ID? {
            let feedTimer = try! XCTUnwrap(feedTimer)
            keyboard.hold(HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk))
            _ = root.holdToTalk.scheduledWatchdog.receive(
                event(.keyDown, 49, [.option]))
            await drain(
                until: { sessionBox.sessionID != nil },
                "the opening must mint and store the record's id before the key-up")
            let minted = sessionBox.sessionID
            var offset = 0
            while offset < samples.count {
                write(
                    Array(samples[offset..<min(offset + LatencyBenchmarkTests.streamingChunkSize, samples.count)]),
                    to: graph.ring)
                offset += LatencyBenchmarkTests.streamingChunkSize
                feedTimer.tick()
            }
            _ = root.holdToTalk.scheduledWatchdog.receive(
                event(.keyUp, 49, [.option]))
            keyboard.release(49)
            await drain(
                until: {
                    if sessionBox.sessionID != nil { return false }
                    return await ledger.snapshot().count == expectedRecords
                },
                "streaming cycle \(expectedRecords): the delivered session must finalize exactly one record")
            return minted
        }

        /// One full hold-to-talk cycle carrying `samples`: press → the opening mints the record's
        /// id → the fixture lands in the ring → release → the record finalizes. Returns the id the
        /// opening minted, so begin/finalize symmetry is asserted against the cycle's own mint.
        func runCycle(samples: [Float], expectedRecords: Int) async -> SessionRecord.ID? {
            keyboard.hold(HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk))
            _ = root.holdToTalk.scheduledWatchdog.receive(
                event(.keyDown, 49, [.option]))
            await drain(
                until: { sessionBox.sessionID != nil },
                "the opening must mint and store the record's id before the key-up")
            let minted = sessionBox.sessionID
            write(samples, to: graph.ring)
            _ = root.holdToTalk.scheduledWatchdog.receive(
                event(.keyUp, 49, [.option]))
            keyboard.release(49)
            await drain(
                until: {
                    if sessionBox.sessionID != nil { return false }
                    return await ledger.snapshot().count == expectedRecords
                },
                "cycle \(expectedRecords): the delivered session must finalize exactly one record")
            return minted
        }

        /// Lets the router's unstructured tasks run until `condition` holds, then asserts it —
        /// the `DictationLoopTests` shape, with the probe's 20_000-turn budget as the headless
        /// floor: the 60 s fixture's transcription (the stub's full sample-string build,
        /// unoptimized in debug) is the slowest honest step, and the drain must outlast it. The
        /// env-gated real run carries a larger budget (see the real-engine composition), because a
        /// real CoreML transcription of the 60 s fixture runs for a real second or more.
        func drain(until condition: @escaping () async -> Bool, _ message: String) async {
            var attempts = 0
            while !(await condition()) && attempts < drainBudget {
                await Task.yield()
                attempts += 1
            }
            let held = await condition()
            XCTAssertTrue(held, message)
        }
    }

    // MARK: - The fixtures

/// The three benchmark fixtures, by name: the shortest, the clean one, and the 60 s one —
/// three different lengths, per the spec's ≥ 3 fixture-derived cycles. Shared with the env-gated
/// real run — the real engine drives the same three fixtures through the same harness.
static func fixtureCases() throws -> [ASRFixtureCase] {
    let all = try ASRFixtureSuite.loadFixtures()
    let wanted = ["two-hundred-ms", "clean", "sixty-second"]
    let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    return try wanted.map { name in
        guard let fixture = byName[name] else {
            throw BenchmarkFixtureError.missing(name)
        }
        return fixture
    }
}

/// The ring must hold the largest fixture whole (the 60 s clip, ~2^20 samples): the ring
/// refuses a block that does not fit, so a ring sized to the largest fixture is what makes
/// every fixture-derived cycle complete rather than truncated.
static func ringCapacity(for fixtures: [ASRFixtureCase]) -> Int {
    let largest = fixtures.map { $0.buffer.samples.count }.max() ?? 0
    var capacity = 1
    while capacity < largest + 1 {
        capacity *= 2
    }
    return capacity
}

enum BenchmarkFixtureError: Error {
    case missing(String)
}
}

// MARK: - The gate and its tables

/// **B4's table, in exactly one place** (`ROADMAP.md:171`): the provisional p50/p95 latency
/// budgets for a 10-second utterance. CI never gates on these numbers — CI proves contract and
/// mechanism only (spec "Isolation / honesty decisions") — the founder re-baselines them from the
/// env-gated real run (the C3 tolerances precedent). The gate's threshold sets are derived from
/// this table, and a test pins that derivation, so the table cannot silently disappear.
enum ProvisionalTolerances {
    /// The provisional p50 budget: 400 ms.
    static let p50: Duration = .milliseconds(400)
    /// The provisional p95 ceiling: 800 ms.
    static let p95: Duration = .milliseconds(800)
}

/// One span's budget — the per-span row of the gate's threshold table.
struct BenchmarkThresholds: Equatable {
    let captureClose: Duration
    let asr: Duration
    let inject: Duration

    func budget(for span: SpanName) -> Duration {
        switch span {
        case .captureClose: return captureClose
        case .asr: return asr
        case .inject: return inject
        case .cleanup:
            preconditionFailure("cleanup has no budget — C5 is unbuilt and the span is never recorded")
        }
    }
}

/// The gate's answer over one record set: a per-span verdict for every expected span of every
/// record (the closed set `captureClose`, `asr`, `inject`), plus the contract failures — records
/// missing, spans missing or out of order, a `cleanup` span present. A span that never ran is a
/// failure, never a free pass.
struct BenchmarkGateVerdict {
    /// One expected span's verdict: the measured elapsed (nil when the span never ran) against
    /// the budget, so a failure names the span, the measurement and the threshold it blew.
    struct SpanVerdict {
        let span: SpanName
        let elapsed: Duration?
        let threshold: Duration

        var passed: Bool {
            guard let elapsed else { return false }
            return elapsed <= threshold
        }
    }

    /// **The W4 warm-start verdict row** — the named contract decision: the closed four-span
    /// session record is unchanged, no new span name; the ratio is cross-session and lives in
    /// ``EngineTiming`` samples, and this row carries the judgment over them, consumed from the
    /// shipped ``WarmStartRatio`` evaluator (never duplicated here). `.insufficientSamples` is
    /// **recorded, neither a pass nor a fail** — the ``LatencySpan/Presence/notPresent``
    /// precedent — so it cannot move ``passed`` either way; only `.exceedsBound` fails it.
    let warmStart: WarmStartRatio.Verdict

    let spans: [SpanVerdict]
    let contractFailures: [String]

    var passed: Bool {
        guard contractFailures.isEmpty else { return false }
        guard spans.allSatisfy(\.passed) else { return false }
        if case .exceedsBound = warmStart { return false }
        return true
    }
}

/// **The regression gate: a pure check over `[SessionRecord]` + a threshold table** — a CI test
/// concern, so test-only (the plan's decision: "the gate is a CI test concern; a test-only type
/// is honest"). The threshold table is injectable; the two named sets below are what the runner
/// consumes, both derived from the provisional table (B4).
enum LatencyBenchmarkGate {

    /// The CI threshold set the runner consumes — derived from the provisional **p95 ceiling**
    /// per span (spec: "CI runs wide/stub thresholds"): the stub's seeded costs are single-digit
    /// milliseconds, so the CI gate is a contract gate, never a product-number gate.
    static let ciThresholds = BenchmarkThresholds(
        captureClose: ProvisionalTolerances.p95,
        asr: ProvisionalTolerances.p95,
        inject: ProvisionalTolerances.p95)

    /// The real-run threshold set (the env-gated runner's, Phase 2) — the tighter half of the
    /// provisional table, the **p50 budget** per span: recorded, not enforced, until the founder
    /// re-baselines.
    static let realRunThresholds = BenchmarkThresholds(
        captureClose: ProvisionalTolerances.p50,
        asr: ProvisionalTolerances.p50,
        inject: ProvisionalTolerances.p50)

    /// Checks every record against the table: every record must carry exactly the closed span set
    /// in order with no `cleanup`, and every recorded span's elapsed must sit under its budget.
    /// The warm-start verdict (W4) is judged over the engine's cross-session ``EngineTiming``
    /// samples — the first-after-launch vs steady-state ratio through the shipped evaluator —
    /// defaulting to `.insufficientSamples` (recorded, neither a pass nor a fail) for a run that
    /// recorded none.
    static func evaluate(
        _ records: [SessionRecord],
        thresholds: BenchmarkThresholds,
        warmStartFirstAfterLaunch: [Duration] = [],
        warmStartSteadyState: [Duration] = []
    ) -> BenchmarkGateVerdict {
        var contractFailures: [String] = []
        if records.isEmpty {
            contractFailures.append("the harness recorded nothing — a gate over no records proves nothing")
        }
        var spans: [BenchmarkGateVerdict.SpanVerdict] = []
        for record in records {
            let names = record.spans.map(\.name)
            if names != [.captureClose, .asr, .inject] {
                contractFailures.append(
                    "record \(record.id.rawValue): spans \(names) are not captureClose, asr, inject in order")
            }
            if record.spans.contains(where: { $0.name == .cleanup }) {
                contractFailures.append(
                    "record \(record.id.rawValue): cleanup must never be recorded (C5 unbuilt)")
            }
            for span in [SpanName.captureClose, .asr, .inject] {
                let found = record.spans.first { $0.name == span }
                spans.append(BenchmarkGateVerdict.SpanVerdict(
                    span: span,
                    elapsed: found?.presence == .recorded ? found?.elapsed : nil,
                    threshold: thresholds.budget(for: span)))
            }
        }
        let warmStart = WarmStartRatio.evaluate(
            firstAfterLaunch: warmStartFirstAfterLaunch,
            steadyState: warmStartSteadyState)
        return BenchmarkGateVerdict(
            warmStart: warmStart, spans: spans, contractFailures: contractFailures)
    }
}

// MARK: - The benchmark's own doubles

/// The one clock the whole benchmark reads — the root, the microphone and the pipeline share it,
/// mirroring `AppBootstrap.configure`'s one-clock rule. Hand-moved: only the three fakes advance
/// it, each by its fixed seeded amount, so every span's delta is exact. `@unchecked Sendable` for
/// the `TableClock` reason: the reading is mutated from the main actor (the graph's `stop()`) and
/// from the engine and injector actors, serialized by the awaits between them.
final class BenchmarkClock: MonotonicClock, @unchecked Sendable {
    var now: Duration = .zero
}

/// The capture graph the benchmark captures through — the W2 ledger shape with the W3 stop-clock:
/// `stop()` takes ``stopAdvance`` by moving the shared clock, so the capture-close span's delta is
/// exact and hand-asserted, and the whole fixture is drained through a real ring and the real
/// converter.
final class BenchmarkGraph: CaptureGraphSeam {
    let ring: AudioRingBuffer
    let captureFormat: CapturedAudioFormat = .interchange
    private(set) var stopCalls = 0
    private(set) var isRunning = false
    var levelPeak: Float = 0
    private let clock: BenchmarkClock
    private let stopAdvance: Duration

    init(ring: AudioRingBuffer, clock: BenchmarkClock, stopAdvance: Duration) {
        self.ring = ring
        self.clock = clock
        self.stopAdvance = stopAdvance
    }

    func start() throws {
        isRunning = true
    }

    func stop() {
        stopCalls += 1
        isRunning = false
        clock.now += stopAdvance
    }
}

/// The stub engine with the clock in the loop (the `TableEngine` shape): `transcribe` advances the
/// shared clock by the seeded ``asrAdvance`` — so the pipeline's two clock reads straddle a real,
/// asserted delta — and delegates the transcription to the shared ``StubEngine``, so the record's
/// attribution is the stub engine's identity, verbatim.
private actor ClockAdvancingEngine: ASREngine {
    let identity: EngineIdentity
    let supportsStreaming = false
    private let inner: StubEngine
    private let clock: BenchmarkClock
    private let advance: Duration

    init(clock: BenchmarkClock, advance: Duration) {
        self.inner = StubEngine.parakeet()
        self.identity = inner.identity
        self.clock = clock
        self.advance = advance
    }

    func prepare() async throws {
        try await inner.prepare()
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        clock.now += advance
        return try await inner.transcribe(buffer)
    }
}

/// The streaming stub engine with the clock in the loop (`speculative-feed` phase (f)): the
    /// `ClockAdvancingEngine` shape moved onto the streaming path — `stream(_:)` advances the
    /// shared clock by the seeded ``chunkAdvance`` **per stream-consumed chunk**, then delegates
    /// the transcription of the merged buffer to the shared ``StubEngine``, so the record's
    /// ASR span (measured by `routeStreaming` from its own entry, key-up) is exactly
    /// `chunkCount × chunkAdvance`, and attribution is the stub engine's identity. The seeded-slow
    /// variant is the B2s seed: the same shape at 100 ms per chunk against the mechanism table's
    /// ~50 ms asr budget.
    private actor StreamingClockAdvancingEngine: ASREngine {
        let identity: EngineIdentity
        let supportsStreaming = true
        private let inner: StubEngine
        private let clock: BenchmarkClock
        private let chunkAdvance: Duration

        init(clock: BenchmarkClock, chunkAdvance: Duration) {
            self.inner = StubEngine.parakeet()
            self.identity = inner.identity
            self.clock = clock
            self.chunkAdvance = chunkAdvance
        }

        func prepare() async throws {
            try await inner.prepare()
        }

        func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
            try await inner.transcribe(buffer)
        }

        nonisolated func stream(
            _ chunks: AsyncStream<AudioBuffer>
        ) -> AsyncThrowingStream<Transcript, Error> {
            AsyncThrowingStream { continuation in
                let task = Task { await self.runStream(chunks, continuation: continuation) }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }

        /// The stream body: advance the clock per chunk, buffer, then delegate the whole
        /// transcription to the stub — the batch-default shape with the clock in the loop.
        private func runStream(
            _ chunks: AsyncStream<AudioBuffer>,
            continuation: AsyncThrowingStream<Transcript, Error>.Continuation
        ) async {
            var samples: [Float] = []
            for await chunk in chunks {
                clock.now += chunkAdvance
                samples.append(contentsOf: chunk.samples)
            }
            do {
                let transcript = try await inner.transcribe(
                    AudioBuffer(samples: samples, sampleRate: AudioBuffer.interchangeSampleRate))
                continuation.yield(transcript)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

/// The W4 engine with the clock in the loop: its first `transcribe` costs ``firstCost`` and
    /// records ``EngineTiming/Kind/firstAfterLaunch``; every later one costs ``steadyCost`` and
    /// records ``EngineTiming/Kind/warmTranscribe`` — the cross-session samples the warm-start
    /// verdict is judged on, produced by the same harness the spans come from. The whole-second
    /// seeds make the recorded ratio an exact IEEE division (the ``WarmStartRatioTests``
    /// discipline), so the verdict's ratio is asserted exactly.
    ///
    /// ``recordsFirstAfterLaunch`` is the insufficient-samples row: `false` records no
    /// first-after-launch sample at all — the ``LatencySpan/Presence/notPresent`` shape, never a
    /// fabricated ratio.
    ///
    /// The ``EngineRewarmable`` half is the idle re-warm's benchmark row: `rewarm()` advances the
    /// shared clock by the seeded ``rewarmCost`` and records it as
    /// ``EngineTiming/Kind/rewarm`` — the W4-double discipline (whole seconds, exact IEEE
    /// values), so the recorded-not-gated claim is asserted exactly.
    private actor WarmStartRecordingEngine: ASREngine, EngineRewarmable {
        let identity: EngineIdentity
        let supportsStreaming = false
        /// The cross-session timing ledger the verdict is judged on — the tests read it back.
        let timing: EngineTiming
        private let inner: StubEngine
        private let clock: BenchmarkClock
        private let firstCost: Duration
        private let steadyCost: Duration
        private let recordsFirstAfterLaunch: Bool
        private let rewarmCost: Duration
        private var transcribes = 0

    init(
        clock: BenchmarkClock,
        firstCost: Duration,
        steadyCost: Duration,
        recordsFirstAfterLaunch: Bool = true,
        rewarmCost: Duration = .zero
    ) {
        self.inner = StubEngine.parakeet()
        self.identity = inner.identity
        self.timing = EngineTiming()
        self.clock = clock
        self.firstCost = firstCost
        self.steadyCost = steadyCost
        self.recordsFirstAfterLaunch = recordsFirstAfterLaunch
        self.rewarmCost = rewarmCost
    }

    func prepare() async throws {
        try await inner.prepare()
    }

    func rewarm() async throws {
        clock.now += rewarmCost
        await timing.record(.rewarm, elapsed: rewarmCost)
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        transcribes += 1
        let isFirst = transcribes == 1
        let cost = isFirst ? firstCost : steadyCost
        clock.now += cost
        if isFirst && recordsFirstAfterLaunch {
            await timing.record(.firstAfterLaunch, elapsed: cost)
        } else {
            await timing.record(.warmTranscribe, elapsed: cost)
        }
        return try await inner.transcribe(buffer)
    }
}

/// The real-engine wrapper with the clock in the loop (spec B3): measures the inner engine's
/// **actual** wall-clock transcription and advances the shared benchmark clock by exactly that
/// delta — the only real number in the whole benchmark. The pipeline's two clock reads then straddle
/// the real duration, so the ledger's ASR span carries the real measurement while every other span
/// keeps its seeded delta. The wrapper's identity is the inner engine's, verbatim — attribution on
/// the real run's records is the real engine's own.
private actor WallClockAdvancingEngine: ASREngine {
    let identity: EngineIdentity
    let supportsStreaming = false
    private let inner: any ASREngine
    private let clock: BenchmarkClock

    init(inner: any ASREngine, clock: BenchmarkClock) {
        self.inner = inner
        self.clock = clock
        self.identity = inner.identity
    }

    func prepare() async throws {
        try await inner.prepare()
    }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        let start = ContinuousClock.now
        let transcript = try await inner.transcribe(buffer)
        clock.now += ContinuousClock.now - start
        return transcript
    }
}

/// One recorded injection — the benchmark injector's ledger row.
struct BenchmarkInjectionCall {
    let text: String
    let target: TargetContext
}

/// The injector, with the clock in the loop: `inject` advances the shared clock by the seeded
/// ``advance`` and reports that same delta as the ladder's measured `elapsed` — the pipeline
/// records `InjectionResult.elapsed` verbatim, so the inject span's delta is exact. The slow
/// variant is the B2 seed: the same shape at ~100 ms against the ~10 ms budget.
actor BenchmarkInjector: TextInjector {
    private let clock: BenchmarkClock
    private let advance: Duration
    private(set) var calls: [BenchmarkInjectionCall] = []

    init(clock: BenchmarkClock, advance: Duration) {
        self.clock = clock
        self.advance = advance
    }

    func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        calls.append(BenchmarkInjectionCall(text: text, target: target))
        clock.now += advance
        return InjectionResult(
            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
            elapsed: advance)
    }
}

/// The holder, as a ledger that never holds: the delivered path must never touch it.
actor BenchmarkHolder: TranscriptHolder {
    private(set) var holdCalls = 0
    private(set) var currentCalls = 0

    func hold(_ transcript: HeldTranscript) async throws {
        holdCalls += 1
    }

    func current() async -> HeldTranscript? {
        currentCalls += 1
        return nil
    }

    func release() async {}
}

/// The widget's level source, as a fixed value — the waveform is not this suite's subject.
final class BenchmarkLevelSource: LiveLevelSource {
    let level: Float

    init(level: Float) {
        self.level = level
    }

    func latestLevel() -> Float { level }
}

// MARK: - Fixture helpers

/// One keyboard event, stamped with the constant timestamp the machine's own tests use.
private func event(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false,
        timestamp: .zero)
}

/// Write `samples` into `ring` the way the realtime producer would — whole blocks, refused whole
/// when there is no room (the ring is sized so a fixture never is).
private func write(_ samples: [Float], to ring: AudioRingBuffer) {
    _ = samples.withUnsafeBufferPointer { pointer in
        ring.write(pointer.baseAddress!, count: pointer.count)
    }
}
