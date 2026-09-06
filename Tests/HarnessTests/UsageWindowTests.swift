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

/// ``UsageWindow`` — the bounded run of days a streak is read off — `usage-vocabulary`'s B8–B11.
///
/// The streak is the P0 gate's headline number (`ROADMAP.md:102`), and it is the number in this
/// unit with the most ways to be quietly generous. Each of those ways is a test below:
///
/// - **A day with no sessions is absent, not a zero row.** Absence is precisely what breaks a
///   streak, so a window that materialised empty days would repair every gap it was shown and
///   report an unbroken run over a fortnight the user did not dictate in.
/// - **Only real work extends a run.** Onboarding's TRY IT goes through the same ledger under a
///   different ``SessionKind``, and the gate is about dictating as the *primary text-input
///   method* — which a setup demo, however successful, is not.
/// - **Arrival order is not evidence.** Days can be inserted in any order (a store replaying a
///   file, a late-arriving aggregate), and the streak reads the *set of days present*. A second
///   row for a day already held would double-count it and, worse, could push a real day out of
///   the retained window.
/// - **The window is bounded at thirty days, oldest first.** A cap that only applied at read time
///   would let the collection grow without limit in memory and would make "the oldest day" a
///   function of when someone happened to ask.
///
/// Nothing here reads a clock. `asOf` is an argument, exactly as ``StrategyMemory``'s `now` is —
/// the caller that resolved a wall-clock instant into a ``CalendarDay`` is the only code that
/// could have known the time zone, and it decides once, above this type.
final class UsageWindowTests: XCTestCase {

    // MARK: - Test helpers

