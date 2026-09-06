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
import VoccaUsage
import XCTest

/// The adapter that answers "what day is it, here" — `SystemCalendarDayProvider`
/// (`usage-wiring/spec.md` §2).
///
/// `CalendarDay` refuses to answer this question on purpose: `VoccaCore` imports nothing and
/// reads no clock (`CoreBoundaryTests.testVoccaCoreReadsNoClockOfItsOwn`), so resolving a
/// wall-clock instant into a calendar day — "with the time zone and the day-rollover question
/// that comes with it" (`CalendarDay.swift:26-28`) — is the adapter's job, at the seam where it
/// can be seen and configured. This file is where those two questions get answered.
///
/// **Every instant here is a hardcoded epoch second and every zone is named explicitly.** A test
/// that reads `TimeZone.current` passes in one time zone and fails in another, which is not a
/// test; the only assertion below that touches the machine's real clock or zone is
/// ``testTheShippedDefaultAnswersARealDay``, and it asserts a bound wide enough to hold every
/// zone on Earth.
final class CalendarDayProviderTests: XCTestCase {

    // MARK: - Resolution

    /// The base case: an instant, a zone, the day it is there. UTC first, where the local day and
    /// the UTC day agree — the case every wrong implementation also gets right.
    func testAFixedInstantInAFixedZoneResolvesToItsLocalCalendarDay() throws {
        let noonUTC = Date(timeIntervalSince1970: 1_788_782_400)  // 2026-09-07T12:00:00Z

        XCTAssertEqual(
            SystemCalendarDayProvider.day(at: noonUTC, in: try zone("UTC")),
            CalendarDay(year: 2026, month: 9, day: 7))
    }

    /// **The whole reason the provider is local rather than `epochSeconds / 86400`.**
    ///
    /// The same three instants resolve to a *different calendar day* than UTC would give, in both
    /// directions: late evening in a UTC-negative zone is still yesterday, early morning in a
    /// UTC-positive one is already tomorrow, and a zone with a 45-minute offset is neither.
    /// A day counted in UTC would post a New Yorker's evening dictations to tomorrow and a
    /// Tokyo morning's to yesterday — every day of the year, not at an edge case.
    func testTheLocalDayIsNotTheUTCDay() throws {
        // 2026-09-07T03:30:00Z — 23:30 on the 6th in New York (UTC-4 in September).
        let lateEvening = Date(timeIntervalSince1970: 1_788_751_800)
        XCTAssertEqual(
            SystemCalendarDayProvider.day(at: lateEvening, in: try zone("America/New_York")),
            CalendarDay(year: 2026, month: 9, day: 6),
            "23:30 local is still the 6th, however far into the 7th UTC has got")
        XCTAssertEqual(
            SystemCalendarDayProvider.day(at: lateEvening, in: try zone("UTC")),
            CalendarDay(year: 2026, month: 9, day: 7),
            "the control: UTC really does say the 7th for that instant, so the difference is real")

        // 2026-09-07T22:30:00Z — 07:30 on the 8th in Tokyo (UTC+9).
        let earlyMorning = Date(timeIntervalSince1970: 1_788_820_200)
        XCTAssertEqual(
            SystemCalendarDayProvider.day(at: earlyMorning, in: try zone("Asia/Tokyo")),
            CalendarDay(year: 2026, month: 9, day: 8),
            "07:30 local is already the 8th, whatever UTC still says")

        // 2026-09-07T18:20:00Z — 00:05 on the 8th in Kathmandu (UTC+5:45).
        let fractionalOffset = Date(timeIntervalSince1970: 1_788_805_200)
        XCTAssertEqual(
            SystemCalendarDayProvider.day(at: fractionalOffset, in: try zone("Asia/Kathmandu")),
            CalendarDay(year: 2026, month: 9, day: 8),
            """
            a 45-minute offset is a real zone with real users. An implementation that divides by \
            whole hours gets this one wrong and nothing else.
            """)
    }

    /// The same instant, two zones, two different days — so this suite cannot be passed by an
    /// implementation that ignores the zone it was handed and reads the machine's.
    func testTheZoneHandedInIsTheZoneUsed() throws {
        let instant = Date(timeIntervalSince1970: 1_788_820_200)  // 2026-09-07T22:30:00Z

        XCTAssertEqual(
            SystemCalendarDayProvider.day(at: instant, in: try zone("Asia/Tokyo")),
            CalendarDay(year: 2026, month: 9, day: 8))
        XCTAssertEqual(
            SystemCalendarDayProvider.day(at: instant, in: try zone("America/New_York")),
            CalendarDay(year: 2026, month: 9, day: 7),
            """
            one instant, two zones, two days. If these two ever agree, the zone argument is being \
            ignored and the whole seam is decorative.
            """)
    }

