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
import VoccaInject
import XCTest

/// The injection ladder: the decision function of Phase C
/// (`docs/planning/injection-ladder/injector-seam/plan_20260809.md` §3), and the orchestrator that
/// runs it.
///
/// Everything with a branch in the ladder lives here, over injected handles — the `TapHealthPolicy`
/// precedent: the rung strategies, the order, the allowlist, the handoff and the clock all arrive
/// through seams, so no system call and no wall clock can hide in a decision. The load-bearing
/// tests are the ones over the **closed set**:
///
/// - every row of the decision table (`plan §3`), including the two rung-0 refusals with their
///   `attempted == []` guarantee;
/// - the **fault-injection acceptance** (`CAPABILITY_ROADMAP.md:106`): every rung forced to fail in
///   sequence, in every combination, with the transcript held in exactly the combinations that
///   exhaust the ladder — zero loss, no tolerance band;
/// - the default order pinned (allowlisted → accessibility first, never otherwise), with a custom
///   injected order changing the sequence with no decision-code change;
/// - `elapsed` accumulated from the injected clock, with the ladder budget asserted at realistic
///   fake costs (`ARCHITECTURE.md:271`);
/// - `attempted` carrying exactly the prefix trace the docs promise, so C8's strategy memory reads
///   one shape wherever it looks.
///
/// The whole class is `@MainActor`, like the ladder it drives: the decision and the injector share
/// one isolation domain with the injected ``MonotonicClock`` (which is not `Sendable`), and the
/// tests build that domain rather than crossing it.
@MainActor
final class InjectionLadderTests: XCTestCase {

    // MARK: - Small builders

    private let defaultOrder: [InjectionRung] = [
        .accessibility, .clipboardPaste, .keystrokeSynthesis,
    ]

    private func target(
        bundleID: String? = "com.example.Notes", secureInput: Bool = false
    ) -> TargetContext {
        TargetContext(bundleID: bundleID, windowTitle: nil, isSecureInput: secureInput)
    }

    /// One ladder run over the decision, with every input explicit so a test can vary exactly one
    /// thing. The default target app name is "Slack" so the "{app}" copy's carrier
    /// (`PRODUCT_SPEC.md:112`) is exercised on every failsafe path, not only in the routing test.
    private func runDecision(
        text: String = "the words",
        target: TargetContext = TargetContext(
            bundleID: "com.example.Notes", windowTitle: nil, isSecureInput: false),
        targetAppName: String? = "Slack",
        orderedRungs: [InjectionRung],
        strategies: [InjectionRung: any InjectionRungStrategy],
        handoff: any FailsafeHandoff,
        clock: any MonotonicClock
    ) async throws -> InjectionResult {
        try await decide(
            text: text,
            target: target,
            targetAppName: targetAppName,
            orderedRungs: orderedRungs,
            strategies: strategies,
            handoff: handoff,
            clock: clock)
    }

    // MARK: - The two rung-0 refusals

    /// Secure Input refuses at rung 0: `attempted == []`, reason `.secureInput`, nothing attempted,
    /// nothing timed — and the transcript is still held.
    ///
    /// The honest refusal of `PRODUCT_SPEC.md:111` — never a silent no-op, and never an attempt
    /// that could type into a password field. The `attempted == []` guarantee is the whole point of
    /// the row: a refusal that reported a trace would be indistinguishable from an attempt that
    /// ran.
    func testSecureInputRefusesAtRungZeroWithAnEmptyTrace() async throws {
        let clock = TestClock()
        clock.now = .seconds(5)
        let handoff = RecordingFailsafeHandoff()
        let ax = FakeInjectionStrategy(rung: .accessibility, outcome: .succeeded(verified: true))

        let result = try await runDecision(
            target: target(secureInput: true),
            orderedRungs: defaultOrder,
            strategies: [.accessibility: ax],
            handoff: handoff,
            clock: clock)

        XCTAssertEqual(result.rung, .widgetFailsafe)
        XCTAssertEqual(result.attempted, [], "a rung-0 refusal must not report a trace")
        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.elapsed, .zero, "nothing was attempted, so nothing took time")

