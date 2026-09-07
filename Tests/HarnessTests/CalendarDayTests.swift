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

/// ``CalendarDay``: a date as three integers, and the day-number arithmetic that makes
/// "consecutive days" a subtraction.
///
/// The `usage-vocabulary` spec's B7 row is the whole reason this suite exists. `VoccaCore`
/// imports nothing — no `Foundation`, so no `Calendar`, no `DateComponents` — which means the
/// proleptic-Gregorian conversion is *written here*, and hand-written calendar arithmetic is
/// famous for being right for years and then wrong on one February. The four boundary classes
/// below are the ones an ad-hoc algorithm gets wrong: a month end, a non-leap February, a leap
/// day, and a year end — plus the leap **century** rule, where 2000 has a 29 February and 1900
/// does not, which is the single case that separates the standard algorithm from a plausible
/// invention.
///
/// Nothing in this suite asks what day it is. A `CalendarDay` is always supplied by its caller,
/// exactly as ``LatencySpan``'s elapsed arrives already measured — the streak is arithmetic over
/// days handed in, never a clock read below the seam.
final class CalendarDayTests: XCTestCase {

    // MARK: - Consecutive days

    /// The last day of a month and the first of the next are one day apart.
    ///
    /// A streak is `dayNumber` subtraction, so if the month rollover cost anything other than 1
    /// the streak would break silently at the end of every month — the user dictates every day
    /// and the ledger tells them they did not.
    func testConsecutiveDaysAcrossAMonthBoundaryDifferByOne() throws {
        let januaryEnd = try XCTUnwrap(CalendarDay(year: 2026, month: 1, day: 31))
        let februaryStart = try XCTUnwrap(CalendarDay(year: 2026, month: 2, day: 1))
        XCTAssertEqual(
            februaryStart.dayNumber - januaryEnd.dayNumber, 1,
            """
            31 January and 1 February 2026 are consecutive days, so their day numbers must \
            differ by exactly 1. Any other answer breaks a real user's streak at the end of \
            every month, on arithmetic they cannot see or argue with.
            """)
    }

    /// February 2026 has 28 days: 28 February and 1 March are consecutive.
    ///
    /// This is the case a "30 days in every month" shortcut gets wrong, and the case a
    /// leap-year rule applied to the wrong years gets wrong in the other direction. Most years
    /// are this year, so an error here is the common case, not the rare one.
    func testTheDayAfterTwentyEighthFebruaryInANonLeapYearIsFirstMarch() throws {
        let februaryEnd = try XCTUnwrap(CalendarDay(year: 2026, month: 2, day: 28))
        let marchStart = try XCTUnwrap(CalendarDay(year: 2026, month: 3, day: 1))
        XCTAssertEqual(
            marchStart.dayNumber - februaryEnd.dayNumber, 1,
            """
            2026 is not a leap year, so 28 February is the last day of the month and 1 March is \
            the next day. A gap of 2 here means the ledger believes in a 29 February that never \
            happened and breaks the streak of every user who dictates through the end of \
            February.
            """)
    }

    /// 2028 is a leap year: 28 February, 29 February and 1 March are three consecutive days.
    ///
    /// The leap day is a real day of use. If it is not representable, a user's streak either
    /// breaks on it or silently skips it — both are wrong answers to "how many consecutive days",
    /// and both are invisible until the day arrives.
    func testALeapDayIsARealDayBetweenFebruaryAndMarch() throws {
        let februaryTwentyEighth = try XCTUnwrap(CalendarDay(year: 2028, month: 2, day: 28))
        let leapDay = try XCTUnwrap(CalendarDay(year: 2028, month: 2, day: 29))
        let marchStart = try XCTUnwrap(CalendarDay(year: 2028, month: 3, day: 1))
        XCTAssertEqual(
            leapDay.dayNumber - februaryTwentyEighth.dayNumber, 1,
            "29 February 2028 exists and is the day after the 28th; a ledger that cannot count to it cannot count a streak through it.")
        XCTAssertEqual(
            marchStart.dayNumber - leapDay.dayNumber, 1,
            "1 March 2028 is the day after the leap day, not two days after it — otherwise every streak spanning a leap year is reported one day short.")
    }