    /// **A DST transition day is still one calendar day**, in both directions.
    ///
    /// The spring-forward day is 23 hours long and the fall-back day is 25, so any arithmetic
    /// that assumes 86 400 seconds per day drifts across them. Both transitions are checked from
    /// the instants either side of the jump, plus the last minute of the day *before* the
    /// spring-forward — the boundary a 23-hour day is most likely to be pushed over.
    func testADSTTransitionDayStillYieldsItsOwnCalendarDay() throws {
        let newYork = try zone("America/New_York")

        // Spring forward, 2026-03-08: 02:00 EST becomes 03:00 EDT, and the day is 23 hours long.
        XCTAssertEqual(
            SystemCalendarDayProvider.day(  // 2026-03-08T04:59:00Z — 23:59 on the 7th, EST
                at: Date(timeIntervalSince1970: 1_772_945_940), in: newYork),
            CalendarDay(year: 2026, month: 3, day: 7),
            "the last minute of the 23-hour day's eve belongs to the 7th")
        XCTAssertEqual(
            SystemCalendarDayProvider.day(  // 2026-03-08T06:59:00Z — 01:59 on the 8th, EST
                at: Date(timeIntervalSince1970: 1_772_953_140), in: newYork),
            CalendarDay(year: 2026, month: 3, day: 8),
            "the minute before the clocks jump is the 8th")
        XCTAssertEqual(
            SystemCalendarDayProvider.day(  // 2026-03-08T07:00:00Z — 03:00 on the 8th, EDT
                at: Date(timeIntervalSince1970: 1_772_953_200), in: newYork),
            CalendarDay(year: 2026, month: 3, day: 8),
            "and so is the minute after — an hour vanished, the day did not")

        // Fall back, 2026-11-01: 02:00 EDT becomes 01:00 EST, so 01:30 local happens twice.
        // Both occurrences are the 1st; the day is 25 hours long and still one day.
        XCTAssertEqual(
            SystemCalendarDayProvider.day(  // 2026-11-01T05:00:00Z — 01:00, EDT (first pass)
                at: Date(timeIntervalSince1970: 1_793_509_200), in: newYork),
            CalendarDay(year: 2026, month: 11, day: 1))
        XCTAssertEqual(
            SystemCalendarDayProvider.day(  // 2026-11-01T06:00:00Z — 01:00, EST (second pass)
                at: Date(timeIntervalSince1970: 1_793_512_800), in: newYork),
            CalendarDay(year: 2026, month: 11, day: 1),
            """
            the ambiguous hour is not a second day. A dictation at 01:30 twice over must land on \
            the 1st both times — an hour is repeated, a day is not.
            """)
    }

    /// The two calendar boundaries a hand-rolled conversion gets wrong: a year end crossed by the
    /// offset, and a leap day. Both are read through the zone, which is what puts them at the
    /// boundary in the first place.
    func testYearEndAndLeapDayAreResolvedThroughTheZone() throws {
        let newYork = try zone("America/New_York")

        XCTAssertEqual(
            SystemCalendarDayProvider.day(  // 2027-01-01T00:30:00Z — 19:30 on 2026-12-31, EST
                at: Date(timeIntervalSince1970: 1_798_763_400), in: newYork),
            CalendarDay(year: 2026, month: 12, day: 31),
            "New Year in UTC is still the old year — and the old *day* — in New York")

        XCTAssertEqual(
            SystemCalendarDayProvider.day(  // 2028-03-01T04:30:00Z — 23:30 on 2028-02-29, EST
                at: Date(timeIntervalSince1970: 1_835_497_800), in: newYork),
            CalendarDay(year: 2028, month: 2, day: 29),
            "29 February is a real local day, and CalendarDay accepts it only in a leap year")
    }

    // MARK: - Per call, never memoised (PRD E3)

