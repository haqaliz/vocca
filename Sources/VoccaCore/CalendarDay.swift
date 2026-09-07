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

/// A plain calendar date — year, month and day as integers — with a pure day-number conversion,
/// so "consecutive days" is a subtraction rather than a calendar query.
///
/// `VoccaCore` imports nothing (`CoreBoundaryTests.testVoccaCoreImportsOnlyWhatIsExplicitlyPermitted`),
/// so there is no `Calendar`, no `DateComponents` and no `TimeZone` to borrow this arithmetic
/// from. It is written here, in integers, which is why ``CalendarDayTests`` spends most of its
/// length on the four boundary classes a hand-written calendar gets wrong.
///
/// **This type never answers "what day is it."** There is no clock in this module
/// (`CoreBoundaryTests.testVoccaCoreReadsNoClockOfItsOwn`) and there is deliberately no
/// convenience that resolves "today": a day arrives from its caller already resolved, exactly as
/// ``LatencySpan``'s elapsed arrives already measured. Resolving a wall-clock date into a
/// ``CalendarDay`` — with the time zone and the day-rollover question that comes with it — is the
/// adapter's job at the wiring seam, where it can be seen and configured.
///
/// ## An impossible date is refused, not repaired
///
/// The initialiser is **failable**: month 13, day 32, and 29 February 1900 all return `nil`.
/// The two alternatives were considered and rejected:
///
/// - **Clamping** (month 13 becomes December, 29 February 1900 becomes the 28th) fabricates a
///   date the caller never asked for and hands back a `dayNumber` that looks entirely plausible.
///   That is the failure mode ``LatencySpan/Presence/notPresent`` exists to prevent one level
///   down — a fabricated value is worse than an absent one precisely because nothing downstream
///   can tell it apart from a real one. A streak computed from repaired days is a number about
///   nothing.
/// - **A precondition** turns bad input into a crash. The days that reach this type come from an
///   adapter reading the system clock on behalf of a *usage ledger*; a menu-bar dictation app
///   must not die because its statistics tab was handed a date it did not like.
///
/// `nil` is the third option and the only honest one: invalidity is representable, and the
/// compiler makes every caller face it at the point of construction, once, rather than
/// discovering it as a wrong number in a report much later.
///
/// The accepted year range (``representableYears``) is deliberately narrow. Proleptic Gregorian
/// is a fiction before 1582 in any case, four digits covers every date a usage window can ever
/// hold, and the bound keeps the era arithmetic below far away from the edges of `Int`, where a
/// nonsense year would trap on overflow instead of returning `nil` like every other nonsense
/// input.
///
/// Equality and hashing are over the three components, which is the same relation as equality of
/// ``dayNumber``: the civil-to-days conversion is injective over the valid dates this type can
/// hold, so there is no second spelling of the same day to disagree about.
public struct CalendarDay: Sendable, Hashable, Comparable {

    /// The years this type will accept. See the type's doc comment: wide enough for any real
    /// date, narrow enough that ``dayNumber``'s arithmetic cannot overflow.
    public static let representableYears: ClosedRange<Int> = -9999...9999

    /// The proleptic Gregorian year.
    public let year: Int
    /// The month, 1 (January) through 12 (December).
    public let month: Int
    /// The day of the month, 1 through the length of that month in that year.
    public let day: Int

    /// Builds a day, or returns `nil` if the three numbers do not name a real date.
    ///
    /// - Returns: `nil` when `year` is outside ``representableYears``, when `month` is outside
    ///   `1...12`, or when `day` is outside `1...` the length of that month in that year —
    ///   including 29 February in a non-leap year. Never a repaired date.
    public init?(year: Int, month: Int, day: Int) {
        guard CalendarDay.representableYears.contains(year), (1...12).contains(month) else {
            return nil
        }
        guard (1...CalendarDay.daysInMonth(ofYear: year, month: month)).contains(day) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Days since 1970-01-01, which is day 0; earlier days are negative.
    ///
    /// This is Howard Hinnant's `days_from_civil` — the canonical integer civil-to-days form,
    /// transcribed rather than invented, because the era/year-of-era/day-of-year decomposition is
    /// what gets the leap-century rule right without a special case. March is treated as the
    /// first month of the year, which is what puts the leap day at the *end* of the year and
    /// removes it from the middle of the arithmetic.
    ///
    /// The epoch itself carries no meaning here: every consumer subtracts two day numbers, so it
    /// cancels. It is 1970 only because that is the algorithm's published shift.
    public var dayNumber: Int {
        let shiftedYear = year - (month <= 2 ? 1 : 0)
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400                                    // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1   // [0, 365]
        let dayOfEra =
            yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear          // [0, 146096]
        return era * 146097 + dayOfEra - 719468
    }

    /// Calendar order, which is ``dayNumber`` order — the simplest correct thing, and the same
    /// relation retention evicts in and a streak walks backwards through.
    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        lhs.dayNumber < rhs.dayNumber
    }

    /// Whether the proleptic Gregorian calendar gives this year a 29 February: divisible by four,
    /// except centuries, except every fourth century. All three clauses are load-bearing — 1900
    /// is not a leap year and 2000 is.
    private static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// The length of a month in a given year. `month` is assumed to be `1...12`; the only caller
    /// is the initialiser, which has already checked it.
    private static func daysInMonth(ofYear year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}
