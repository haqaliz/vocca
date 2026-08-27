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

/// The record fold: how one ``InjectionResult`` — with the trace the fold demotes on passed
/// explicitly — becomes the next dictation's strategy (`core-memory/spec.md` M5/M6).
///
/// The load-bearing decisions, each with a row below:
///
/// - **demote-on-fail**: every rung attempted before the winner failed, so every one of them is
///   demoted with a fresh window (`now + reprobeWindowSeconds`, the single source); a
///   `.widgetFailsafe` winner demotes **every** attempted rung — the failsafe always succeeds,
///   so everything attempted before it failed (rule 2);
/// - `.clipboardPaste` and `.widgetFailsafe` are **never** candidates, whatever the trace says —
///   the workhorse stays, and the failsafe is not a rung to learn from (rule 2/3, pinned as a
///   property over the closed winner × trace matrix);
/// - **rung-0 identity**: `attempted == []` (Secure Input refusals, `bundleID == nil`) writes
///   nothing, and a winner absent from the trace writes nothing — caller-error defense, no
///   guessing (rules 1/2);
/// - **promotion is read-back-verified** (X1): only `rung == .accessibility && verified &&
///   !allowlisted` sets `learnedAllowlist` — a lying AX that passes no read-back is never
///   promoted, and an already-allowlisted app has nothing to learn (rule 5);
/// - **the re-probe is one-shot, record-side** (M6): a demoted rung that wins is restored and
///   its window dropped — even when its window had not elapsed; one that fails is re-demoted
///   with a fresh window, so it is not eligible again until then (rules 3/4);
/// - the fold mutates only the fields it owns: other apps' state — other demotions and their
///   windows — survives untouched (rule 6).
final class StrategyMemoryRecordTests: XCTestCase {

    // MARK: - Demote-on-fail

