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

import Darwin
import Foundation
import VoccaASR
import VoccaCore
import XCTest

/// The `benchmark-gate` aspect's real-number half (spec B3/B4): the **same** benchmark harness
/// (`LatencyBenchmarkTests.swift`'s) driven by the **real Parakeet engine** over the fixture suite,
/// env-gated exactly like `ParakeetEngineWERTests` — the model cannot reach a hosted runner, so
/// without `VOCCA_LATENCY_BENCH` this test **skips visibly**, and CI never runs a line of the real
/// path.
///
/// ## The discipline this half exists for
///
/// CI proves the span contract and the gate's mechanism only; the product latency numbers come from
/// this run, on the founder's machine, with the suppression-state discipline (`measure-timers.sh`
/// precedent): every printed row carries `getpriority(PRIO_DARWIN_PROCESS, 0)` read fresh beside it
/// (`darwinSuppressionState()`, the TimerProbe errno discipline copied below), so a throttled
/// number is recorded as throttled, never presented as clean.
///
/// ## Recorded, not gated
///
/// The provisional p50 ≤ 400 ms / p95 ≤ 800 ms table (`ROADMAP.md:171`) lives in
/// ``ProvisionalTolerances`` — one place, pinned headlessly by the B4 tests. The runner here
/// consumes the gate's real-run set (derived from the p50 budget), prints the pass/fail verdict for
/// information, and **never throws on a blown tolerance**: the founder re-baselines
/// (`tolerances_20260810.md` mechanism) before anything gates on these numbers.
@MainActor
final class LatencyBenchmarkRealEngineTests: XCTestCase {

    /// **B4.** The env-gated runner's table is the same named set the gate consumes — derived from
    /// the provisional p50 budget in exactly one place (`ProvisionalTolerances`), so deleting or
    /// forking the table breaks this test headlessly, in CI, without any model on the machine.
    func testTheRealRunnerReferencesTheProvisionalTolerancesTable() {
        XCTAssertEqual(
            RealEngineLatencyBenchmark.thresholds, LatencyBenchmarkGate.realRunThresholds,
            "the env-gated runner must consume the gate's real-run threshold set — B4: the "
                + "provisional p50/p95 table lives in one place")
        XCTAssertEqual(
            RealEngineLatencyBenchmark.thresholds.asr, ProvisionalTolerances.p50,
            "the runner's ASR budget is the provisional p50 budget — the tighter half of the table")
        XCTAssertEqual(
            RealEngineLatencyBenchmark.thresholds.inject, ProvisionalTolerances.p50,
            "the runner's inject budget is the provisional p50 budget too")
    }

    /// **B3's arithmetic, headless.** The percentile the printed rows depend on is a pure
    /// nearest-rank function: p50 of three samples is the median, p95 is the nearest-rank ceiling,
    /// and no samples is `nil` — a row prints n/a, never a fabricated number.
    func testThePrintedPercentilesAreNearestRankAndStable() {
        let values = [
            Duration.milliseconds(3), Duration.milliseconds(7), Duration.milliseconds(100),
        ]
        XCTAssertEqual(
            RealEngineLatencyBenchmark.percentile(values, 0.5), .milliseconds(7),
            "p50 of three samples is the median")
        XCTAssertEqual(
            RealEngineLatencyBenchmark.percentile(values, 0.95), .milliseconds(100),
            "p95 of three samples is the nearest-rank ceiling")
        XCTAssertNil(
            RealEngineLatencyBenchmark.percentile([], 0.5),
            "no samples, no percentile — a row must print n/a, never a fabricated number")
    }