    /// **The clock is read on every call**, so an app left running past midnight starts a new day
    /// without a restart (PRD E3) — the reason the day is resolved per fold rather than once at
    /// launch.
    ///
    /// The instants are two minutes apart across midnight in Berlin; a provider that cached its
    /// first answer would return the 7th twice, and every dictation after midnight would be
    /// posted to yesterday until the app was quit.
    func testTheClockIsReadOnEveryCallSoMidnightRollsOver() throws {
        let instants = InstantQueue([
            Date(timeIntervalSince1970: 1_788_818_340),  // 2026-09-07T21:59:00Z — 23:59 Berlin
            Date(timeIntervalSince1970: 1_788_818_460),  // 2026-09-07T22:01:00Z — 00:01 Berlin
        ])
        let provider = SystemCalendarDayProvider(
            timeZone: try zone("Europe/Berlin"), now: { instants.next() })

        XCTAssertEqual(provider.today(), CalendarDay(year: 2026, month: 9, day: 7))
        XCTAssertEqual(
            provider.today(), CalendarDay(year: 2026, month: 9, day: 8),
            """
            the second call must see the second instant. A memoised provider returns the 7th here \
            and posts every dictation after midnight to yesterday until the app is quit.
            """)
        XCTAssertEqual(instants.taken, 2, "one clock read per call — no more, no fewer")
    }

    /// The ``CalendarDayProvider`` closure the wiring holds is the provider, not a second
    /// resolution beside it: it answers what `today()` answers, and it reads the clock per call
    /// exactly as `today()` does.
    func testTheClosureFormAnswersWhatTheProviderAnswers() throws {
        let instants = InstantQueue([
            Date(timeIntervalSince1970: 1_788_818_340),  // 2026-09-07T21:59:00Z — 23:59 Berlin
            Date(timeIntervalSince1970: 1_788_818_460),  // 2026-09-07T22:01:00Z — 00:01 Berlin
        ])
        let provider = SystemCalendarDayProvider(
            timeZone: try zone("Europe/Berlin"), now: { instants.next() })
        let closure: CalendarDayProvider = provider.provider

        XCTAssertEqual(closure(), CalendarDay(year: 2026, month: 9, day: 7))
        XCTAssertEqual(
            closure(), CalendarDay(year: 2026, month: 9, day: 8),
            "the closure reads the clock per call too — it is the provider, not a snapshot of it")
        XCTAssertEqual(instants.taken, 2, "one clock read per call through the closure as well")
    }

    // MARK: - The shipped default

    /// The zero-argument provider — the one `AppBootstrap` will compose — answers a real day off
    /// the real clock in the real zone.
    ///
    /// The only assertion in this file that touches the machine, and deliberately loose: the day
    /// must be within one of the UTC day, which every zone on Earth satisfies (the offsets run
    /// from UTC-12 to UTC+14) and which no broken conversion does.
    func testTheShippedDefaultAnswersARealDay() throws {
        let today = try XCTUnwrap(
            SystemCalendarDayProvider().today(),
            "the shipped provider must answer a day; nil means today is unrepresentable")
        let utcDay = try XCTUnwrap(
            SystemCalendarDayProvider.day(at: Date(), in: zone("UTC")))

        XCTAssertLessThanOrEqual(
            abs(today.dayNumber - utcDay.dayNumber), 1,
            """
            the local day is \(today.year)-\(today.month)-\(today.day) and the UTC day is \
            \(utcDay.year)-\(utcDay.month)-\(utcDay.day). Every zone on Earth is within 14 hours \
            of UTC, so these can differ by at most one day.
            """)
    }

    // MARK: - Helpers

    /// A named zone, or a failed test — never `TimeZone.current` as a fallback, which would make
    /// a typo'd identifier silently machine-dependent.
    private func zone(_ identifier: String) throws -> TimeZone {
        try XCTUnwrap(TimeZone(identifier: identifier), "unknown time zone \(identifier)")
    }
}

/// A hand-moved clock: the instants a provider will be handed, in order, and a count of how many
/// it actually took — the `TestClock` shape (`LatencyLedgerTests`), for a wall clock.
///
/// `@unchecked Sendable` over a lock because the `now` closure is `@Sendable`.
private final class InstantQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var instants: [Date]
    private var index = 0

    init(_ instants: [Date]) {
        self.instants = instants
    }

    /// The next instant, or the last one repeated — a provider that reads the clock more often
    /// than the test expects is caught by ``taken``, not by a crash.
    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let instant = instants[min(index, instants.count - 1)]
        index += 1
        return instant
    }

    /// How many reads happened.
    var taken: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}