    /// 31 December and the following 1 January are one day apart.
    ///
    /// The year rollover is where an algorithm that treats a year as a fresh count restarts from
    /// zero: the difference goes hugely negative and the streak resets on New Year's Day for
    /// every user at once.
    func testConsecutiveDaysAcrossAYearBoundaryDifferByOne() throws {
        let yearEnd = try XCTUnwrap(CalendarDay(year: 2026, month: 12, day: 31))
        let yearStart = try XCTUnwrap(CalendarDay(year: 2027, month: 1, day: 1))
        XCTAssertEqual(
            yearStart.dayNumber - yearEnd.dayNumber, 1,
            """
            31 December 2026 and 1 January 2027 are consecutive days. A day number that restarts \
            at the year boundary resets every streak in the product on the same night.
            """)
    }

    /// The leap **century** rule: 2000 has a 29 February, 1900 does not.
    ///
    /// This is the one test an invented algorithm fails. "Every fourth year" gives 1900 a leap
    /// day; "every fourth year except centuries" takes 2000's away. Only the full proleptic
    /// Gregorian rule — divisible by 4, except centuries, except every fourth century — gets
    /// both right, which is exactly why the standard integer form is used here instead of one
    /// written from memory.
    func testTwoThousandHasALeapDayAndNineteenHundredDoesNot() throws {
        let millenniumFebruaryTwentyEighth = try XCTUnwrap(CalendarDay(year: 2000, month: 2, day: 28))
        let millenniumLeapDay = try XCTUnwrap(CalendarDay(year: 2000, month: 2, day: 29))
        XCTAssertEqual(
            millenniumLeapDay.dayNumber - millenniumFebruaryTwentyEighth.dayNumber, 1,
            "2000 is divisible by 400, so it is a leap year and 29 February 2000 is a real date — the case a \"no leap day in a century\" rule gets wrong.")

        XCTAssertNil(
            CalendarDay(year: 1900, month: 2, day: 29),
            "1900 is divisible by 100 but not 400, so it has no 29 February. Accepting one would mint a day that never existed.")
        let nineteenHundredFebruaryEnd = try XCTUnwrap(CalendarDay(year: 1900, month: 2, day: 28))
        let nineteenHundredMarchStart = try XCTUnwrap(CalendarDay(year: 1900, month: 3, day: 1))
        XCTAssertEqual(
            nineteenHundredMarchStart.dayNumber - nineteenHundredFebruaryEnd.dayNumber, 1,
            "1900 has no leap day, so 28 February 1900 and 1 March 1900 are consecutive — the case an \"every fourth year\" rule gets wrong.")
    }

    // MARK: - Ordering

    /// `Comparable` puts days in calendar order, across the year, the month and the day.
    ///
    /// Retention evicts the *oldest* day and a streak reads the *most recent* one, so both are
    /// wrong the moment ordering is anything other than calendar order — a lexicographic or
    /// field-major comparison would sort 2027-01-01 before 2026-12-31 as easily as after it.
    func testComparableOrdersByCalendarOrderAcrossYearMonthAndDay() throws {
        let earliest = try XCTUnwrap(CalendarDay(year: 2026, month: 1, day: 5))
        let laterDay = try XCTUnwrap(CalendarDay(year: 2026, month: 1, day: 6))
        let laterMonth = try XCTUnwrap(CalendarDay(year: 2026, month: 2, day: 1))
        let laterYear = try XCTUnwrap(CalendarDay(year: 2027, month: 1, day: 1))

        XCTAssertLessThan(earliest, laterDay, "5 January precedes 6 January; a day-of-month that does not order is a ledger that cannot say which day was most recent.")
        XCTAssertLessThan(laterDay, laterMonth, "6 January precedes 1 February — the month must outrank the day, or the newest day in the window is picked by its number rather than its date.")
        XCTAssertLessThan(laterMonth, laterYear, "February 2026 precedes January 2027 — the year must outrank the month, or retention evicts next year before last month.")
        XCTAssertEqual(
            [laterYear, laterMonth, earliest, laterDay].sorted(), [earliest, laterDay, laterMonth, laterYear],
            "Sorting a shuffled set of days must produce calendar order: this is the order retention evicts in and the order a streak walks backwards through.")
    }

