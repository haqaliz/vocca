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

/// The ledger as the Usage tab was handed it: the days the window holds, and the streak read off
/// them.
///
/// `streak` travels in the snapshot rather than being computed here, for the reason
/// ``AppStrategyEntry/isAllowlisted`` does: the answer needs something this module may not have.
/// A streak is a fact about **today** — ``UsageWindow/streak(asOf:)`` takes today as an argument
/// precisely because `VoccaCore` has no clock — and resolving a wall-clock instant into a
/// ``CalendarDay``, with the time zone and the day-rollover question that comes with it, is the
/// adapter's job at the wiring seam, where it can be seen and configured. The wiring knows the
/// window and the day, and answers once, at read time — which is also what makes the whole tab
/// testable with no store and no clock at all.
///
/// The days themselves are ``DayAggregate``s, unflattened: they are `Sendable` values that cross
/// no actor boundary by being read, and re-deriving their counts into a second shape here would
/// give the tab a private opinion about what a delivery is.
public struct UsageSnapshot: Sendable, Equatable {
    /// The days the window holds, in whatever order it holds them.
    public var days: [DayAggregate]
    /// The run of consecutive days ending today or yesterday, answered where today is known.
    public var streak: Int

    public init(days: [DayAggregate], streak: Int) {
        self.days = days
        self.streak = streak
    }
}

/// **The six ways a dictation can end**, as a column a table can be built from.
///
/// The same closed set as ``SessionOutcomeClass``, minus the payload: a row shows *how many*
/// sessions ended each way, and the rung and read-back verdict a delivery carries are not a
/// column. Naming the set here rather than switching over ``DayAggregate/OutcomeCounts``' six
/// stored properties in the view is what lets ``UsageTabCopy`` and the page walk the same list —
/// and what makes a seventh class break the build rather than fall silently out of the table.
public enum UsageOutcome: String, Sendable, Equatable, CaseIterable {
    /// ``SessionOutcomeClass/delivered(rung:verified:)`` — the text reached the field.
    case delivered
    /// ``SessionOutcomeClass/failsafeHeld`` — the widget held it for the user.
    case held
    /// ``SessionOutcomeClass/aborted`` — cancelled before anything was asked of the engine.
    case aborted
    /// ``SessionOutcomeClass/failed`` — a failure with no transcript to lose.
    case failed
    /// ``SessionOutcomeClass/lost`` — a transcript existed and nobody has it.
    case lost
    /// ``SessionOutcomeClass/emptySkip`` — a press that recorded nothing.
    case skipped

    /// This outcome's tally in a day's column.
    public func count(in counts: DayAggregate.OutcomeCounts) -> Int {
        switch self {
        case .delivered: return counts.delivered
        case .held: return counts.failsafeHeld
        case .aborted: return counts.aborted
        case .failed: return counts.failed
        case .lost: return counts.lost
        case .skipped: return counts.emptySkip
        }
    }
}

/// One row of the Usage table: a day, and everything the ledger recorded on it.
///
/// The two ``DayAggregate/OutcomeCounts`` sit **side by side and are never added**. That is the
/// aspect's fifth honesty requirement expressed as a type: there is no field here holding a
/// combined total, so a view cannot render one without writing the addition itself, in the open.
///
/// The percentiles are ``LatencyBucketBound``s, not `Int`s. An `Int` here would be the type that
/// lets a view print `376 ms` from a histogram that only knows the sample landed in the 400 ms
/// bucket — the bound is the strongest true statement available, and it is the only one the row
/// can carry. `nil` is a day that measured nothing, and is deliberately not `0`.
public struct UsageDayRow: Sendable, Equatable, Identifiable {
    /// The day these numbers are about.
    public let day: CalendarDay
    /// Real dictation, in the six classes and the four rungs.
    public let realWork: DayAggregate.OutcomeCounts
    /// Onboarding's TRY IT — counted in full, counted apart.
    public let onboarding: DayAggregate.OutcomeCounts
    /// The median of the day's real-work cycle times, as a bound. `nil` when nothing was measured.
    public let medianLatency: LatencyBucketBound?
    /// The 95th percentile, as a bound. `nil` when nothing was measured.
    public let ninetyFifthLatency: LatencyBucketBound?
    /// How many cycle times the day's percentiles were computed from. `0` is the honest empty
    /// case, and is why a view never has to guess whether a `nil` bound means "fast" or "absent".
    public let latencySampleCount: Int

    /// The row's identity, stable across a reload — one row per day, always.
    public var id: Int { day.dayNumber }

    /// The day's actual dictations: the real-work sessions in which a transcript existed
    /// (``DayAggregate/OutcomeCounts/transcriptsProduced``). Read off Core rather than defined
    /// here, so this tab and ``UsageWindow/streak(asOf:)`` cannot come to disagree about what a
    /// day of dictation is.
    public var dictations: Int { realWork.transcriptsProduced }

    /// How many real-work deliveries `rung` carried. A **count**, never a share of anything: the
    /// injection-success denominator belongs to the matrix (`docs/STATUS.md:44-46`), and this row
    /// has no access to it and offers no arithmetic that could imitate one.
    public func deliveries(via rung: InjectionRung) -> Int {
        realWork.deliveries(via: rung)
    }