        let held = await handoff.held
        XCTAssertEqual(held.count, 1, "the refusal must still hold the transcript")
        XCTAssertEqual(held[0].text, "the words")
        XCTAssertEqual(held[0].reason, .secureInput)
        XCTAssertEqual(held[0].targetAppName, "Slack")
        XCTAssertEqual(held[0].capturedAt, .seconds(5), "capturedAt is the injected clock's reading")

        let axCalls = await ax.callCount
        XCTAssertEqual(axCalls, 0, "no rung may be attempted under Secure Input")
    }

    /// Nothing focused refuses at rung 0: `attempted == []`, reason `.noFocusedField`
    /// (`PRODUCT_SPEC.md:113`), before any rung runs.
    func testNoFocusedFieldRefusesAtRungZeroWithAnEmptyTrace() async throws {
        let clock = TestClock()
        clock.now = .seconds(9)
        let handoff = RecordingFailsafeHandoff()
        let clipboard = FakeInjectionStrategy(rung: .clipboardPaste, outcome: .succeeded(verified: false))

        let result = try await runDecision(
            target: target(bundleID: nil),
            orderedRungs: defaultOrder,
            strategies: [.clipboardPaste: clipboard],
            handoff: handoff,
            clock: clock)

        XCTAssertEqual(result.rung, .widgetFailsafe)
        XCTAssertEqual(result.attempted, [])
        XCTAssertEqual(result.elapsed, .zero)

        let held = await handoff.held
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].reason, .noFocusedField)
        XCTAssertEqual(held[0].capturedAt, .seconds(9))

        let clipboardCalls = await clipboard.callCount
        XCTAssertEqual(clipboardCalls, 0, "no rung may be attempted with nothing focused")
    }

    /// When both refusal conditions hold, Secure Input wins — the decision table's first row is
    /// checked first (`ARCHITECTURE.md:382-384`), and a password field with no focused app is still
    /// a password field.
    func testSecureInputTakesPrecedenceOverNoFocusedField() async throws {
        let handoff = RecordingFailsafeHandoff()

        let result = try await runDecision(
            target: target(bundleID: nil, secureInput: true),
            orderedRungs: defaultOrder,
            strategies: [:],
            handoff: handoff,
            clock: TestClock())

        XCTAssertEqual(result.rung, .widgetFailsafe)
        let held = await handoff.held
        XCTAssertEqual(held[0].reason, .secureInput)
    }

    // MARK: - The rung rows

    /// The first row of success: accessibility, read-back verified, delivers at once — `attempted`
    /// is exactly the prefix trace through the winning rung.
    func testAccessibilitySucceedsFirstWhenVerified() async throws {
        let handoff = RecordingFailsafeHandoff()
        let clock = StepAdvancingClock(step: .milliseconds(20))
        let ax = FakeInjectionStrategy(rung: .accessibility, outcome: .succeeded(verified: true))

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: [.accessibility: ax],
            handoff: handoff,
            clock: clock)

        XCTAssertEqual(result.rung, .accessibility)
        XCTAssertEqual(result.attempted, [.accessibility])
        XCTAssertTrue(result.verified, "the read-back truth carries into the result")
        XCTAssertEqual(result.elapsed, .milliseconds(20), "one rung turn at 20 ms per turn")

        let held = await handoff.held
        XCTAssertTrue(held.isEmpty, "a delivered transcript is never held")
    }

    /// Clipboard succeeds with `succeeded(verified: false)` — its raw truth — and that is *not* a
    /// failure, because the read-back standard is accessibility's, not the ladder's: the adapter
    /// reports raw truth only, and the *decision* interprets (`ARCHITECTURE.md:400`).
    func testClipboardSucceedsWithoutReadBackAndCarriesTheRawTruth() async throws {
        let handoff = RecordingFailsafeHandoff()
        let clock = StepAdvancingClock(step: .milliseconds(20))
        let ax = FakeInjectionStrategy(rung: .accessibility, outcome: .failed)
        let clipboard = FakeInjectionStrategy(rung: .clipboardPaste, outcome: .succeeded(verified: false))

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: [.accessibility: ax, .clipboardPaste: clipboard],
            handoff: handoff,
            clock: clock)

        XCTAssertEqual(result.rung, .clipboardPaste)
        XCTAssertEqual(result.attempted, [.accessibility, .clipboardPaste])
        XCTAssertFalse(result.verified, "the result carries the raw truth: clipboard has no read-back")
        XCTAssertEqual(result.elapsed, .milliseconds(40))
    }

    /// The workhorse answer: the first two rungs fail and keystroke synthesis delivers, with the
    /// full prefix trace recorded.
    func testKeystrokeDeliversAfterTheFirstTwoRungsFail() async throws {
        let handoff = RecordingFailsafeHandoff()
        let clock = StepAdvancingClock(step: .milliseconds(20))
        let ax = FakeInjectionStrategy(rung: .accessibility, outcome: .failed)
        let clipboard = FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed)
        let keystroke = FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .succeeded(verified: false))

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: [.accessibility: ax, .clipboardPaste: clipboard, .keystrokeSynthesis: keystroke],
            handoff: handoff,
            clock: clock)

        XCTAssertEqual(result.rung, .keystrokeSynthesis)
        XCTAssertEqual(result.attempted, [.accessibility, .clipboardPaste, .keystrokeSynthesis])
        XCTAssertEqual(result.elapsed, .milliseconds(60))
    }

    /// **The silent-lie catch**: an accessibility rung reporting `succeeded(verified: false)`
    /// counts as *failure* and falls through to the next rung
    /// (`ARCHITECTURE.md:400` — the check that turns R1's silent lie into a caught failure).
    func testTheSilentLieCountsAsFailureAndFallsThrough() async throws {
        let handoff = RecordingFailsafeHandoff()
        let clock = StepAdvancingClock(step: .milliseconds(20))
        let ax = FakeInjectionStrategy(rung: .accessibility, outcome: .succeeded(verified: false))
        let clipboard = FakeInjectionStrategy(rung: .clipboardPaste, outcome: .succeeded(verified: false))

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: [.accessibility: ax, .clipboardPaste: clipboard],
            handoff: handoff,
            clock: clock)

        XCTAssertEqual(result.rung, .clipboardPaste)
        XCTAssertEqual(result.attempted, [.accessibility, .clipboardPaste])
        XCTAssertFalse(result.verified)
    }

    /// The silent lie with nowhere to fall: the lie is recorded in the trace and the ladder
    /// exhausts to the failsafe — a lying "success" must never become the reported outcome.
    func testTheSilentLieWithNowhereToFallEndsInTheFailsafe() async throws {
        let handoff = RecordingFailsafeHandoff()
        let clock = StepAdvancingClock(step: .milliseconds(20))
        let ax = FakeInjectionStrategy(rung: .accessibility, outcome: .succeeded(verified: false))
        let clipboard = FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed)
        let keystroke = FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed)

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: [.accessibility: ax, .clipboardPaste: clipboard, .keystrokeSynthesis: keystroke],
            handoff: handoff,
            clock: clock)

        XCTAssertEqual(result.rung, .widgetFailsafe)
        XCTAssertEqual(result.attempted, [.accessibility, .clipboardPaste, .keystrokeSynthesis])
        let held = await handoff.held
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].reason, .exhausted)
    }

    // MARK: - Missing strategies

    /// A rung absent from the injected strategy set counts as failed: recorded in the trace, never
    /// consulted, and the ladder moves on (C8's store may demote a rung to absent).
    func testARungAbsentFromTheStrategyMapIsRecordedAsFailedAndSkipped() async throws {
        let handoff = RecordingFailsafeHandoff()
        let clock = StepAdvancingClock(step: .milliseconds(20))
        let clipboard = FakeInjectionStrategy(rung: .clipboardPaste, outcome: .succeeded(verified: false))

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: [.clipboardPaste: clipboard],
            handoff: handoff,
            clock: clock)

        XCTAssertEqual(result.rung, .clipboardPaste)
        XCTAssertEqual(result.attempted, [.accessibility, .clipboardPaste])
        let clipboardCalls = await clipboard.callCount
        XCTAssertEqual(clipboardCalls, 1)
    }

    /// A strategy set missing every rung exhausts to the failsafe with the full trace — the map is
    /// the truth, and there is no implicit recovery.
    func testAStrategyMapMissingEveryRungExhaustsToTheFailsafe() async throws {
        let handoff = RecordingFailsafeHandoff()

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: [:],
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)))

        XCTAssertEqual(result.rung, .widgetFailsafe)
        XCTAssertEqual(result.attempted, defaultOrder)
        let held = await handoff.held
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].reason, .exhausted)
    }

    // MARK: - Fault injection (the acceptance)

    /// The acceptance (`CAPABILITY_ROADMAP.md:106`), over the closed set: every combination of the
    /// three rungs' outcomes — success, silent lie, and failure — driven through the ladder, with
    /// the exact outcome hand-written for each row rather than derived from the implementation.
    ///
    /// The zero-loss assertion is **exact**: the handoff received the transcript in exactly the
    /// rows that exhaust the ladder, and received nothing in the rows a rung delivered — no
    /// tolerance band, no "at least one hold", no counting of calls the decision is believed to
    /// have made.
    func testEveryOutcomeCombinationLosesNothingAndHoldsExactlyWhenExhausted() async throws {
        struct Row {
            let ax: RungAttempt
            let clipboard: RungAttempt
            let keystroke: RungAttempt
            let expectedRung: InjectionRung
            let expectedAttempted: [InjectionRung]
            let expectedHeld: Bool
        }
        let rows: [Row] = [
            Row(ax: .succeeded(verified: true), clipboard: .succeeded(verified: false), keystroke: .succeeded(verified: false),
                expectedRung: .accessibility, expectedAttempted: [.accessibility], expectedHeld: false),
            Row(ax: .succeeded(verified: true), clipboard: .succeeded(verified: false), keystroke: .failed,
                expectedRung: .accessibility, expectedAttempted: [.accessibility], expectedHeld: false),
            Row(ax: .succeeded(verified: true), clipboard: .failed, keystroke: .succeeded(verified: false),
                expectedRung: .accessibility, expectedAttempted: [.accessibility], expectedHeld: false),
            Row(ax: .succeeded(verified: true), clipboard: .failed, keystroke: .failed,
                expectedRung: .accessibility, expectedAttempted: [.accessibility], expectedHeld: false),
            Row(ax: .succeeded(verified: false), clipboard: .succeeded(verified: false), keystroke: .succeeded(verified: false),
                expectedRung: .clipboardPaste, expectedAttempted: [.accessibility, .clipboardPaste], expectedHeld: false),
            Row(ax: .succeeded(verified: false), clipboard: .succeeded(verified: false), keystroke: .failed,
                expectedRung: .clipboardPaste, expectedAttempted: [.accessibility, .clipboardPaste], expectedHeld: false),
            Row(ax: .succeeded(verified: false), clipboard: .failed, keystroke: .succeeded(verified: false),
                expectedRung: .keystrokeSynthesis, expectedAttempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis], expectedHeld: false),
            Row(ax: .succeeded(verified: false), clipboard: .failed, keystroke: .failed,
                expectedRung: .widgetFailsafe, expectedAttempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis], expectedHeld: true),
            Row(ax: .failed, clipboard: .succeeded(verified: false), keystroke: .succeeded(verified: false),
                expectedRung: .clipboardPaste, expectedAttempted: [.accessibility, .clipboardPaste], expectedHeld: false),
            Row(ax: .failed, clipboard: .succeeded(verified: false), keystroke: .failed,
                expectedRung: .clipboardPaste, expectedAttempted: [.accessibility, .clipboardPaste], expectedHeld: false),
            Row(ax: .failed, clipboard: .failed, keystroke: .succeeded(verified: false),
                expectedRung: .keystrokeSynthesis, expectedAttempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis], expectedHeld: false),
            Row(ax: .failed, clipboard: .failed, keystroke: .failed,
                expectedRung: .widgetFailsafe, expectedAttempted: [.accessibility, .clipboardPaste, .keystrokeSynthesis], expectedHeld: true),
        ]
        XCTAssertEqual(rows.count, 12, "3 × 2 × 2 outcome combinations over the three rungs")

        for (index, row) in rows.enumerated() {
            let handoff = RecordingFailsafeHandoff()
            let clock = StepAdvancingClock(step: .milliseconds(20))
            let strategies: [InjectionRung: any InjectionRungStrategy] = [
                .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: row.ax),
                .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: row.clipboard),
                .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: row.keystroke),
            ]

            let result = try await runDecision(
                orderedRungs: defaultOrder,
                strategies: strategies,
                handoff: handoff,
                clock: clock)

            XCTAssertEqual(result.rung, row.expectedRung, "row \(index)")
            XCTAssertEqual(result.attempted, row.expectedAttempted, "row \(index)")

            let held = await handoff.held
            if row.expectedHeld {
                XCTAssertEqual(held.count, 1, "row \(index): the exhausted ladder must have held the transcript")
                XCTAssertEqual(held[0].text, "the words", "row \(index): the held text is the input, verbatim")
                XCTAssertEqual(held[0].reason, .exhausted, "row \(index)")
                XCTAssertEqual(held[0].targetAppName, "Slack", "row \(index)")
            } else {
                XCTAssertTrue(held.isEmpty, "row \(index): a delivered transcript must not be held")
            }
        }
    }

    /// Every rung forced to fail **in sequence**, over every ordering of the ladder: the failsafe
    /// holds the transcript in all six, each time with that ordering's own trace — C8's memory
    /// input, order intact.
    func testEveryOrderingOfFailingRungsHoldsTheTranscriptWithItsOwnTrace() async throws {
        let orderings: [[InjectionRung]] = [
            [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            [.accessibility, .keystrokeSynthesis, .clipboardPaste],
            [.clipboardPaste, .accessibility, .keystrokeSynthesis],
            [.clipboardPaste, .keystrokeSynthesis, .accessibility],
            [.keystrokeSynthesis, .accessibility, .clipboardPaste],
            [.keystrokeSynthesis, .clipboardPaste, .accessibility],
        ]

        for ordering in orderings {
            let handoff = RecordingFailsafeHandoff()
            let strategies: [InjectionRung: any InjectionRungStrategy] = [
                .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
                .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed),
                .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
            ]

            let result = try await runDecision(
                orderedRungs: ordering,
                strategies: strategies,
                handoff: handoff,
                clock: StepAdvancingClock(step: .milliseconds(20)))

            XCTAssertEqual(result.rung, .widgetFailsafe, "ordering \(ordering)")
            XCTAssertEqual(result.attempted, ordering, "the trace is the ordering, intact")

            let held = await handoff.held
            XCTAssertEqual(held.count, 1, "ordering \(ordering): zero loss")
            XCTAssertEqual(held[0].text, "the words")
            XCTAssertEqual(held[0].reason, .exhausted)
        }
    }

    // MARK: - The failsafe's payload

    /// The failsafe routes the transcript with text, reason, app name and the injected clock's
    /// capture instant — the journal's schema and the window's "{app}" copy read one shape.
    func testTheFailsafeHandsTextReasonAppAndCaptureInstantToTheHandoff() async throws {
        let handoff = RecordingFailsafeHandoff()
        let clock = StepAdvancingClock(step: .milliseconds(20))
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed),
            .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
        ]

        _ = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: strategies,
            handoff: handoff,
            clock: clock)

        let held = await handoff.held
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].text, "the words", "the text is carried verbatim")
        XCTAssertEqual(held[0].reason, .exhausted)
        XCTAssertEqual(held[0].targetAppName, "Slack")
        XCTAssertEqual(held[0].capturedAt, .milliseconds(80), "the reading at hand-off: start plus three turns")
    }

    /// The decision passes the caller's text and context through to every rung it consults —
    /// nothing is rewritten, filtered or re-derived between the seam and the rungs.
    func testTheDecisionPassesTextAndTargetThroughToTheRungs() async throws {
        let handoff = RecordingFailsafeHandoff()
        let target = TargetContext(
            bundleID: "com.example.Notes", windowTitle: "Untitled", isSecureInput: false)
        let clipboard = FakeInjectionStrategy(rung: .clipboardPaste, outcome: .succeeded(verified: false))

        _ = try await runDecision(
            text: "verbatim words",
            target: target,
            orderedRungs: defaultOrder,
            strategies: [.clipboardPaste: clipboard],
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)))

        let receivedText = await clipboard.receivedText
        let receivedTarget = await clipboard.receivedTarget
        XCTAssertEqual(receivedText, "verbatim words")
        XCTAssertEqual(receivedTarget, target)
    }

    // MARK: - Elapsed and the budget

    /// `elapsed` accumulates deltas between the injected clock's readings, one per rung turn —
    /// never a wall clock, never a remembered start.
    func testElapsedIsAccumulatedFromTheInjectedClockAcrossTheRungs() async throws {
        let handoff = RecordingFailsafeHandoff()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed),
            .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
        ]

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: strategies,
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)))

        XCTAssertEqual(result.elapsed, .milliseconds(60), "three rung turns at 20 ms each")
    }

    /// The ladder budget: `ARCHITECTURE.md:271` gives the whole `TextInjector` ladder ≤100 ms, and
    /// at realistic per-rung costs — 25 ms across the three rungs of the default order — the
    /// decision stays inside it while still reporting the truth.
    func testTheLadderBudgetStaysWithinOneHundredMillisecondsAtRealisticCosts() async throws {
        let handoff = RecordingFailsafeHandoff()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed),
            .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
        ]

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: strategies,
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(25)))

        XCTAssertEqual(result.elapsed, .milliseconds(75))
        XCTAssertLessThanOrEqual(
            result.elapsed, .milliseconds(100),
            "the full exhausted ladder must stay inside ARCHITECTURE.md:271's budget")
    }

    /// The negative-delta rule, mirrored from `SessionMachine.tick()`: a clock that steps backwards
    /// contributes nothing — a backwards jump can never extend a session's ladder time.
    func testANegativeClockDeltaContributesNothingToElapsed() async throws {
        let handoff = RecordingFailsafeHandoff()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed),
            .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
        ]

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: strategies,
            handoff: handoff,
            clock: StepAdvancingClock(step: Duration.milliseconds(-5)))

        XCTAssertEqual(result.elapsed, .zero)
    }

    /// `elapsed` covers only the rungs actually attempted: a delivery at rung two stops the clock
    /// there.
    func testElapsedCountsOnlyTheRungsActuallyAttempted() async throws {
        let handoff = RecordingFailsafeHandoff()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .succeeded(verified: false)),
        ]

        let result = try await runDecision(
            orderedRungs: defaultOrder,
            strategies: strategies,
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)))

        XCTAssertEqual(result.rung, .clipboardPaste)
        XCTAssertEqual(result.elapsed, .milliseconds(40))
    }

    // MARK: - The handoff's throw (plan §8)

    /// A handoff that refuses custody surfaces its error through the decision — the throw is the
    /// seam's honest report, and the journal contract (durable before return) is what makes the
    /// branch unreachable in practice (I1 floor).
    func testAHandoffThatRefusesCustodySurfacesTheErrorThroughTheDecision() async throws {
        let handoff = RecordingFailsafeHandoff()
        await handoff.refuseNextHold()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed),
            .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
        ]

        do {
            _ = try await runDecision(
                orderedRungs: defaultOrder,
                strategies: strategies,
                handoff: handoff,
                clock: StepAdvancingClock(step: .milliseconds(20)))
            XCTFail("a refused hand-off must surface as a throw, not as a successful return")
        } catch {
            // Expected — the throw is how the decision surfaces the journal's failure.
        }
    }

    // MARK: - The order seam

    /// The default order, pinned: an allowlisted bundle starts at accessibility
    /// (`ARCHITECTURE.md:398-399`), because AX is opportunistic rather than primary — the allowlist
    /// is what earns it the first position.
    func testDefaultOrderPutsAccessibilityFirstForAnAllowlistedApp() {
        let order = DefaultInjectionStrategyOrder(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]))

        XCTAssertEqual(
            order.orderedRungs(for: "com.example.Allowed"),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis])
    }

    /// The default order for everything else — including no focused app — is clipboard first, and
    /// accessibility never appears (`ROADMAP.md:47`'s "clipboard-paste primary, AX opportunistic",
    /// with the default allowlist empty, makes clipboard the de facto primary).
    func testDefaultOrderStartsWithClipboardAndNeverNamesAccessibilityForUnallowlistedApps() {
        let order = DefaultInjectionStrategyOrder(
            allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"]))

        XCTAssertEqual(
            order.orderedRungs(for: "com.example.Other"),
            [.clipboardPaste, .keystrokeSynthesis])
        XCTAssertEqual(
            order.orderedRungs(for: nil),
            [.clipboardPaste, .keystrokeSynthesis])
    }

    /// The failsafe is never in the attempt list — it is the decision's terminal, not a rung
    /// (`plan §3`).
    func testTheDefaultOrderNeverNamesTheWidgetFailsafe() {
        let order = DefaultInjectionStrategyOrder(allowlist: EmptyInjectionAllowlist())

        for bundleID in ["com.example.Allowed", "com.example.Other", nil] {
            XCTAssertFalse(
                order.orderedRungs(for: bundleID).contains(.widgetFailsafe),
                "the failsafe must not appear for \(String(describing: bundleID))")
        }
    }

    /// The C4 default allowlist contains nothing: the seeded list lands in the adapters aspect.
    func testEmptyInjectionAllowlistContainsNoBundle() {
        XCTAssertFalse(EmptyInjectionAllowlist().contains(bundleID: "com.example.Anything"))
    }

    /// A custom injected order changes the attempt sequence with no decision-code change — the
    /// decision reads the resolved list, so C8's per-app strategy memory slots in behind the same
    /// seam.
    func testACustomInjectedOrderChangesTheAttemptSequenceWithNoDecisionCodeChange() async throws {
        let handoff = RecordingFailsafeHandoff()
        let clock = StepAdvancingClock(step: .milliseconds(20))
        let keystroke = FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .succeeded(verified: false))

        let result = try await runDecision(
            orderedRungs: [.keystrokeSynthesis, .clipboardPaste, .accessibility],
            strategies: [.keystrokeSynthesis: keystroke],
            handoff: handoff,
            clock: clock)

        XCTAssertEqual(result.rung, .keystrokeSynthesis)
        XCTAssertEqual(result.attempted, [.keystrokeSynthesis])
        let held = await handoff.held
        XCTAssertTrue(held.isEmpty)
    }

    // MARK: - The orchestrator (LadderInjector)

    /// The injector wires the default order to an unallowlisted target: accessibility is absent
    /// from the sequence, so clipboard — the workhorse — delivers.
    func testLadderInjectorDeliversThroughTheInjectedDefaultOrderForAnUnallowlistedApp() async throws {
        let handoff = RecordingFailsafeHandoff()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .succeeded(verified: false)),
            .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
        ]
        let injector = LadderInjector(
            strategies: strategies,
            order: DefaultInjectionStrategyOrder(allowlist: EmptyInjectionAllowlist()),
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)))

        let result = await injector.inject(
            "the words", into: target(bundleID: "com.example.Other"))

        XCTAssertEqual(result.rung, .clipboardPaste)
        XCTAssertEqual(result.attempted, [.clipboardPaste])
    }

    /// The injector tries accessibility first for an allowlisted app — the allowlist seam, wired
    /// through the default order, earns AX the first position.
    func testLadderInjectorTriesAccessibilityFirstForAnAllowlistedApp() async throws {
        let handoff = RecordingFailsafeHandoff()
        let ax = FakeInjectionStrategy(rung: .accessibility, outcome: .succeeded(verified: true))
        let injector = LadderInjector(
            strategies: [.accessibility: ax],
            order: DefaultInjectionStrategyOrder(
                allowlist: FakeInjectionAllowlist(allowed: ["com.example.Allowed"])),
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)))

        let result = await injector.inject(
            "the words", into: target(bundleID: "com.example.Allowed"))

        XCTAssertEqual(result.rung, .accessibility)
        XCTAssertEqual(result.attempted, [.accessibility])
    }

    /// A failsafe path through the injector is a *successful* outcome under I1: `rung ==
    /// .widgetFailsafe`, returned — never thrown (`ARCHITECTURE.md:199`).
    func testLadderInjectorReportsTheFailsafePathAsASuccessfulOutcome() async throws {
        let handoff = RecordingFailsafeHandoff()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed),
            .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
        ]
        let injector = LadderInjector(
            strategies: strategies,
            order: DefaultInjectionStrategyOrder(allowlist: EmptyInjectionAllowlist()),
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)))

        let result = await injector.inject(
            "the words", into: target())

        XCTAssertEqual(result.rung, .widgetFailsafe)
        XCTAssertEqual(
            result.attempted, [.clipboardPaste, .keystrokeSynthesis],
            "the empty allowlist keeps accessibility out of the attempt list, so the trace is the unallowlisted order")
        XCTAssertFalse(result.verified)
        let held = await handoff.held
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held[0].reason, .exhausted)
    }

    /// A handoff that refuses custody cannot crash the injector: `TextInjector` has no throwing
    /// variant, so the failure ends in the failsafe outcome — the residual the journal's
    /// durable-before-return contract makes unreachable.
    func testLadderInjectorReturnsTheFailsafeOutcomeWhenTheHandoffRefusesCustody() async throws {
        let handoff = RecordingFailsafeHandoff()
        await handoff.refuseNextHold()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
            .clipboardPaste: FakeInjectionStrategy(rung: .clipboardPaste, outcome: .failed),
            .keystrokeSynthesis: FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .failed),
        ]
        let injector = LadderInjector(
            strategies: strategies,
            order: DefaultInjectionStrategyOrder(allowlist: EmptyInjectionAllowlist()),
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)))

        let result = await injector.inject(
            "the words", into: target())

        XCTAssertEqual(result.rung, .widgetFailsafe)
    }

    /// The injector runs the injected order, whatever it is — a custom order changes the sequence
    /// with no decision-code change, through the full orchestration.
    func testLadderInjectorUsesTheInjectedOrder() async throws {
        let handoff = RecordingFailsafeHandoff()
        let keystroke = FakeInjectionStrategy(rung: .keystrokeSynthesis, outcome: .succeeded(verified: false))
        let injector = LadderInjector(
            strategies: [.keystrokeSynthesis: keystroke],
            order: FakeInjectionStrategyOrder(rungs: [.keystrokeSynthesis]),
            handoff: handoff,
            clock: StepAdvancingClock(step: .milliseconds(20)))

        let result = await injector.inject(
            "the words", into: target())

        XCTAssertEqual(result.rung, .keystrokeSynthesis)
        XCTAssertEqual(result.attempted, [.keystrokeSynthesis])
    }
}
