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
import VoccaUI
import XCTest

/// **The Usage tab's decisions** (`daily-use-ledger/usage-tab/spec.md` E2, E3, E6, E10) — a pure
/// reducer over an injected snapshot, in the ``AppsTabReducer`` shape.
///
/// Three things it deliberately does **not** do, and each absence is the design:
///
/// - **it has no clock.** A streak is a fact about *today* and this module cannot know what day it
///   is (`CoreBoundaryTests.testVoccaCoreReadsNoClockOfItsOwn` puts the same rule one layer down).
///   The streak therefore arrives inside the snapshot, already answered by the wiring that
///   resolved the wall-clock instant into a ``CalendarDay`` — the ``AppStrategyEntry/isAllowlisted``
///   move, applied to the one number on this tab that a clock could invent;
/// - **it does not compute a rate.** Nothing here divides. The rung tallies are counts, and the
///   only denominator that could turn them into an injection-success figure belongs to the
///   matrix (`docs/STATUS.md:44-46`), which this tab is not;
/// - **it never merges onboarding into real work.** The two columns travel side by side from
///   ``DayAggregate`` to the row and are never added.
final class UsageTabReducerTests: XCTestCase {

    // MARK: - Fixtures

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> CalendarDay {
        guard let day = CalendarDay(year: year, month: month, day: dayOfMonth) else {
            preconditionFailure("the fixture named an impossible date")
        }
        return day
    }

    /// A day built by folding real records, so the counts under test are the ones the shipped
    /// fold produces rather than hand-written numbers that agree with nothing.
    private func aggregate(
        _ day: CalendarDay,
        realWork: [SessionOutcomeClass] = [],
        onboarding: [SessionOutcomeClass] = [],
        latencies: [Duration] = []
    ) -> DayAggregate {
        var built = DayAggregate(day: day)
        for (index, outcome) in realWork.enumerated() {
            let elapsed = index < latencies.count ? latencies[index] : nil
            built.fold(record(kind: .dictation, outcome: outcome, cycle: elapsed))
        }
        for outcome in onboarding {
            built.fold(record(kind: .onboarding, outcome: outcome, cycle: nil))
        }
        return built
    }

    private var nextRecordID = 0

    private func record(
        kind: SessionKind, outcome: SessionOutcomeClass, cycle: Duration?
    ) -> SessionRecord {
        nextRecordID += 1
        return SessionRecord(
            id: SessionRecord.ID(rawValue: nextRecordID), outcome: outcome,
            spans: cycle.map { [LatencySpan.recorded(name: .inject, elapsed: $0)] } ?? [],
            engine: nil, kind: kind)
    }

    private func loaded(_ days: [DayAggregate], streak: Int = 0) -> UsageTabState {
        UsageTabReducer.reduce(
            .initial, .snapshotLoaded(UsageSnapshot(days: days, streak: streak)))
    }

    // MARK: - E2: "we haven't looked" is not "there is nothing"

    /// Nothing is claimed before the file is read. `isLoaded == false` with no rows is the state
    /// the window opens in, and it is **not** the empty state — the distinction the
    /// `DictionarySettingsPage` guard exists for, and the one that stops a tab whose store failed
    /// to load from telling a daily user they have never dictated.
    func testDefaultStateIsNotLoadedAndHoldsNothing() {
        XCTAssertFalse(UsageTabState.initial.isLoaded)
        XCTAssertTrue(UsageTabState.initial.rows.isEmpty)
        XCTAssertEqual(UsageTabState.initial.streak, 0)
    }

    /// The two states are distinguishable **as values**, not only by convention: an empty load
    /// differs from the initial state, so a view cannot render one for the other by accident.
    func testALoadedEmptyWindowIsNotEqualToTheUnreadState() {
        let empty = loaded([])
        XCTAssertTrue(empty.isLoaded)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertNotEqual(
            empty, UsageTabState.initial,
            """
            "read, and there is nothing" now equals "not read yet". The two must not look alike: \
            a store that failed to load would otherwise tell a daily user they have never \
            dictated.
            """)
    }