    /// **B3, the env gate.** Without `VOCCA_LATENCY_BENCH` the real-engine benchmark **skips
    /// visibly** (the WER `XCTSkip` pattern — CI runs this path, and the skip names the env var);
    /// with it, it requires `VOCCA_MODEL_DIR` (the WER provisioning path), drives the real Parakeet
    /// engine through the same harness over the fixture suite, and prints per-span p50/p95 with the
    /// process's darwin suppression state beside every row.
    func testTheRealEngineBenchmarkPrintsPerSpanP50P95WithSuppressionState() async throws {
        guard ProcessInfo.processInfo.environment["VOCCA_LATENCY_BENCH"] != nil else {
            throw XCTSkip(
                "set VOCCA_LATENCY_BENCH=1 to run the real-engine latency benchmark — the model "
                    + "cannot reach a hosted runner, so CI runs the skip path")
        }
        guard
            let modelDir = ProcessInfo.processInfo.environment["VOCCA_MODEL_DIR"]
        else {
            throw XCTSkip(
                "set VOCCA_MODEL_DIR to a store-shaped version directory — see "
                    + "Scripts/provision-asr-fixtures.sh")
        }
        let modelDirectory = URL(fileURLWithPath: modelDir)

        // The shipped manifest + the store rooted at the model tree's root — the WER construction,
        // verbatim (`ParakeetEngineWERTests.swift:62-78`): the transport is never reached when the
        // model is present and verified, so its base URL is a stub.
        let manifestURL = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaASR/Models/Manifests/parakeet-tdt-0.6b-v3.json")
        let manifest = try ModelManifest.load(from: Data(contentsOf: manifestURL))
        let store = ModelStore(
            rootURL: modelDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent())
        let engine = ParakeetEngine(
            store: store,
            manifest: manifest,
            transport: DefaultModelTransport(
                baseURL: URL(string: "https://unused.invalid")!),
            clock: ContinuousMonotonicClock())
        try await engine.prepare()

        let rows = try await RealEngineLatencyBenchmark.run(
            engine: engine,
            fixtures: try LatencyBenchmarkTests.fixtureCases(),
            stopAdvance: LatencyBenchmarkTests.captureCloseAdvance,
            injectAdvance: LatencyBenchmarkTests.fastInjectAdvance)

        XCTAssertEqual(
            rows.map(\.span), [.captureClose, .asr, .inject],
            "one printed row per closed span, in order")
        XCTAssertTrue(
            rows.allSatisfy { $0.p50 != nil && $0.p95 != nil },
            "every row carries measured p50/p95 — a row with no samples prints n/a, never zero")
        XCTAssertFalse(
            rows.contains {
                if case .unreadable = $0.suppression { return true } else { return false }
            },
            "no row may carry an unreadable suppression state as an answer — an unreadable state "
                + "is a void run, not a row")
    }

    /// **W3, the warm-start record.** The env-gated real run also prints the engine's
    /// `firstAfterLaunch` and `warmTranscribe` samples, the ratio, and the suppression state
    /// beside it — **recorded, never gated**: this test asserts the record's shape, never its
    /// value. Exactly one first-after-launch sample (the run's first cycle), every later cycle a
    /// warm transcribe, a measured ratio (never n/a when both sides have samples), and no
    /// unreadable suppression state beside it — the `measure-timers.sh` discipline, so a
    /// throttled number is recorded as throttled, never presented as clean.
    func testTheRealEngineBenchmarkRecordsTheWarmStartRatioWithSuppressionState() async throws {
        guard ProcessInfo.processInfo.environment["VOCCA_LATENCY_BENCH"] != nil else {
            throw XCTSkip(
                "set VOCCA_LATENCY_BENCH=1 to run the real-engine latency benchmark — the model "
                    + "cannot reach a hosted runner, so CI runs the skip path")
        }
        guard
            let modelDir = ProcessInfo.processInfo.environment["VOCCA_MODEL_DIR"]
        else {
            throw XCTSkip(
                "set VOCCA_MODEL_DIR to a store-shaped version directory — see "
                    + "Scripts/provision-asr-fixtures.sh")
        }
        let modelDirectory = URL(fileURLWithPath: modelDir)

        let manifestURL = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaASR/Models/Manifests/parakeet-tdt-0.6b-v3.json")
        let manifest = try ModelManifest.load(from: Data(contentsOf: manifestURL))
        let store = ModelStore(
            rootURL: modelDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent())
        let timing = EngineTiming()
        let engine = ParakeetEngine(
            store: store,
            manifest: manifest,
            transport: DefaultModelTransport(
                baseURL: URL(string: "https://unused.invalid")!),
            clock: ContinuousMonotonicClock(),
            timing: timing)
        try await engine.prepare()

        let fixtures = try LatencyBenchmarkTests.fixtureCases()
        let result = try await RealEngineLatencyBenchmark.run(
            engine: engine,
            fixtures: fixtures,
            stopAdvance: LatencyBenchmarkTests.captureCloseAdvance,
            injectAdvance: LatencyBenchmarkTests.fastInjectAdvance,
            timing: timing)

        XCTAssertEqual(
            result.warmStart.firstAfterLaunch.count, 1,
            "exactly one first-after-launch sample — the run's first cycle is the cold one")
        XCTAssertEqual(
            result.warmStart.steadyState.count, fixtures.count - 1,
            "every later cycle is a warm transcribe")
        if case .insufficientSamples = result.warmStart.verdict {
            XCTFail(
                "the driven real run records a measured ratio — both sides have samples, never n/a")
        }
        if case .unreadable = result.warmStart.suppression {
            XCTFail(
                "no unreadable suppression state beside the ratio — an unreadable state is a void "
                    + "record, not a row")
        }
    }
}

