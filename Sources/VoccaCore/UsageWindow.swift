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

/// The one named table of the usage ledger's bounded-history claim: this many days are retained,
/// and the oldest is evicted when a further day arrives.
///
/// Its own place, following ``InjectionStrategyStoreConstants/maximumRememberedApps`` — which
/// cites ``LatencyLedger/maximumRetainedRecords`` as *its* precedent — so the bound is stated once
/// and pinned by a single-source scan
/// (`UsageWindowTests.testTheRetentionCapLivesOnlyInTheNamedConstant`).
///
/// Thirty is deliberately larger than the seven the P0 gate reads (`ROADMAP.md:102`): a window
/// exactly the size of the question can answer it only for a user who has never lapsed, and it
/// leaves no history to see a broken run against. It is also the span the store will persist, so
/// changing it changes how much history an existing install keeps — a decision to take once,
/// visibly, rather than by editing a numeral.
public enum UsageWindowConstants {
    /// The cap on retained days.
    public static let maximumRetainedDays = 30
}

/// The recent days of use, in calendar order and bounded — the collection a streak is read from.
///
/// A window is a set of ``DayAggregate``s keyed by their ``CalendarDay``, held in calendar order.
/// Two rules are the whole of its behaviour, and both exist because the alternative quietly
/// flatters the number the P0 gate reads:
///
/// ## A day with no sessions is absent, not a zero row
///
/// Absence is exactly the signal that breaks a streak. A window that materialised empty days —
/// filling in the gaps between the days it was given — would repair every lapse it was shown and
/// report an unbroken run across a fortnight nobody dictated in. So a day exists here only
/// because a session was folded into it, and ``aggregate(for:)`` returns `nil` for every other
/// day. This is ``LatencySpan/Presence/notPresent``'s no-fabrication rule at the level of a whole
/// day: an absent measurement is absent.
///
/// ## The day is the key; arrival order is not evidence
///
/// Days do not arrive in order — a store replays a file, an aggregate is recomputed and comes
/// round again — so ``insert(_:)`` is an upsert on ``DayAggregate/day``, and the newest arrival
/// for a day replaces the row held for it. A duplicate row would double a day's counts and, in a
/// full window, could evict a genuinely older day to make room for a copy of one already held.
/// Everything read off the window is a fact about the *set* of days present.
///
/// ## No clock
///
/// The window never asks what day it is; there is no clock in this module
/// (`CoreBoundaryTests.testVoccaCoreReadsNoClockOfItsOwn`). ``streak(asOf:)`` takes today as an
/// argument, exactly as ``StrategyMemory`` takes `now` — the caller that resolved a wall-clock
/// instant into a ``CalendarDay``, with the time zone and day-rollover question that comes with
/// it, is the only code that could have known, and it decides once, above this type.
public struct UsageWindow: Sendable, Equatable {

    /// The days held, ascending by ``CalendarDay``. The invariant is maintained by
    /// ``insert(_:)``, which is the only thing that writes it: at most one entry per day, sorted,
    /// never longer than ``UsageWindowConstants/maximumRetainedDays``.
    ///
    /// Sorted storage rather than a dictionary because both things done with this collection walk
    /// it in calendar order — eviction takes from the front, a streak walks back from the end —
    /// and thirty entries make the linear upsert beneath any measurable cost.
    private var orderedDays: [DayAggregate] = []

    /// An empty window: no days, and therefore no streak. The first-launch state.
    public init() {}

    /// The days held, oldest first. Calendar order regardless of the order they arrived in.
    public var days: [DayAggregate] { orderedDays }

    /// The day's aggregate, or `nil` if no session was ever folded into that day.
    ///
    /// `nil` means *nobody dictated*, and is the honest answer rather than an aggregate of zeros:
    /// a caller that wants to render a blank row can make one, but only this type knows the
    /// difference between a day of no use and a day of no data.
    public func aggregate(for day: CalendarDay) -> DayAggregate? {
        orderedDays.first { $0.day == day }
    }