    // MARK: - E3: ordering is a decision

    /// Rows come back newest first, whatever order the window held them in. ``UsageWindow`` keeps
    /// its days ascending (eviction takes from the front); a reader wants today at the top.
    func testRowsAreNewestFirst() {
        let state = loaded([
            aggregate(day(2026, 9, 3), realWork: [.failsafeHeld]),
            aggregate(day(2026, 9, 6), realWork: [.delivered(rung: .clipboardPaste, verified: true)]),
            aggregate(day(2026, 8, 31), realWork: [.lost]),
        ])

        XCTAssertEqual(
            state.rows.map(\.day),
            [day(2026, 9, 6), day(2026, 9, 3), day(2026, 8, 31)],
            "The days are not newest-first — the row a user came to read is not at the top.")
    }

    /// The row's identity is its day, so a table keyed on it is stable across a reload.
    func testARowIsIdentifiedByItsDay() {
        let state = loaded([aggregate(day(2026, 9, 6), realWork: [.aborted])])
        XCTAssertEqual(state.rows.first?.id, day(2026, 9, 6).dayNumber)
        XCTAssertEqual(Set(state.rows.map(\.id)).count, state.rows.count)
    }

    /// The streak arrives with the snapshot and is carried through untouched — the reducer has no
    /// clock and computes nothing about today.
    func testTheStreakIsCarriedFromTheSnapshot() {
        XCTAssertEqual(loaded([aggregate(day(2026, 9, 6), realWork: [.lost])], streak: 4).streak, 4)
        XCTAssertEqual(loaded([], streak: 0).streak, 0)
    }

    // MARK: - E6: onboarding travels beside real work, never inside it

    /// A day holding both kinds keeps them apart, at the level of the row. The real-work column
    /// counts only dictation, the onboarding column only the setup demo, and neither total
    /// contains the other's sessions.
    func testOnboardingCountsAreNeverSummedIntoRealWork() {
        let state = loaded([
            aggregate(
                day(2026, 9, 6),
                realWork: [.delivered(rung: .clipboardPaste, verified: true), .aborted],
                onboarding: [
                    .delivered(rung: .accessibility, verified: true), .failsafeHeld, .emptySkip,
                ])
        ])

        guard let row = state.rows.first else { return XCTFail("no row for a day that was folded") }
        XCTAssertEqual(row.realWork.total, 2)
        XCTAssertEqual(row.realWork.delivered, 1)
        XCTAssertEqual(row.onboarding.total, 3)
        XCTAssertEqual(row.onboarding.delivered, 1)
        XCTAssertEqual(
            row.dictations, 1,
            "A day's dictation count took in the setup demo's transcripts.")
        XCTAssertEqual(
            row.realWork.deliveries(via: .accessibility), 0,
            """
            The onboarding delivery was credited to the real-work rung tally. A setup demo that \
            leaks into the injection counts makes every number on the tab about a different \
            population than its heading says.
            """)
    }

    /// The window-level totals keep the same separation. "38 dictations" must never be a number
    /// the setup demo contributed to.
    func testWindowTotalsKeepTheTwoKindsApart() {
        let state = loaded([
            aggregate(
                day(2026, 9, 6), realWork: [.delivered(rung: .clipboardPaste, verified: true)],
                onboarding: [.failsafeHeld]),
            aggregate(day(2026, 9, 5), realWork: [.failsafeHeld, .failed], onboarding: [.aborted]),
        ])

        XCTAssertEqual(state.realWorkSessionCount, 3)
        XCTAssertEqual(state.onboardingSessionCount, 2)
        XCTAssertEqual(state.dictationCount, 2, "aborted and failed produced no transcript")
        XCTAssertEqual(state.daysRecorded, 2)
    }