    /// A day, unwrapped. Every date this suite names is a real one, so a `nil` here would be a
    /// defect in the fixture rather than in the window.
    private static func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) throws -> CalendarDay {
        try XCTUnwrap(
            CalendarDay(year: year, month: month, day: dayOfMonth),
            "the suite's own fixture date must be a real date")
    }

    /// A hand-built record. `engine` follows the record's own rule — attribution for the routes
    /// that asked the engine, `nil` for the two that never did.
    private static func record(
        _ outcome: SessionOutcomeClass, kind: SessionKind, id: Int
    ) -> SessionRecord {
        let asked: Bool
        switch outcome {
        case .aborted, .emptySkip: asked = false
        default: asked = true
        }
        return SessionRecord(
            id: SessionRecord.ID(rawValue: id), outcome: outcome, spans: [],
            engine: asked
                ? EngineIdentity(
                    id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet", isLocal: true)
                : nil,
            kind: kind)
    }

    /// A day someone dictated on: `sessions` delivered ``SessionKind/dictation`` sessions.
    private static func dayOfRealWork(_ day: CalendarDay, sessions: Int = 1) -> DayAggregate {
        DayAggregate.folded(
            (0..<sessions).map {
                record(.delivered(rung: .clipboardPaste, verified: true), kind: .dictation, id: $0 + 1)
            },
            on: day)
    }

    /// A day of real dictation whose sessions ended in exactly the given outcomes — the helper
    /// for the rule that not every real-work session is evidence a dictation happened.
    private static func dayOfRealWork(
        _ day: CalendarDay, outcomes: [SessionOutcomeClass]
    ) -> DayAggregate {
        DayAggregate.folded(
            outcomes.enumerated().map { record($1, kind: .dictation, id: $0 + 1) }, on: day)
    }

    /// A day that saw only onboarding — and a *successful* demo at that, so the test that this
    /// does not extend a streak cannot be passing for the incidental reason that the demo failed.
    private static func dayOfOnboardingOnly(_ day: CalendarDay) -> DayAggregate {
        DayAggregate.folded(
            [record(.delivered(rung: .clipboardPaste, verified: true), kind: .onboarding, id: 1)],
            on: day)
    }

    /// A window over the given aggregates, inserted in the order written.
    private static func window(_ aggregates: [DayAggregate]) -> UsageWindow {
        var window = UsageWindow()
        for aggregate in aggregates {
            window.insert(aggregate)
        }
        return window
    }

    // MARK: - B8 · consecutive days of real work

    /// Seven consecutive days, each with a real dictation, read as a streak of seven.
    ///
    /// This is the gate's first leg stated at its simplest: `ROADMAP.md:102` counts days
    /// completed, and the count is the number of them in an unbroken run. If this arithmetic is
    /// off by one in either direction the gate is decided on a number nobody can reconstruct.
    func testSevenConsecutiveDaysOfRealWorkReadAsAStreakOfSeven() throws {
        var days: [DayAggregate] = []
        for dayOfMonth in 1...7 {
            days.append(Self.dayOfRealWork(try Self.day(2026, 9, dayOfMonth)))
        }
        let window = Self.window(days)

        XCTAssertEqual(
            window.streak(asOf: try Self.day(2026, 9, 7)), 7,
            """
            The user dictated on each of seven consecutive days, so the streak is seven. This is \
            the figure ROADMAP.md:102's gate is decided on, and it must be the plain count of \
            days in the run — not the run minus its endpoint, and not a day inflated by the \
            window's own bookkeeping.
            """)
    }

    /// One day of real work is a streak of one, not of zero.
    ///
    /// The first day of a streak is the day the user first chose dictation over typing. Reading
    /// it as zero would tell someone who has just started that they have not started.
    func testASingleDayOfRealWorkReadsAsAStreakOfOne() throws {
        let today = try Self.day(2026, 9, 6)
        let window = Self.window([Self.dayOfRealWork(today)])

        XCTAssertEqual(
            window.streak(asOf: today), 1,
            """
            One day of dictation is one day of dictation. A run has to start somewhere, and a \
            streak that only begins counting on the second day would tell a new user their first \
            day did not happen.
            """)
    }

    // MARK: - B9 · a gap, and arrival order

    /// A missing day resets the run: only the days since the gap are counted.
    ///
    /// The gap day is *absent* from the window — nobody dictated, so nothing was recorded — and
    /// absence is the only signal a streak has that a day was skipped. A window that filled the
    /// hole with a zero row would report eight where the honest answer is three.
    func testAGapDayResetsTheStreakToTheRunSinceTheGap() throws {
        // 1–4 September, then nothing on the 5th, then 6–8.
        var days: [DayAggregate] = []
        for dayOfMonth in [1, 2, 3, 4, 6, 7, 8] {
            days.append(Self.dayOfRealWork(try Self.day(2026, 9, dayOfMonth)))
        }
        let window = Self.window(days)

        XCTAssertEqual(
            window.streak(asOf: try Self.day(2026, 9, 8)), 3,
            """
            The user did not dictate on 5 September, so the run before it is over and the current \
            streak is the three days since. Counting through the gap — reporting seven — would \
            hand the gate a number for a week of daily use that never happened.
            """)
        XCTAssertNil(
            window.aggregate(for: try Self.day(2026, 9, 5)),
            """
            A day with no sessions is absent from the window, not stored as a row of zeros. \
            Absence is exactly what breaks a streak, so a materialised empty day would silently \
            repair every gap it was shown.
            """)
    }

    /// A day arriving after a later day updates that day rather than appearing twice.
    ///
    /// Days do not always arrive in order — a store replays a file, an aggregate is rebuilt — and
    /// the window is keyed by the day, not by when it turned up. A duplicate row would double a
    /// day's counts and, in a full window, could evict a real day to make room for a copy of one
    /// already held.
    func testInsertingADayOutOfOrderUpdatesItRatherThanDuplicatingIt() throws {
        let first = try Self.day(2026, 9, 1)
        let second = try Self.day(2026, 9, 2)
        var window = Self.window([
            Self.dayOfRealWork(first, sessions: 1),
            Self.dayOfRealWork(second, sessions: 1),
        ])

        // 1 September comes round again, now carrying three sessions.
        window.insert(Self.dayOfRealWork(first, sessions: 3))

        XCTAssertEqual(
            window.days.count, 2,
            """
            Two calendar days were inserted, so the window holds two days however many times \
            each arrived. A third row would double-count a day and could push a genuinely older \
            day out of a full window to store a copy of one already there.
            """)
        XCTAssertEqual(
            window.aggregate(for: first)?.realWork.delivered, 3,
            """
            The later arrival for 1 September is that day's aggregate now. The window holds one \
            answer per day and the newest one wins, rather than keeping the stale row and \
            discarding a recomputed day.
            """)
        XCTAssertEqual(
            window.days.map(\.day), [first, second],
            """
            The window stays in calendar order regardless of arrival order — that ordering is \
            what eviction and the backwards streak walk both depend on.
            """)
    }

    /// The same set of days produces the same streak whichever order it arrives in.
    ///
    /// The streak reads the set of days present, never the sequence of insertions. If arrival
    /// order changed the answer, restoring a window from disk in a different order would change
    /// the gate's number without a single session having changed.
    func testTheStreakIsIdenticalWhicheverOrderTheSameDaysArriveIn() throws {
        let aggregates = try (1...5).map { Self.dayOfRealWork(try Self.day(2026, 9, $0)) }
        let asOf = try Self.day(2026, 9, 5)

        let inOrder = Self.window(aggregates)
        let reversed = Self.window(aggregates.reversed())
        let shuffled = Self.window([aggregates[2], aggregates[0], aggregates[4], aggregates[1], aggregates[3]])

        XCTAssertEqual(
            inOrder.streak(asOf: asOf), 5,
            "five consecutive days of dictation are a streak of five, inserted oldest-first")
        XCTAssertEqual(
            reversed.streak(asOf: asOf), 5,
            """
            The same five days inserted newest-first are the same five days. A streak that \
            depended on insertion order would change when a store replayed its file backwards, \
            with no dictation having happened or not happened.
            """)
        XCTAssertEqual(
            shuffled.streak(asOf: asOf), 5,
            """
            Arrival order is not evidence about the user's week. The streak is a fact about which \
            days hold real work, and it must be invariant under every permutation of the same days.
            """)
    }

    // MARK: - B8 · the one-day grace

    /// A run ending yesterday still reads in full today, before today's first dictation.
    ///
    /// At nine in the morning on day eight the user has not dictated yet — and telling them their
    /// seven-day streak is zero would be both wrong (the gate counts days *completed*) and
    /// actively discouraging at exactly the moment the habit is most fragile.
    func testARunEndingYesterdayStillReadsInFullWhenAskedAsOfToday() throws {
        let days = try (1...7).map { Self.dayOfRealWork(try Self.day(2026, 9, $0)) }
        let window = Self.window(days)

        XCTAssertEqual(
            window.streak(asOf: try Self.day(2026, 9, 8)), 7,
            """
            Seven days were completed and today has barely started. The gate counts completed \
            days, so a streak asked about before today's first dictation must report the seven \
            that happened — not zero, which is both false and the most discouraging possible \
            answer at the most fragile moment of a new habit.
            """)
    }

    /// Once a full day has passed with no dictation, the run is over.
    ///
    /// The grace is one day wide and no wider. Asked two days after the last session, the answer
    /// is zero: a streak that survived an entire skipped day would be measuring something other
    /// than daily use, and the gate would pass on days the user did not dictate.
    func testARunUnextendedForAFullDayReadsZero() throws {
        let days = try (1...7).map { Self.dayOfRealWork(try Self.day(2026, 9, $0)) }
        let window = Self.window(days)

        XCTAssertEqual(
            window.streak(asOf: try Self.day(2026, 9, 9)), 0,
            """
            The last dictation was on the 7th and the 8th passed without one, so by the 9th the \
            run is broken. The grace covers the day in progress and nothing more — a streak that \
            outlived a whole skipped day would let the gate pass on days of non-use.
            """)
    }

    // MARK: - B10 · onboarding is not use

    /// A day whose only sessions were onboarding demos does not extend a streak.
    ///
    /// The gate is about dictating as the primary text-input method. Running TRY IT during setup
    /// is not that, however well it goes — and it is the one kind of session a user can produce
    /// without having dictated anything they meant to keep.
    func testADayOfOnlyOnboardingSessionsDoesNotExtendAStreak() throws {
        let onboardingDay = try Self.day(2026, 9, 6)
        let window = Self.window([Self.dayOfOnboardingOnly(onboardingDay)])

        XCTAssertEqual(
            window.streak(asOf: onboardingDay), 0,
            """
            A successful TRY IT during setup is not a day of using dictation as the primary \
            text-input method, which is what ROADMAP.md:102's gate asks. Counting it would let \
            the gate's headline figure be produced by the onboarding screen.
            """)
        XCTAssertNotNil(
            window.aggregate(for: onboardingDay),
            """
            The onboarding day is still held — its outcomes are real and an onboarding failure is \
            a real defect. It is excluded from the streak, not discarded from the window.
            """)
    }

    /// An onboarding-only day in the middle of a run breaks it exactly as an absent day does.
    ///
    /// This is the case where the two rules could disagree: the day is *present* in the window,
    /// so a streak that walked over "days held" rather than "days of real work" would count it
    /// and report an unbroken run through a day the user only ran a demo on.
    func testAnOnboardingOnlyDayInTheMiddleOfARunBreaksItLikeAnAbsentDay() throws {
        let window = Self.window([
            Self.dayOfRealWork(try Self.day(2026, 9, 1)),
            Self.dayOfRealWork(try Self.day(2026, 9, 2)),
            Self.dayOfRealWork(try Self.day(2026, 9, 3)),
            Self.dayOfOnboardingOnly(try Self.day(2026, 9, 4)),
            Self.dayOfRealWork(try Self.day(2026, 9, 5)),
            Self.dayOfRealWork(try Self.day(2026, 9, 6)),
        ])

        XCTAssertEqual(
            window.streak(asOf: try Self.day(2026, 9, 6)), 2,
            """
            The 4th holds a session but no real work, so the run ends there and the streak is the \
            two days since. A window that walked the days it holds rather than the days of real \
            work would report six, turning a demo into a day of use.
            """)

        let withTheDayAbsentInstead = Self.window([
            Self.dayOfRealWork(try Self.day(2026, 9, 1)),
            Self.dayOfRealWork(try Self.day(2026, 9, 2)),
            Self.dayOfRealWork(try Self.day(2026, 9, 3)),
            Self.dayOfRealWork(try Self.day(2026, 9, 5)),
            Self.dayOfRealWork(try Self.day(2026, 9, 6)),
        ])
        XCTAssertEqual(
            withTheDayAbsentInstead.streak(asOf: try Self.day(2026, 9, 6)),
            window.streak(asOf: try Self.day(2026, 9, 6)),
            """
            An onboarding-only day and a day nobody opened the app on are the same thing to a \
            streak. Stating it as an equality is what stops the two rules drifting apart later.
            """)
    }

    // MARK: - B11 · retention

    /// The window keeps thirty days; the thirty-first insertion drops the oldest.
    ///
    /// The bound is on the collection, applied when a day goes in. A cap enforced at read time
    /// would let the window grow without limit in memory and would make "the oldest day held" a
    /// function of when someone last asked rather than of what was inserted.
    func testRetentionKeepsThirtyDaysAndEvictsTheOldestFirst() throws {
        var window = UsageWindow()
        // 1 September 2026 through 1 October 2026 — thirty-one consecutive days.
        var inserted: [CalendarDay] = []
        for dayOfMonth in 1...30 {
            inserted.append(try Self.day(2026, 9, dayOfMonth))
        }
        inserted.append(try Self.day(2026, 10, 1))

        for day in inserted {
            window.insert(Self.dayOfRealWork(day))
            XCTAssertLessThanOrEqual(
                window.days.count, UsageWindowConstants.maximumRetainedDays,
                """
                The window never exceeds its bound, at any point between insertions. Eviction \
                happens when a day goes in, not when a reader arrives — otherwise the collection \
                grows unboundedly in memory and the oldest day held depends on who asked when.
                """)
        }

        XCTAssertEqual(
            window.days.count, 30,
            "thirty-one days were inserted into a thirty-day window, so thirty are held")
        XCTAssertNil(
            window.aggregate(for: try Self.day(2026, 9, 1)),
            """
            The oldest day is the one evicted. A window that dropped the newest instead would \
            stop recording use the moment it filled up, and the streak would freeze a month after \
            first launch.
            """)
        XCTAssertEqual(
            window.days.first?.day, try Self.day(2026, 9, 2),
            "after one eviction the oldest day held is the second day inserted")
        XCTAssertEqual(
            window.days.last?.day, try Self.day(2026, 10, 1),
            "the newest day is retained — it is the one the streak is read backwards from")
    }

    /// A day older than every day a full window holds is not admitted.
    ///
    /// Oldest-first eviction says what happens to the oldest day, and a late-arriving day from
    /// before the window's start *is* the oldest. Admitting it by dropping a newer day would let
    /// a stale replay delete the days the streak is actually read from.
    func testADayOlderThanEveryRetainedDayIsNotAdmittedIntoAFullWindow() throws {
        var window = UsageWindow()
        for dayOfMonth in 1...30 {
            window.insert(Self.dayOfRealWork(try Self.day(2026, 9, dayOfMonth)))
        }

        window.insert(Self.dayOfRealWork(try Self.day(2026, 8, 20)))

        XCTAssertNil(
            window.aggregate(for: try Self.day(2026, 8, 20)),
            """
            A day older than everything a full window holds is the oldest day, and the oldest day \
            is the one that goes. Keeping it would mean dropping a newer day instead — letting a \
            late replay of ancient history delete the days the streak is read from.
            """)
        XCTAssertEqual(
            window.days.count, 30,
            "the window is still exactly full, and still holds the same thirty days it did")
        XCTAssertEqual(
            window.days.first?.day, try Self.day(2026, 9, 1),
            "nothing already held was evicted to make room for a day older than all of it")
    }

    /// The thirty-day bound's definition lives in exactly one place.
    ///
    /// The retained window is what every reported figure is computed over, so a second definition
    /// of the bound is a second answer to "how much history is there" — and the day the two
    /// disagree, the number in the UI and the number the store keeps stop being about the same
    /// span. This is ``InjectionStrategyStoreConstants/maximumRememberedApps``'s pinning scan, and
    /// like it the scan pins the *definition*: the bare numeral and the name itself may legitimately
    /// appear elsewhere.
    func testTheRetentionCapLivesOnlyInTheNamedConstant() throws {
        XCTAssertEqual(UsageWindowConstants.maximumRetainedDays, 30)

        let root = try PackageRootLocator.find(from: #filePath)
        let namedFile = "UsageWindow.swift"
        let pinningTest = "UsageWindowTests.swift"
        let allowedSightings: Set<String> = [namedFile, pinningTest]
        let pattern = #"maximumRetainedDays = 30"#
        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let content = try String(contentsOf: file, encoding: .utf8)
                if SwiftSourceScanner.stripComments(from: content).contains(pattern) {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), allowedSightings,
            """
            The retention bound's definition must live in exactly the named Core file and this \
            pinning test, got: \(sightings). A second definition is a second answer to how much \
            history the ledger has, and the figures computed over each would silently diverge.
            """)
        XCTAssertEqual(
            sightings[namedFile], 1,
            "the named file's own definition must exist — the vacuity guard's second direction")
    }

    // MARK: - The empty window

    /// A window with no days at all reports a streak of zero and does not crash.
    ///
    /// This is the state of every install on first launch, and the state the settings tab renders
    /// before a single dictation. Zero is the true answer here — the window is empty because
    /// nothing happened, which is not the same as a number being unavailable.
    func testAnEmptyWindowHasNoStreakAndNoDays() throws {
        let window = UsageWindow()

        XCTAssertEqual(
            window.streak(asOf: try Self.day(2026, 9, 6)), 0,
            """
            Nobody has dictated, so the streak is zero. This is the first-launch state and it must \
            be a plain answer rather than a crash or an empty-collection edge case.
            """)
        XCTAssertEqual(window.days, [], "an empty window holds no days")
        XCTAssertNil(
            window.aggregate(for: try Self.day(2026, 9, 6)),
            "a day nobody dictated on is absent, including today")
    }

    /// A window holding days, none of them near `asOf`, reports zero.
    ///
    /// The run has to *end* at today or yesterday. A month-old streak is over, and reporting it
    /// as current would tell a lapsed user they are on a run they abandoned in August.
    func testAWindowWhoseMostRecentUseIsLongPastReportsNoCurrentStreak() throws {
        let window = Self.window(try (1...5).map { Self.dayOfRealWork(try Self.day(2026, 8, $0)) })

        XCTAssertEqual(
            window.streak(asOf: try Self.day(2026, 9, 6)), 0,
            """
            The last dictation was five weeks ago, so there is no current run. Reporting the old \
            five would tell a lapsed user they are mid-streak and would let the gate read a week \
            of use from a month of silence.
            """)
    }

    // MARK: - B7 boundaries, through the window

    /// A streak spanning the end of a month counts every day across the rollover.
    ///
    /// The window walks backwards in ``CalendarDay/dayNumber``, not in day-of-month, and this is
    /// the test that proves it: a naive `day - 1` comparison gives 31 January and 1 February a
    /// difference of −30 and breaks every user's streak at the end of every month.
    func testAStreakSpanningAMonthBoundaryCountsEveryDay() throws {
        let window = Self.window([
            Self.dayOfRealWork(try Self.day(2026, 1, 30)),
            Self.dayOfRealWork(try Self.day(2026, 1, 31)),
            Self.dayOfRealWork(try Self.day(2026, 2, 1)),
            Self.dayOfRealWork(try Self.day(2026, 2, 2)),
        ])

        XCTAssertEqual(
            window.streak(asOf: try Self.day(2026, 2, 2)), 4,
            """
            30 January to 2 February is four consecutive days. Anything less means the window is \
            comparing days of the month instead of day numbers, and every user's streak would \
            reset on the first of every month for reasons they could never see.
            """)
    }

    /// A streak spanning the end of a year counts every day across the rollover.
    ///
    /// The same failure one level up: the year changes and the month resets too, so an
    /// arithmetic that survived the month boundary can still break here.
    func testAStreakSpanningAYearBoundaryCountsEveryDay() throws {
        let window = Self.window([
            Self.dayOfRealWork(try Self.day(2026, 12, 30)),
            Self.dayOfRealWork(try Self.day(2026, 12, 31)),
            Self.dayOfRealWork(try Self.day(2027, 1, 1)),
            Self.dayOfRealWork(try Self.day(2027, 1, 2)),
        ])

        XCTAssertEqual(
            window.streak(asOf: try Self.day(2027, 1, 2)), 4,
            """
            30 December to 2 January is four consecutive days. A streak that reset at midnight on \
            New Year's Eve would take the longest runs the product ever produces and delete them \
            on the one day a user is most likely to look.
            """)
    }

    // MARK: - A day of use is a day a transcript existed

    /// A day whose only real-work session was a stray hotkey press does not extend a streak.
    ///
    /// An ``SessionOutcomeClass/emptySkip`` is a press that recorded nothing and never reached the
    /// injector. `ROADMAP.md:102` asks whether the founder dictated as their primary text-input
    /// method that day, and a pocket-tap of ⌥Space is not an answer to that question — counting it
    /// would let the gate's headline number be produced by a keyboard, not by a dictation.
    func testADayOfOnlyStrayHotkeyPressesDoesNotExtendAStreak() throws {
        let day = try Self.day(2026, 9, 6)
        let window = Self.window([Self.dayOfRealWork(day, outcomes: [.emptySkip, .emptySkip])])

        XCTAssertEqual(
            window.streak(asOf: day), 0,
            """
            Two presses that recorded nothing are not a day of dictation. The gate asks whether \
            the tool was the primary way text got typed that day, and a stray hotkey press is \
            evidence of a pocket, not of a habit.
            """)
    }

    /// A day of nothing but cancellations does not extend a streak.
    ///
    /// An abort is the user deciding, mid-session, not to dictate after all. Whatever else it is,
    /// it is not the day's dictation — and a streak fed by Escape presses would measure how often
    /// someone changed their mind.
    func testADayOfOnlyCancelledSessionsDoesNotExtendAStreak() throws {
        let day = try Self.day(2026, 9, 6)
        let window = Self.window([Self.dayOfRealWork(day, outcomes: [.aborted, .aborted])])

        XCTAssertEqual(
            window.streak(asOf: day), 0,
            """
            Every session that day was cancelled before it produced anything, so nothing was \
            dictated. A cancellation is a decision not to dictate, and a run built out of them \
            would be a record of intentions rather than of use.
            """)
    }

    /// A day of nothing but transcription failures does not extend a streak.
    ///
    /// This is the case that most tempts a generous reading — the user *tried*. But a
    /// ``SessionOutcomeClass/failed`` session produced no transcript, which means the tool did not
    /// work that day, and a habit gate that counts days the product failed on is measuring the
    /// wrong thing twice: it flatters the streak and hides the outage.
    func testADayOfOnlyTranscriptionFailuresDoesNotExtendAStreak() throws {
        let day = try Self.day(2026, 9, 6)
        let window = Self.window([Self.dayOfRealWork(day, outcomes: [.failed, .failed])])

        XCTAssertEqual(
            window.streak(asOf: day), 0,
            """
            The engine produced nothing all day, so no dictation happened — the user tried and the \
            tool did not work. Counting the attempt would let a day of total failure extend the \
            run that is supposed to be evidence the product is usable daily.
            """)
    }

    /// A day whose transcript was **lost** still extends the streak.
    ///
    /// This is the counterintuitive half of the rule, and the reason the rule is about a
    /// transcript existing rather than about a happy ending. A ``SessionOutcomeClass/lost``
    /// session is one where the user spoke, the engine transcribed, and then nobody ended up with
    /// the text. The dictation *happened*; where the text went is a separate failure, and it is
    /// already carried — loudly, and at exactly zero tolerance (`ROADMAP.md:95`) — by the loss
    /// count. Deducting it from the streak as well would let one defect quietly suppress the
    /// evidence of another metric.
    func testADayWhoseTranscriptWasLostStillExtendsAStreak() throws {
        let day = try Self.day(2026, 9, 6)
        let window = Self.window([Self.dayOfRealWork(day, outcomes: [.lost])])

        XCTAssertEqual(
            window.streak(asOf: day), 1,
            """
            The user dictated and a transcript existed; that it reached nobody is a transcript \
            loss, counted as such and gated at zero on its own. The day still happened, and \
            erasing it from the streak would mean a loss defect silently shrinking the habit \
            figure as well — one failure, reported twice, in two unrelated numbers.
            """)
    }

    /// A day the failsafe held the transcript for the user still extends the streak.
    ///
    /// The failsafe is the floor of the injection ladder, not a failure of the dictation: the user
    /// spoke, the text exists and they can take it. That is a day of use by any reading.
    func testADayWhoseTranscriptTheFailsafeHeldStillExtendsAStreak() throws {
        let day = try Self.day(2026, 9, 6)
        let window = Self.window([Self.dayOfRealWork(day, outcomes: [.failsafeHeld])])

        XCTAssertEqual(
            window.streak(asOf: day), 1,
            """
            The transcript exists and the user has it in the failsafe window. Injection never \
            landed it in the field, which the rung tallies record, but the dictation itself \
            plainly happened and the day counts.
            """)
    }

    /// One real dictation on a day of stray presses is still a day of dictation.
    ///
    /// The rule is "at least one", not "mostly": the noise around a real session does not cancel
    /// it. A user who fumbles the hotkey twice and then dictates a paragraph used the product
    /// that day.
    func testADayMixingStrayPressesWithOneRealDictationExtendsAStreak() throws {
        let day = try Self.day(2026, 9, 6)
        let window = Self.window([
            Self.dayOfRealWork(
                day, outcomes: [.emptySkip, .delivered(rung: .clipboardPaste, verified: true), .emptySkip])
        ])

        XCTAssertEqual(
            window.streak(asOf: day), 1,
            """
            One delivered dictation is one dictation, whatever else happened around it. A rule \
            that let two stray presses cancel a real session would punish fumbling the hotkey by \
            deleting the day it was eventually used on.
            """)
    }

    /// A day of nothing but stray presses breaks a run exactly as an absent day does.
    ///
    /// The day is *present* in the window — its counts are real and the Usage tab shows them — so
    /// a streak that walked the days it holds rather than the days a transcript existed on would
    /// count it and report an unbroken run through a day nobody dictated in. Stated as an equality
    /// against the same window with the day simply missing, so the two rules cannot drift apart.
    func testAStrayPressOnlyDayMidRunBreaksItLikeAnAbsentDay() throws {
        let asOf = try Self.day(2026, 9, 6)
        let window = Self.window([
            Self.dayOfRealWork(try Self.day(2026, 9, 1)),
            Self.dayOfRealWork(try Self.day(2026, 9, 2)),
            Self.dayOfRealWork(try Self.day(2026, 9, 3)),
            Self.dayOfRealWork(try Self.day(2026, 9, 4), outcomes: [.emptySkip]),
            Self.dayOfRealWork(try Self.day(2026, 9, 5)),
            Self.dayOfRealWork(asOf),
        ])

        XCTAssertEqual(
            window.streak(asOf: asOf), 2,
            """
            The 4th holds a session but no transcript, so the run ends there and the streak is the \
            two days since. A window that counted days-held rather than days-a-transcript-existed \
            would report six and turn a pocket-tap into a day of use.
            """)

        let withTheDayAbsentInstead = Self.window([
            Self.dayOfRealWork(try Self.day(2026, 9, 1)),
            Self.dayOfRealWork(try Self.day(2026, 9, 2)),
            Self.dayOfRealWork(try Self.day(2026, 9, 3)),
            Self.dayOfRealWork(try Self.day(2026, 9, 5)),
            Self.dayOfRealWork(asOf),
        ])
        XCTAssertEqual(
            withTheDayAbsentInstead.streak(asOf: asOf), window.streak(asOf: asOf),
            """
            A day of stray presses and a day nobody opened the app on are the same thing to a \
            streak. Stating it as an equality is what stops the two rules drifting apart later.
            """)
    }
}