    /// Files `aggregate` under its day, replacing whatever was held for that day, and evicts the
    /// oldest day if the window is now over its bound.
    ///
    /// Eviction happens **here**, when a day goes in — not when a reader arrives. A bound applied
    /// at read time would let the collection grow without limit in memory and would make "the
    /// oldest day held" a function of when someone last asked.
    ///
    /// A day older than every day a full window holds is therefore the day evicted, immediately
    /// and by the same rule: it *is* the oldest. Admitting it by dropping a newer day instead
    /// would let a stale replay of old history delete the recent days the streak is read from.
    public mutating func insert(_ aggregate: DayAggregate) {
        if let held = orderedDays.firstIndex(where: { $0.day == aggregate.day }) {
            orderedDays[held] = aggregate
            return
        }
        let position = orderedDays.firstIndex { aggregate.day < $0.day } ?? orderedDays.endIndex
        orderedDays.insert(aggregate, at: position)
        if orderedDays.count > UsageWindowConstants.maximumRetainedDays {
            orderedDays.removeFirst(orderedDays.count - UsageWindowConstants.maximumRetainedDays)
        }
    }

    /// The current run of consecutive days of real dictation, as of `today`.
    ///
    /// The run is the consecutive days each holding at least one ``SessionKind/dictation``
    /// session, ending at `today` **or** at the day before it. If neither day holds real work the
    /// answer is 0.
    ///
    /// ## The one-day grace is deliberate
    ///
    /// At nine in the morning on day eight, the user has not dictated yet today. Reporting 0 there
    /// would be wrong — `ROADMAP.md:102`'s gate counts days *completed*, and seven of them were —
    /// and it would be discouraging at exactly the point a new habit is most fragile. So a run
    /// that ends yesterday still reads in full today. The grace is one day wide and no wider: once
    /// a whole day has passed without a dictation, the run is over and the answer is 0, because a
    /// streak that survived a skipped day would be measuring something other than daily use.
    ///
    /// ## Only real work extends a run
    ///
    /// A day whose only sessions were onboarding's TRY IT is *present* in the window — those
    /// outcomes are real, and an onboarding failure is a real defect — but it does not extend the
    /// run. The gate asks about dictation as the primary text-input method, which a setup demo is
    /// not, however well it goes. Such a day therefore breaks a run exactly as an absent day does.
    ///
    /// ## A day counts when a transcript existed
    ///
    /// Not every real-work session is evidence that a dictation happened. The gate asks whether
    /// the founder dictated as their *primary text-input method* that day, so the run counts a day
    /// only if it holds a session whose outcome means a transcript existed —
    /// ``DayAggregate/OutcomeCounts/transcriptsProduced``, which names the set once rather than
    /// letting this method open-code it. A stray hotkey press is not a dictation, a cancellation
    /// is not a dictation, and a day of nothing but transcription failures is a day the tool did
    /// not work; none of the three is evidence of the habit being measured.
    ///
    /// ``SessionOutcomeClass/lost`` is on the counting side, which looks generous and is not: the
    /// transcript existed, so the dictation happened. That it went nowhere is a separate failure
    /// which the loss count already carries at zero tolerance (`ROADMAP.md:95`), and taking the
    /// day off the streak as well would report one defect twice, in two unrelated numbers.
    ///
    /// Days are compared by ``CalendarDay/dayNumber``, so "consecutive" is a subtraction and the
    /// run walks across the end of a month and the end of a year without noticing either.
    public func streak(asOf today: CalendarDay) -> Int {
        var realWorkDayNumbers: Set<Int> = []
        for aggregate in orderedDays where aggregate.realWork.transcriptsProduced > 0 {
            realWorkDayNumbers.insert(aggregate.day.dayNumber)
        }

        let mostRecent = today.dayNumber
        var cursor: Int
        if realWorkDayNumbers.contains(mostRecent) {
            cursor = mostRecent
        } else if realWorkDayNumbers.contains(mostRecent - 1) {
            cursor = mostRecent - 1
        } else {
            return 0
        }

        var run = 0
        while realWorkDayNumbers.contains(cursor) {
            run += 1
            cursor -= 1
        }
        return run
    }
}