    public init(
        day: CalendarDay, realWork: DayAggregate.OutcomeCounts,
        onboarding: DayAggregate.OutcomeCounts, medianLatency: LatencyBucketBound?,
        ninetyFifthLatency: LatencyBucketBound?, latencySampleCount: Int
    ) {
        self.day = day
        self.realWork = realWork
        self.onboarding = onboarding
        self.medianLatency = medianLatency
        self.ninetyFifthLatency = ninetyFifthLatency
        self.latencySampleCount = latencySampleCount
    }
}

/// What the Usage tab is showing.
public struct UsageTabState: Sendable, Equatable {
    /// The rows, **newest first**. The window keeps its days ascending because eviction takes
    /// from the front; a person opening this tab is looking for today.
    public var rows: [UsageDayRow]
    /// Whether the ledger has been read. `false` with no rows is "we haven't looked yet"; `true`
    /// with no rows is the empty state, and the two must not render the same
    /// (the ``SettingsCopy/dictionaryEmpty`` guard). The difference matters more here than
    /// anywhere else in the window: a store that failed to load would otherwise tell a daily user
    /// they have never dictated.
    public var isLoaded: Bool
    /// The run of consecutive days, as the wiring answered it.
    public var streak: Int

    /// The state the window opens in.
    public static let initial = UsageTabState(rows: [], isLoaded: false, streak: 0)

    /// How many days the ledger holds. Days, not dictations: a day exists here only because a
    /// session was folded into it, so this is the size of the window and not a count of use.
    public var daysRecorded: Int { rows.count }

    /// The window's real dictations — the sessions in which a transcript existed, across every
    /// day held. Real work only; the setup demo has its own total below and the two are never one
    /// number.
    public var dictationCount: Int { rows.reduce(0) { $0 + $1.dictations } }

    /// Every real-work session the window holds, in all six classes.
    public var realWorkSessionCount: Int { rows.reduce(0) { $0 + $1.realWork.total } }

    /// Every onboarding session, counted apart.
    public var onboardingSessionCount: Int { rows.reduce(0) { $0 + $1.onboarding.total } }

    public init(rows: [UsageDayRow], isLoaded: Bool, streak: Int) {
        self.rows = rows
        self.isLoaded = isLoaded
        self.streak = streak
    }
}

/// Everything that can happen to the Usage tab. A closed set, folded exhaustively, with no
/// time-based transition in it — the widget's never-auto-dismiss discipline, applied to a settings
/// surface for the same reason: nothing here should change while a user is reading it. A page that
/// re-read itself while open would also make the streak change under a reader at midnight, which
/// is a scheduling detail reported as a fact about them.
public enum UsageTabAction: Sendable, Equatable {
    /// The ledger was read; these are its days and the streak off them.
    case snapshotLoaded(UsageSnapshot)
    /// The user cleared it, and the store said so.
    case cleared
}

/// The Usage tab's decisions — pure, clock-free, and holding no arithmetic beyond ordering.
///
/// **Nothing here divides.** Every number the tab renders is a count the ledger folded or a bound
/// the histogram computed; the only quotient anyone would want is the first-method-success rate,
/// whose denominator belongs to the injection matrix and is structurally capped at 17 of 20 on
/// this machine (`docs/STATUS.md:44-46`). A reducer that could produce one would eventually be
/// asked to.
public enum UsageTabReducer {

    /// The two percentiles the tab reports. Named once, here, because the copy that renders them
    /// says "half" and "19 in 20" and the two spellings must stay attached to the same numbers.
    private static let medianPercent = 50
    private static let ninetyFifthPercent = 95

    public static func reduce(_ state: UsageTabState, _ action: UsageTabAction) -> UsageTabState {
        var next = state
        switch action {
        case .snapshotLoaded(let snapshot):
            next.rows = rows(from: snapshot.days)
            next.streak = snapshot.streak
            next.isLoaded = true

        case .cleared:
            // `isLoaded` stays true. The file was read and is now empty; dropping back to the
            // unread state would put the page into "we haven't looked yet", which is a different
            // claim and a false one — the user has just watched it be emptied.
            next.rows = []
            next.streak = 0
        }
        return next
    }

    /// The rows a set of days produces: one per day, **newest first**, with no day invented
    /// between them. A gap in the list is a day nobody dictated on, and filling it with a row of
    /// zeroes would repair exactly the lapse a streak is supposed to show
    /// (``UsageWindow``'s no-materialised-days rule, honoured by a reader rather than worked
    /// around).
    private static func rows(from days: [DayAggregate]) -> [UsageDayRow] {
        days
            .map(row(for:))
            .sorted { $0.day > $1.day }
    }

    private static func row(for aggregate: DayAggregate) -> UsageDayRow {
        let latency = aggregate.realWorkLatency
        return UsageDayRow(
            day: aggregate.day,
            realWork: aggregate.realWork,
            onboarding: aggregate.onboarding,
            medianLatency: latency.percentile(medianPercent),
            ninetyFifthLatency: latency.percentile(ninetyFifthPercent),
            latencySampleCount: latency.sampleCount)
    }
}