    /// A day whose only sessions were cancelled is a day recorded and **not** a day dictated — the
    /// distinction ``UsageWindow/streak(asOf:)`` already draws, kept here so the two surfaces
    /// cannot disagree about what a day of use is.
    func testADayOfNothingButCancellationsCountsNoDictations() {
        let state = loaded([aggregate(day(2026, 9, 6), realWork: [.aborted, .emptySkip, .failed])])
        XCTAssertEqual(state.daysRecorded, 1)
        XCTAssertEqual(state.dictationCount, 0)
        XCTAssertEqual(state.rows.first?.dictations, 0)
    }

    // MARK: - Latency travels as a bound, or not at all

    /// A day with samples carries both percentiles as ``LatencyBucketBound``s — never as an `Int`,
    /// which is the type that would let a view print bucket resolution as a spot value.
    func testAMeasuredDayCarriesBothPercentilesAsBounds() {
        let state = loaded([
            aggregate(
                day(2026, 9, 6),
                realWork: Array(repeating: .delivered(rung: .clipboardPaste, verified: true), count: 4),
                latencies: [.milliseconds(90), .milliseconds(140), .milliseconds(390), .milliseconds(7000)])
        ])

        guard let row = state.rows.first else { return XCTFail("no row for a day that was folded") }
        XCTAssertEqual(row.latencySampleCount, 4)
        XCTAssertEqual(row.medianLatency, .atMostMilliseconds(150))
        XCTAssertEqual(row.ninetyFifthLatency, .aboveMilliseconds(5000))
    }

    /// A day that measured nothing carries `nil`, not a zero bound. The fabricated 0 ms would land
    /// in the fastest bucket the histogram has and read as the best day on record.
    func testAnUnmeasuredDayCarriesNoPercentileAtAll() {
        let state = loaded([aggregate(day(2026, 9, 6), realWork: [.failsafeHeld, .aborted])])
        guard let row = state.rows.first else { return XCTFail("no row for a day that was folded") }
        XCTAssertEqual(row.latencySampleCount, 0)
        XCTAssertNil(row.medianLatency)
        XCTAssertNil(row.ninetyFifthLatency)
    }

    // MARK: - Clearing

    /// Clearing empties the rows and the streak and leaves `isLoaded` **true**: the file was read,
    /// and it is now empty. Dropping back to the unread state would put the page back into
    /// "we haven't looked", which is a different and false claim.
    func testClearedEmptiesTheStateButKeepsItRead() {
        let state = UsageTabReducer.reduce(
            loaded([aggregate(day(2026, 9, 6), realWork: [.lost])], streak: 3), .cleared)
        XCTAssertTrue(state.isLoaded)
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertEqual(state.streak, 0)
        XCTAssertEqual(state, loaded([]))
    }

    // MARK: - E10: equality distinguishes every field

    /// Every stored field of ``UsageTabState`` participates in `==`. A synthesised conformance
    /// that quietly stopped comparing one of them would make a test asserting on state pass while
    /// the tab showed something else.
    func testStateEqualityDistinguishesEveryField() {
        let base = loaded([aggregate(day(2026, 9, 6), realWork: [.lost])], streak: 3)

        var differentRows = base
        differentRows.rows = []
        XCTAssertNotEqual(base, differentRows, "rows do not participate in equality")

        var differentLoaded = base
        differentLoaded.isLoaded = false
        XCTAssertNotEqual(base, differentLoaded, "isLoaded does not participate in equality")

        var differentStreak = base
        differentStreak.streak = 4
        XCTAssertNotEqual(base, differentStreak, "streak does not participate in equality")

        XCTAssertEqual(base, loaded([aggregate(day(2026, 9, 6), realWork: [.lost])], streak: 3))
    }