// MARK: - The real-engine benchmark runner

/// The env-gated real run (spec B3/B4): the same harness as the headless half, with the real
/// engine in place of the stub — one composition, two subjects. Test-only, like the gate itself.
enum RealEngineLatencyBenchmark {

    /// **B4's reference, in the runner's hand**: the same named set the gate consumes — derived
    /// from ``ProvisionalTolerances``'s p50 budget. Asserted by
    /// `testTheRealRunnerReferencesTheProvisionalTolerancesTable`, headlessly.
    static let thresholds = LatencyBenchmarkGate.realRunThresholds

    /// One printed row: a span's p50/p95 over the driven cycles, and the darwin suppression state
    /// read **fresh, beside the row** — the `measure-timers.sh` discipline.
    struct Row {
        let span: SpanName
        let p50: Duration?
        let p95: Duration?
        let suppression: DarwinSuppression
    }

    /// The nearest-rank percentile over sorted samples (`p` in (0, 1]); no samples is `nil` — a
    /// row prints n/a, never a fabricated number.
    static func percentile(_ values: [Duration], _ percentile: Double) -> Duration? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(percentile * Double(sorted.count)) - 1)))
        return sorted[index]
    }

    /// Drives the real engine through the benchmark harness over `fixtures` — the same route the
    /// headless half drives, only the engine differs — and prints one row per closed span with the
    /// suppression state beside it. The provisional-tolerance verdict is **printed, never thrown**:
    /// the numbers are recorded (B4), and the founder re-baselines before anything gates on them.
    @MainActor
    static func run(
        engine: any ASREngine,
        fixtures: [ASRFixtureCase],
        stopAdvance: Duration,
        injectAdvance: Duration
    ) async throws -> [Row] {
        let harness = try LatencyBenchmarkTests.BenchmarkHarness(
            ringCapacity: LatencyBenchmarkTests.ringCapacity(for: fixtures),
            stopAdvance: stopAdvance,
            realEngine: engine,
            injectAdvance: injectAdvance)

        var mintedIDs: [SessionRecord.ID] = []
        for (index, fixture) in fixtures.enumerated() {
            let minted = await harness.runCycle(
                samples: fixture.buffer.samples, expectedRecords: index + 1)
            XCTAssertNotNil(minted, "\(fixture.name): the opening must mint the record's id")
            mintedIDs.append(minted ?? SessionRecord.ID(rawValue: -1))
        }

        let records = await harness.ledger.snapshot()
        XCTAssertEqual(records.count, fixtures.count, "one record per driven cycle")
        XCTAssertEqual(
            records.map { $0.id }, mintedIDs,
            "begin/finalize symmetry holds under the real engine")

        let rows: [Row] = [SpanName.captureClose, .asr, .inject].map { span in
            let values: [Duration] = records.compactMap { record in
                guard let found = record.spans.first(where: { $0.name == span }) else { return nil }
                return found.presence == .recorded ? found.elapsed : nil
            }
            return Row(
                span: span,
                p50: percentile(values, 0.5),
                p95: percentile(values, 0.95),
                suppression: darwinSuppressionState())
        }

        let verdict = LatencyBenchmarkGate.evaluate(records, thresholds: Self.thresholds)
        print("")
        print("== Real-engine latency benchmark (VOCCA_LATENCY_BENCH) ==")
        print("engine: \(engine.identity.id)")
        print("fixtures: \(fixtures.map(\.name).joined(separator: ", "))")
        print("darwin suppression state at start: \(describeSuppression(darwinSuppressionState()))")
        print("span          p50      p95      suppression")
        for row in rows {
            let name = String(describing: row.span)
                .padding(toLength: 13, withPad: " ", startingAt: 0)
            let p50 = (row.p50.map { "\(milliseconds($0)) ms" } ?? "n/a")
                .padding(toLength: 8, withPad: " ", startingAt: 0)
            let p95 = (row.p95.map { "\(milliseconds($0)) ms" } ?? "n/a")
                .padding(toLength: 8, withPad: " ", startingAt: 0)
            print("  \(name) \(p50) \(p95) \(describeSuppression(row.suppression))")
        }
        print(
            "verdict vs the provisional p50 table (RECORDED, not gated — the founder re-baselines): "
                + (verdict.passed ? "PASS" : "FAIL"))
        for spanVerdict in verdict.spans {
            let mark = spanVerdict.passed ? "  ok  " : "  BLOW"
            let measured = spanVerdict.elapsed.map { "\(milliseconds($0)) ms" } ?? "never ran"
            print(
                "\(mark) \(String(describing: spanVerdict.span)): \(measured) "
                    + "vs \(milliseconds(spanVerdict.threshold)) ms budget")
        }
        return rows
    }
}