    // MARK: - Counting days between dates

    /// The difference of two day numbers is the count of days between the dates, including
    /// across a leap year.
    ///
    /// A streak of N days is a claim about a span, not about two adjacent days, so the
    /// arithmetic has to hold over a whole year — 365 for an ordinary year, 366 for a leap one.
    /// An algorithm can get every adjacent pair right and still drift over a year if its leap
    /// handling is off by a day.
    func testDayNumberDifferencesCountTheDaysBetweenTwoDatesAcrossALeapYear() throws {
        let ordinaryYearStart = try XCTUnwrap(CalendarDay(year: 2026, month: 1, day: 1))
        let ordinaryYearEnd = try XCTUnwrap(CalendarDay(year: 2027, month: 1, day: 1))
        XCTAssertEqual(
            ordinaryYearEnd.dayNumber - ordinaryYearStart.dayNumber, 365,
            "2026 is an ordinary year and has 365 days; a span measured in day numbers must agree with the calendar over a whole year, not only over adjacent days.")

        let leapYearStart = try XCTUnwrap(CalendarDay(year: 2028, month: 1, day: 1))
        let leapYearEnd = try XCTUnwrap(CalendarDay(year: 2029, month: 1, day: 1))
        XCTAssertEqual(
            leapYearEnd.dayNumber - leapYearStart.dayNumber, 366,
            "2028 is a leap year and has 366 days. Reporting 365 here is the drift that makes a long streak quietly disagree with the user's own memory of it.")
    }

    // MARK: - Impossible dates

    /// A date that does not exist is refused — `nil` — never clamped into a nearby one that
    /// does.
    ///
    /// This is the decision the type is written around, and it is the same rule as
    /// ``LatencySpan/Presence/notPresent``'s one level down: a repaired value is worse than an
    /// absent one, because a `dayNumber` computed from a clamped 32 January looks exactly as
    /// plausible as a real one and nothing downstream can tell them apart. A streak, a retention
    /// window and an eviction order built on repaired days are numbers about nothing. The
    /// alternative — trapping on a precondition — would kill a menu-bar dictation app over its
    /// statistics tab, so `nil` is the answer: invalid is representable, and the compiler makes
    /// the caller face it once, at construction.
    func testAnImpossibleDateIsRefusedRatherThanRepairedIntoAPlausibleOne() throws {
        XCTAssertNil(CalendarDay(year: 2026, month: 13, day: 1), "there is no thirteenth month; clamping it to December would invent a date the caller never named.")
        XCTAssertNil(CalendarDay(year: 2026, month: 0, day: 1), "months are numbered from 1, so month 0 is not a date — and a zero is exactly what an uninitialised field looks like.")
        XCTAssertNil(CalendarDay(year: 2026, month: 1, day: 32), "January has 31 days; a 32nd would silently become 1 February under any repairing rule.")
        XCTAssertNil(CalendarDay(year: 2026, month: 1, day: 0), "days are numbered from 1, so day 0 is not a date.")
        XCTAssertNil(CalendarDay(year: 2026, month: 4, day: 31), "April has 30 days — the short-month case a fixed 31-day check would let through.")
        XCTAssertNil(CalendarDay(year: 2026, month: 2, day: 30), "no February has 30 days in any year, leap or not.")
        XCTAssertNil(
            CalendarDay(year: CalendarDay.representableYears.upperBound + 1, month: 1, day: 1),
            "a year outside the representable range is refused like any other nonsense input, rather than trapping on overflow deep inside the era arithmetic.")

        // The guard against a vacuous suite: an initialiser that refused everything would pass
        // every assertion above. These are the awkward-but-real dates either side of them.
        XCTAssertNotNil(CalendarDay(year: 2026, month: 12, day: 31), "31 December is a real date; a refusal rule that also rejects the last day of the year has broken the common case to catch the impossible one.")
        XCTAssertNotNil(CalendarDay(year: 2026, month: 4, day: 30), "30 April is the real last day of a thirty-day month and must be accepted.")
        XCTAssertNotNil(CalendarDay(year: 2028, month: 2, day: 29), "29 February 2028 is a real date — refusing every 29 February would be as wrong as accepting every one.")
    }
}
