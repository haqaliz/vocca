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

/// What a provider answers: the day it is now, locally — or `nil` if the instant does not name a
/// day ``CalendarDay`` can hold.
///
/// The optional is not defensive padding. ``CalendarDay/init(year:month:day:)`` is failable by
/// deliberate design ("an impossible date is refused, not repaired", `CalendarDay.swift:30-48`),
/// and a provider that forced it would turn a nonsense clock reading into a crash in a menu-bar
/// app. A fold that has no day skips; nothing downstream is handed a fabricated one.
public typealias CalendarDayProvider = @Sendable () -> CalendarDay?

/// **The usage ledger's calendar seam — the one file in `Sources/` permitted to name `Calendar`,
/// `TimeZone` or `DateComponents`** (the `usageDay` row in `InjectionSeamBoundaryTests`' per-seam
/// Calendar table, the family this file ships with).
///
/// ``CalendarDay`` refuses to answer "what day is it": `VoccaCore` imports nothing and reads no
/// clock (`CoreBoundaryTests.testVoccaCoreReadsNoClockOfItsOwn`), so a day arrives there already
/// resolved, exactly as ``LatencySpan``'s elapsed arrives already measured. Resolving a
/// wall-clock instant into a calendar day — "with the time zone and the day-rollover question
/// that comes with it" (`CalendarDay.swift:26-28`) — is this adapter's whole job, and it is two
/// decisions long.
///
/// ## The day is local, not UTC
///
/// `epochSeconds / 86_400` is the cheap answer and it is wrong for most of the planet most of the
/// time: it posts a New Yorker's evening dictations to tomorrow and a Tokyo morning's to
/// yesterday, every day, not at an edge case. The zone is read from the system —
/// `TimeZone.autoupdatingCurrent` by default, so a user who flies or whose region changes gets
/// the new zone without relaunching — and the day is whatever the wall clock on that user's wall
/// says.
///
/// ## The calendar is Gregorian, fixed, and not the user's
///
/// ``CalendarDay`` is a *proleptic Gregorian* year/month/day with its own integer arithmetic, and
/// the on-disk format spells a day `YYYY-MM-DD` (`PersistentUsageStore`). `Calendar.current`
/// follows the user's locale, so on a Buddhist or Japanese calendar it would answer year 2569 or
/// 8 — a number the file's format cannot mean and ``CalendarDay/representableYears`` might not
/// even accept. The *zone* is the user's; the *calendar* is the one the format is written in.
///
/// ## The clock is read per call
///
/// `now` is a closure, not a stored instant: an app left running past midnight starts a new day
/// on its next fold rather than posting to yesterday until it is quit (PRD E3). Injecting it is
/// also what lets ``CalendarDayProviderTests`` pin a DST transition against hardcoded epoch
/// seconds instead of against the machine it happens to run on.
public struct SystemCalendarDayProvider: Sendable {
    /// The zone the day is read in. `TimeZone.autoupdatingCurrent` tracks the system's, so this
    /// value stays correct across a change rather than freezing the zone the app launched in.
    private let timeZone: TimeZone

    /// The wall clock, read once per ``today()``. The only clock read in this module.
    private let now: @Sendable () -> Date

    public init(
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.timeZone = timeZone
        self.now = now
    }

    /// The day it is now, in this provider's zone — a fresh clock read every time.
    public func today() -> CalendarDay? {
        SystemCalendarDayProvider.day(at: now(), in: timeZone)
    }

    /// This provider as a ``CalendarDayProvider`` closure, for the wiring to hold.
    public var provider: CalendarDayProvider {
        { today() }
    }

    /// The pure resolution, exposed so the whole question — instant, zone, day — can be driven
    /// from a table of hardcoded epoch seconds. Everything above is binding; this is deciding.
    ///
    /// - Returns: `nil` only when the instant does not name a day ``CalendarDay`` accepts — a
    ///   year outside ``CalendarDay/representableYears``, or components the calendar could not
    ///   produce at all. Never a repaired date.
    public static func day(at instant: Date, in timeZone: TimeZone) -> CalendarDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return nil
        }
        return CalendarDay(year: year, month: month, day: day)
    }
}