// MARK: - The darwin suppression state (the TimerProbe discipline, copied verbatim)

/// Whether the kernel has this task in the **darwin-background / suppressed** state — the answer, or
/// why there is not one. Copied from `Tools/TimerProbe/main.swift` (the errno discipline the
/// `measure-timers.sh` measurements rest on): an enum rather than an `Int32`, because
/// `getpriority` returns a *priority*, so `-1` is a legitimate value and only `errno` says it
/// failed — a function returning `-1` for the error would hand a caller a number it could not tell
/// apart from an answer, in the one reading this whole measurement's credibility rests on.
enum DarwinSuppression {
    case notSuppressed
    case suppressed
    /// A priority that is neither 0 nor `PRIO_DARWIN_BG`. Unexpected rather than impossible.
    case other(Int32)
    case unreadable(errno: Int32)
}

/// Read the state, now.
///
/// `getpriority(PRIO_DARWIN_PROCESS, 0)` returns `PRIO_DARWIN_BG` when the task is suppressed and `0`
/// when it is not. The `errno` travels **with** the failure rather than being read at print time.
func darwinSuppressionState() -> DarwinSuppression {
    // Cleared first, as `getpriority(2)` requires: the call does not set `errno` on success, so a
    // stale value from any earlier call would otherwise be read as this one's failure.
    errno = 0
    let value = getpriority(Int32(PRIO_DARWIN_PROCESS), 0)
    if value == -1 && errno != 0 { return .unreadable(errno: errno) }
    switch value {
    case 0: return .notSuppressed
    case 1: return .suppressed
    default: return .other(value)
    }
}

func describeSuppression(_ state: DarwinSuppression) -> String {
    switch state {
    case .notSuppressed: return "0 (NOT suppressed)"
    case .suppressed: return "1 (SUPPRESSED — darwin background)"
    case .other(let value): return "\(value) (unexpected priority)"
    case .unreadable(let code): return "UNREADABLE (errno \(code)) — treat every number below as void"
    }
}