    /// The shape the whole unit is named for: AX attempted and failing, clipboard winning — AX
    /// is demoted with a fresh window, and the workhorse is untouched.
    func testAFailedRungBeforeTheWinnerIsDemotedWithAFreshWindow() {
        let result = InjectionResult(
            rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
            verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility, .clipboardPaste],
            now: 1_000, allowlisted: true, into: InjectionStrategy())
        XCTAssertEqual(recorded.demotedRungs, [.accessibility])
        XCTAssertEqual(
            recorded.reprobeWindows[.accessibility],
            1_000 + StrategyMemoryTargets.reprobeWindowSeconds)
        XCTAssertFalse(recorded.demotedRungs.contains(.clipboardPaste))
        XCTAssertNil(recorded.reprobeWindows[.clipboardPaste])
    }

    /// One row per real winner: the rung that delivered is never demoted — a win is not a
    /// demotion input.
    func testTheAccessibilityWinnerIsNeverDemoted() {
        let result = InjectionResult(
            rung: .accessibility, attempted: [.accessibility], verified: true, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility],
            now: 0, allowlisted: false, into: InjectionStrategy())
        XCTAssertFalse(recorded.demotedRungs.contains(.accessibility))
    }

    func testTheClipboardWinnerIsNeverDemoted() {
        let result = InjectionResult(
            rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
            verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility, .clipboardPaste],
            now: 0, allowlisted: true, into: InjectionStrategy())
        XCTAssertFalse(recorded.demotedRungs.contains(.clipboardPaste))
    }

    func testTheKeystrokeWinnerIsNeverDemoted() {
        let result = InjectionResult(
            rung: .keystrokeSynthesis, attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            now: 0, allowlisted: true, into: InjectionStrategy())
        XCTAssertFalse(recorded.demotedRungs.contains(.keystrokeSynthesis))
    }

    /// A defensive trace with the winner mid-list: only the strict prefix before the winner is
    /// demotion input — rungs attempted after the winner never existed as attempts.
    func testRungsAfterTheWinnerAreNotDemoted() {
        let result = InjectionResult(
            rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            now: 0, allowlisted: true, into: InjectionStrategy())
        XCTAssertEqual(recorded.demotedRungs, [.accessibility])
        XCTAssertFalse(recorded.demotedRungs.contains(.keystrokeSynthesis))
    }

    /// The failsafe always succeeds (I1), so when it wins every attempted rung failed — the
    /// whole trace is demotion input.
    func testAWidgetFailsafeWinnerDemotesEveryAttemptedRung() {
        let result = InjectionResult(
            rung: .widgetFailsafe,
            attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result,
            attempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            now: 2_000, allowlisted: true, into: InjectionStrategy())
        XCTAssertEqual(recorded.demotedRungs, [.accessibility, .keystrokeSynthesis])
        XCTAssertEqual(
            recorded.reprobeWindows,
            [
                .accessibility: 2_000 + StrategyMemoryTargets.reprobeWindowSeconds,
                .keystrokeSynthesis: 2_000 + StrategyMemoryTargets.reprobeWindowSeconds,
            ])
    }

    // MARK: - The never-candidates

    /// Clipboard attempted and failing is still not demoted — the workhorse's demotion is not
    /// representable, whatever the trace says.
    func testClipboardIsNeverDemotedEvenWhenAttempted() {
        let failsafeWinner = InjectionResult(
            rung: .widgetFailsafe, attempted: [.clipboardPaste], verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: failsafeWinner, attempted: [.clipboardPaste],
            now: 0, allowlisted: true, into: InjectionStrategy())
        XCTAssertTrue(recorded.demotedRungs.isEmpty)

        let keystrokeWinner = InjectionResult(
            rung: .keystrokeSynthesis, attempted: [.clipboardPaste, .keystrokeSynthesis],
            verified: false, elapsed: .zero)
        let alsoRecorded = StrategyMemory.record(
            result: keystrokeWinner, attempted: [.clipboardPaste, .keystrokeSynthesis],
            now: 0, allowlisted: true, into: InjectionStrategy())
        XCTAssertTrue(alsoRecorded.demotedRungs.isEmpty)
    }

    /// The failsafe is not a rung to learn from: a trace that mentions it demotes everything
    /// else, never it.
    func testWidgetFailsafeIsNeverDemotedEvenWhenAttempted() {
        let result = InjectionResult(
            rung: .widgetFailsafe, attempted: [.widgetFailsafe, .keystrokeSynthesis],
            verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.widgetFailsafe, .keystrokeSynthesis],
            now: 0, allowlisted: true, into: InjectionStrategy())
        XCTAssertEqual(recorded.demotedRungs, [.keystrokeSynthesis])
        XCTAssertFalse(recorded.demotedRungs.contains(.widgetFailsafe))
    }

    // MARK: - The identity rows

    /// The rung-0 shape — Secure Input refusals and `bundleID == nil` (`SMOKE_CHECKLIST.md`
    /// step 27): no rung was attempted, so the fold writes nothing and returns the input
    /// unchanged.
    func testARungZeroResultWritesNothing() {
        let strategy = InjectionStrategy(
            demotedRungs: [.accessibility],
            reprobeWindows: [.accessibility: 500])
        let result = InjectionResult(
            rung: .widgetFailsafe, attempted: [], verified: false, elapsed: .zero)
        XCTAssertEqual(
            StrategyMemory.record(
                result: result, attempted: [], now: 1_000, allowlisted: true, into: strategy),
            strategy)
    }

    /// A winner absent from the trace is a caller error: nothing demoted, no guessing — the real
    /// ladder always carries the winner in the trace.
    func testAWinnerAbsentFromTheTraceWritesNothing() {
        let strategy = InjectionStrategy(
            demotedRungs: [.keystrokeSynthesis],
            reprobeWindows: [.keystrokeSynthesis: 500])
        let result = InjectionResult(
            rung: .keystrokeSynthesis, attempted: [.accessibility, .clipboardPaste],
            verified: false, elapsed: .zero)
        XCTAssertEqual(
            StrategyMemory.record(
                result: result, attempted: [.accessibility, .clipboardPaste],
                now: 1_000, allowlisted: true, into: strategy),
            strategy)
    }

    // MARK: - Promotion

    /// X1: a lying AX that passes no read-back is never promoted — `verified` is required, the
    /// pure vocabulary refusing to trust a malformed row.
    func testUnverifiedAccessibilitySuccessDoesNotPromote() {
        let result = InjectionResult(
            rung: .accessibility, attempted: [.accessibility], verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility],
            now: 0, allowlisted: false, into: InjectionStrategy())
        XCTAssertFalse(recorded.learnedAllowlist)
    }

    /// The promotion itself: a read-back-verified AX win on a non-allowlisted app earns the
    /// allowlist flag, and the next projection includes AX — the R6 learned-promotion shape.
    func testVerifiedAccessibilityOnANonAllowlistedAppPromotes() {
        let result = InjectionResult(
            rung: .accessibility, attempted: [.accessibility], verified: true, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility],
            now: 0, allowlisted: false, into: InjectionStrategy())
        XCTAssertTrue(recorded.learnedAllowlist)
        XCTAssertEqual(
            StrategyMemory.orderedRungs(for: recorded, allowlisted: false, now: 0),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis])
    }

    /// An already-allowlisted app has nothing to learn: the flag stays false, so the projection's
    /// gate keeps composing the OR itself (the `allowlisted:` argument never carries
    /// `learnedAllowlist` folded in — a first promotion stays observable).
    func testVerifiedAccessibilityOnAnAllowlistedAppLeavesTheFlagFalse() {
        let result = InjectionResult(
            rung: .accessibility, attempted: [.accessibility], verified: true, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility],
            now: 0, allowlisted: true, into: InjectionStrategy())
        XCTAssertFalse(recorded.learnedAllowlist)
    }

    /// The fold touches only the fields it owns: a promotion leaves existing demotions and their
    /// windows exactly as they were.
    func testPromotionPreservesTheRestOfTheStrategy() {
        let strategy = InjectionStrategy(
            demotedRungs: [.keystrokeSynthesis],
            reprobeWindows: [.keystrokeSynthesis: 700])
        let result = InjectionResult(
            rung: .accessibility, attempted: [.accessibility], verified: true, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility],
            now: 0, allowlisted: false, into: strategy)
        XCTAssertTrue(recorded.learnedAllowlist)
        XCTAssertEqual(recorded.demotedRungs, [.keystrokeSynthesis])
        XCTAssertEqual(recorded.reprobeWindows, [.keystrokeSynthesis: 700])
    }

    // MARK: - The one-shot re-probe

    /// A re-probed rung that wins is restored: removed from `demotedRungs`, its window dropped,
    /// and the next projection offers it again — the re-probe was consumed by the success.
    func testAReProbedRungThatSucceedsIsRestored() {
        let strategy = InjectionStrategy(
            demotedRungs: [.keystrokeSynthesis],
            reprobeWindows: [.keystrokeSynthesis: 500])
        let result = InjectionResult(
            rung: .keystrokeSynthesis, attempted: [.keystrokeSynthesis],
            verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.keystrokeSynthesis],
            now: 1_000, allowlisted: true, into: strategy)
        XCTAssertFalse(recorded.demotedRungs.contains(.keystrokeSynthesis))
        XCTAssertNil(recorded.reprobeWindows[.keystrokeSynthesis])
        XCTAssertEqual(
            StrategyMemory.orderedRungs(for: recorded, allowlisted: true, now: 1_000),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis])

        let unelapsedWindow = InjectionStrategy(
            demotedRungs: [.keystrokeSynthesis],
            reprobeWindows: [.keystrokeSynthesis: 5_000])
        let restored = StrategyMemory.record(
            result: result, attempted: [.keystrokeSynthesis],
            now: 1_000, allowlisted: true, into: unelapsedWindow)
        XCTAssertFalse(
            restored.demotedRungs.contains(.keystrokeSynthesis),
            "a rung that succeeded was demoted wrongly, restore it — window elapsed or not")
    }

    /// A re-probed rung that fails is re-demoted with a **fresh** window: the one shot is
    /// consumed, and it is not eligible again until `now + 604_800`.
    func testAReProbedRungThatFailsReDemotesWithAFreshWindow() {
        let strategy = InjectionStrategy(
            demotedRungs: [.accessibility],
            reprobeWindows: [.accessibility: 500])
        let result = InjectionResult(
            rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
            verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility, .clipboardPaste],
            now: 1_000, allowlisted: true, into: strategy)
        XCTAssertEqual(recorded.demotedRungs, [.accessibility])
        XCTAssertEqual(
            recorded.reprobeWindows[.accessibility],
            1_000 + StrategyMemoryTargets.reprobeWindowSeconds)
        XCTAssertFalse(
            StrategyMemory.reprobeEligibility(for: .accessibility, in: recorded, now: 1_000))
    }

    /// A different winner's fold leaves other demotions and their windows untouched — other apps'
    /// state is not this function's concern.
    func testAnUnattemptedDemotedRungKeepsItsWindowAndEligibility() {
        let strategy = InjectionStrategy(
            demotedRungs: [.accessibility, .keystrokeSynthesis],
            reprobeWindows: [.accessibility: 500, .keystrokeSynthesis: 700])
        let result = InjectionResult(
            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.clipboardPaste],
            now: 1_000, allowlisted: true, into: strategy)
        XCTAssertEqual(recorded.demotedRungs, [.accessibility, .keystrokeSynthesis])
        XCTAssertEqual(recorded.reprobeWindows, [.accessibility: 500, .keystrokeSynthesis: 700])
    }

    // MARK: - The contract rows

    /// The window the fold writes is exactly `now + StrategyMemoryTargets.reprobeWindowSeconds` —
    /// the single source in use, not a copied number.
    func testTheDemotionWindowIsNowPlusTheProvisionalWindow() {
        let result = InjectionResult(
            rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
            verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility, .clipboardPaste],
            now: 2_000, allowlisted: true, into: InjectionStrategy())
        XCTAssertEqual(
            recorded.reprobeWindows[.accessibility],
            2_000 + StrategyMemoryTargets.reprobeWindowSeconds)
    }

    /// The invariant over the closed matrix: every winner over every trace the ladder can
    /// produce, the record function never puts clipboard or failsafe in `demotedRungs`.
    func testRecordNeverProducesClipboardOrFailsafeInDemotedRungs() {
        let traces: [[InjectionRung]] = [
            [],
            [.accessibility],
            [.clipboardPaste],
            [.keystrokeSynthesis],
            [.widgetFailsafe],
            [.accessibility, .clipboardPaste],
            [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            [.accessibility, .clipboardPaste, .keystrokeSynthesis, .widgetFailsafe],
        ]
        for winner in InjectionRung.allCases {
            for attempted in traces {
                let result = InjectionResult(
                    rung: winner, attempted: attempted, verified: false, elapsed: .zero)
                let recorded = StrategyMemory.record(
                    result: result, attempted: attempted,
                    now: 0, allowlisted: false, into: InjectionStrategy())
                XCTAssertFalse(
                    recorded.demotedRungs.contains(.clipboardPaste),
                    "\(winner) over \(attempted) demoted the workhorse")
                XCTAssertFalse(
                    recorded.demotedRungs.contains(.widgetFailsafe),
                    "\(winner) over \(attempted) demoted the failsafe")
            }
        }
    }

    /// The `attempted:` parameter — not `result.attempted` — is the demotion input: a result
    /// carrying a truncated trace cannot silently change the demotion.
    func testThePassedTraceIsTheDemotionInput() {
        let result = InjectionResult(
            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false, elapsed: .zero)
        let recorded = StrategyMemory.record(
            result: result, attempted: [.accessibility, .clipboardPaste],
            now: 1_000, allowlisted: true, into: InjectionStrategy())
        XCTAssertEqual(recorded.demotedRungs, [.accessibility])
    }
}