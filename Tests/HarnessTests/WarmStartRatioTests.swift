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

/// The W2 contract: the warm-start ratio evaluator and the 20% bound, table-tested.
///
/// `WarmStartRatio.evaluate` answers whether the first transcription after launch is within 20%
/// of the steady-state transcriptions — the `ROADMAP.md:174` bound — or not. The load-bearing
/// decisions, each with a row below:
///
/// - the bound is **inclusive**: exactly 1.2× steady state is within, because the roadmap's
///   "within 20%" reads as ≤ 20%, not < 20% (plan "Edge cases");
/// - an **empty side is never fabricated into a number**: with no first-after-launch sample or
///   no steady-state sample there is no ratio to judge, and the answer is `.insufficientSamples`
///   — the ``LatencySpan/Presence/notPresent`` precedent, not a manufactured verdict;
/// - the steady-state representative is the **median** — the p50 discipline the latency bench
///   already uses — so the evaluator's answer does not depend on the distribution of a
///   session-to-session latency spread;
/// - the bound lives in exactly one place, `WarmStartTargets.maxFirstAfterLaunchMultiple`, and
///   the single-source scan below pins the `1.2` literal to the named table and this pinning
///   test — the ``ProvisionalCleanupTargets`` precedent (`eval-harness/plan_20260815.md` Phase 8).
///
/// All durations are whole seconds so the ratios are exact IEEE divisions (`11/10 == 1.1`), not
/// approximations from a fraction of an attosecond.
final class WarmStartRatioTests: XCTestCase {

    // MARK: - The bound

    /// The target is exactly the roadmap's 20% multiple, in exactly one named enum.
    func testTheTwentyPercentTargetLivesInTheNamedEnum() {
        XCTAssertEqual(WarmStartTargets.maxFirstAfterLaunchMultiple, 1.2)
    }

    // MARK: - The decision table

    /// 1.1× steady state is comfortably within the bound.
    func testARatioWithinTheBoundIsWithinBound() {
        let verdict = WarmStartRatio.evaluate(
            firstAfterLaunch: [.seconds(11)], steadyState: [.seconds(10)])
        XCTAssertEqual(verdict, .withinBound(ratio: 1.1))
    }

    /// Exactly 1.2× is **within** — the bound is inclusive, per the roadmap's "within 20%".
    func testExactlyTheBoundIsStillWithinBound() {
        let verdict = WarmStartRatio.evaluate(
            firstAfterLaunch: [.seconds(12)], steadyState: [.seconds(10)])
        XCTAssertEqual(verdict, .withinBound(ratio: 1.2))
    }

    /// 1.21× exceeds, and the verdict names the bound it was judged against — the 1.2 can never
    /// silently stop being the thing the verdict was measured against.
    func testARatioPastTheBoundExceedsAndNamesTheBound() {
        let verdict = WarmStartRatio.evaluate(
            firstAfterLaunch: [.seconds(121)], steadyState: [.seconds(100)])
        XCTAssertEqual(
            verdict,
            .exceedsBound(ratio: 1.21, bound: WarmStartTargets.maxFirstAfterLaunchMultiple))
        XCTAssertEqual(WarmStartTargets.maxFirstAfterLaunchMultiple, 1.2)
    }

    /// No first-after-launch sample means there is no ratio — an honest `.insufficientSamples`,
    /// never a fabricated verdict.
    func testEmptyFirstAfterLaunchSamplesAreInsufficient() {
        XCTAssertEqual(
            WarmStartRatio.evaluate(firstAfterLaunch: [], steadyState: [.seconds(10)]),
            .insufficientSamples)
    }

    /// No steady-state sample is equally unjudgeable.
    func testEmptySteadyStateSamplesAreInsufficient() {
        XCTAssertEqual(
            WarmStartRatio.evaluate(firstAfterLaunch: [.seconds(11)], steadyState: []),
            .insufficientSamples)
    }

    /// The steady-state side is summarized by its median, not its mean — the p50 discipline of
    /// the latency bench — so one slow outlier cannot move the verdict.
    func testTheSteadyStateRepresentativeIsTheMedian() {
        let verdict = WarmStartRatio.evaluate(
            firstAfterLaunch: [.seconds(11)],
            steadyState: [.seconds(5), .seconds(10), .seconds(15)])
        XCTAssertEqual(verdict, .withinBound(ratio: 1.1))
    }

    // MARK: - Single-source scan

    /// The `1.2` literal appears in exactly the named table and this pinning test — nowhere else
    /// in `Sources/` or `Tests/` — so the W2 bound cannot drift into a second home. The scan
    /// strips comments first (a doc comment naming `1.2` is not a hard-coded bound) and matches
    /// a complete numeric token (`1.25` and `1.21` are not the bound). The vacuity guard runs in
    /// both directions, the ``CleanupEvalHarnessTests`` precedent.
    func testTheBoundLiteralAppearsNowhereOutsideTheNamedFile() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let namedTable = "WarmStartRatio.swift"
        let pinningTest = "WarmStartRatioTests.swift"
        let allowedSightings: Set<String> = [namedTable, pinningTest]
        let pattern = #"(?<![0-9])1\.2(?![0-9])"#

        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let content = try String(contentsOf: file, encoding: .utf8)
                let stripped = SwiftSourceScanner.stripComments(from: content)
                if stripped.range(of: pattern, options: .regularExpression) != nil {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), allowedSightings,
            "1.2 must live in exactly the named table and its pinning test, got: \(sightings)")
        XCTAssertEqual(
            sightings[namedTable], 1,
            "the named table's own sighting must exist — the vacuity guard's second direction")
    }
}