    /// And every field of a row. The row is what the table renders, so a field outside `==` is a
    /// column that can change without any test noticing.
    func testRowEqualityDistinguishesEveryField() {
        let sample = Duration.milliseconds(90)
        let base = UsageDayRow(
            day: day(2026, 9, 6),
            realWork: aggregate(
                day(2026, 9, 6), realWork: [.delivered(rung: .clipboardPaste, verified: true)]
            ).realWork,
            onboarding: aggregate(day(2026, 9, 6), onboarding: [.failsafeHeld]).onboarding,
            medianLatency: .atMostMilliseconds(100),
            ninetyFifthLatency: .atMostMilliseconds(100),
            latencySampleCount: 1)
        _ = sample

        XCTAssertNotEqual(
            base,
            UsageDayRow(
                day: day(2026, 9, 5), realWork: base.realWork, onboarding: base.onboarding,
                medianLatency: base.medianLatency, ninetyFifthLatency: base.ninetyFifthLatency,
                latencySampleCount: base.latencySampleCount),
            "day does not participate in equality")
        XCTAssertNotEqual(
            base,
            UsageDayRow(
                day: base.day, realWork: DayAggregate.OutcomeCounts(),
                onboarding: base.onboarding, medianLatency: base.medianLatency,
                ninetyFifthLatency: base.ninetyFifthLatency,
                latencySampleCount: base.latencySampleCount),
            "realWork does not participate in equality")
        XCTAssertNotEqual(
            base,
            UsageDayRow(
                day: base.day, realWork: base.realWork, onboarding: DayAggregate.OutcomeCounts(),
                medianLatency: base.medianLatency,
                ninetyFifthLatency: base.ninetyFifthLatency,
                latencySampleCount: base.latencySampleCount),
            "onboarding does not participate in equality")
        XCTAssertNotEqual(
            base,
            UsageDayRow(
                day: base.day, realWork: base.realWork, onboarding: base.onboarding,
                medianLatency: nil, ninetyFifthLatency: base.ninetyFifthLatency,
                latencySampleCount: base.latencySampleCount),
            "medianLatency does not participate in equality")
        XCTAssertNotEqual(
            base,
            UsageDayRow(
                day: base.day, realWork: base.realWork, onboarding: base.onboarding,
                medianLatency: base.medianLatency, ninetyFifthLatency: nil,
                latencySampleCount: base.latencySampleCount),
            "ninetyFifthLatency does not participate in equality")
        XCTAssertNotEqual(
            base,
            UsageDayRow(
                day: base.day, realWork: base.realWork, onboarding: base.onboarding,
                medianLatency: base.medianLatency, ninetyFifthLatency: base.ninetyFifthLatency,
                latencySampleCount: 2),
            "latencySampleCount does not participate in equality")
    }

    /// The snapshot handed in is itself a value with both fields in `==`, so a wiring test can
    /// assert on what it passed.
    func testSnapshotEqualityDistinguishesEveryField() {
        let days = [aggregate(day(2026, 9, 6), realWork: [.lost])]
        XCTAssertEqual(UsageSnapshot(days: days, streak: 1), UsageSnapshot(days: days, streak: 1))
        XCTAssertNotEqual(
            UsageSnapshot(days: days, streak: 1), UsageSnapshot(days: days, streak: 2))
        XCTAssertNotEqual(UsageSnapshot(days: days, streak: 1), UsageSnapshot(days: [], streak: 1))
    }

    // MARK: - The closed outcome set

    /// The six outcome columns a row renders are exactly the six classes the pipeline can exit
    /// by, and each reads its own tally off ``DayAggregate/OutcomeCounts``. A seventh class must
    /// break here rather than fall silently into an existing column.
    func testEveryOutcomeReadsItsOwnTally() {
        let counts = aggregate(
            day(2026, 9, 6),
            realWork: [
                .delivered(rung: .clipboardPaste, verified: true), .failsafeHeld, .failsafeHeld,
                .aborted, .aborted, .aborted, .failed, .failed, .failed, .failed, .lost,
                .emptySkip, .emptySkip, .emptySkip, .emptySkip, .emptySkip,
            ]
        ).realWork

        XCTAssertEqual(UsageOutcome.allCases.count, 6)
        XCTAssertEqual(
            UsageOutcome.allCases.map { $0.count(in: counts) }, [1, 2, 3, 4, 1, 5],
            "an outcome column is reading another column's tally")
        XCTAssertEqual(
            UsageOutcome.allCases.reduce(0) { $0 + $1.count(in: counts) }, counts.total,
            "the six columns no longer partition the day — a session is counted twice or not at all")
    }
}
