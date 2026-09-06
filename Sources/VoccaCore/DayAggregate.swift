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

/// One day of use, as the numbers the P0 gate reads: how each session ended, which rung
/// delivered it, and how long the cycle took.
///
/// The aggregate is a pure fold over ``SessionRecord``s. It reads no clock and knows no date of
/// its own — a record carries no day, because `VoccaCore` has none to stamp on it — so the day an
/// aggregate is filed under is supplied by its caller at the wiring seam, exactly as
/// ``LatencySpan``'s elapsed arrives already measured. Nothing here checks that a record
/// "belongs" to ``day``; the caller that resolved the day is the only code that could know, and
/// it decides once, above this type.
///
/// ## Two columns, never mixed
///
/// Onboarding's TRY IT runs through the production ledger under the same recorder as real
/// dictation (``SessionKind``), and its injector never holds — a refused demo finalizes
/// ``SessionOutcomeClass/lost``. `ROADMAP.md:95` fixes transcript loss at exactly zero for real
/// dictation, and `ROADMAP.md:102`'s streak is about dictating as the *primary text-input
/// method*, so a setup demo counted as work fails one gate and inflates the other. It is not
/// discarded either: an onboarding loss is a real defect. So the day carries ``realWork`` and
/// ``onboarding`` — the **same** six-class shape twice, rather than two divergent sets of
/// fields, so neither column can quietly acquire a distinction the other lacks and every future
/// question ("how many demos failed?") is answerable in the vocabulary already written.
///
/// ## Latency is real work only
///
/// ``realWorkLatency`` covers ``SessionKind/dictation`` sessions and nothing else. The P2 targets
/// (`ROADMAP.md:171`) are about the dictation loop; a setup demo runs through a different
/// injector — a sink that always accepts — often on a cold model, and folding its timing into
/// the histogram would contaminate the figure the gate reads with a measurement of the
/// onboarding window. Onboarding latency is therefore **not retained**: retaining it would mean
/// a second histogram, a second column on disk and a second number nobody has asked a question
/// about yet.
///
/// ## What the fold refuses to invent
///
/// - **No class is coerced.** All six outcome classes are counted as themselves
///   (`SessionOutcomeClass.swift:16-19`) — `lost` apart from `failed`, `failsafeHeld` as neither.
/// - **No rung is fabricated.** Only ``SessionOutcomeClass/delivered(rung:verified:)`` carries a
///   rung, so only a delivery tallies one. The other five stopped somewhere the record does not
///   name, and a `failsafeHeld` credited to ``InjectionRung/widgetFailsafe`` would read as an
///   insertion that never happened.
/// - **No latency is fabricated.** A session whose spans all went unrecorded contributes *no
///   sample*, not a zero one — ``LatencySpan/Presence/notPresent``'s rule one level up. A
///   fabricated 0 ms would land in the fastest bucket the histogram has and read as the best
///   dictation on record.
public struct DayAggregate: Sendable, Equatable {

    /// One column of a day: how sessions of a single ``SessionKind`` ended, and which rungs
    /// delivered the ones that were delivered.
    ///
    /// Used twice — once for real work, once for onboarding — so both columns count the same six
    /// classes with the same meanings, and a reader comparing them is comparing like with like.
    public struct OutcomeCounts: Sendable, Equatable {

        /// Sessions whose transcript reached the focused field. The first-method-success
        /// metric's numerator, and the only class it counts.
        public private(set) var delivered: Int
        /// Sessions whose transcript the failsafe window held for the user. I1's floor: not a
        /// delivery, and emphatically not a loss.
        public private(set) var failsafeHeld: Int
        /// Sessions cancelled before anything was asked of the engine.
        public private(set) var aborted: Int
        /// Sessions that failed with no transcript to lose.
        public private(set) var failed: Int
        /// Sessions where a transcript existed and nobody has it — the only class the
        /// transcript-loss metric counts.
        public private(set) var lost: Int
        /// Short presses that recorded nothing and skipped the injector.
        public private(set) var emptySkip: Int

        /// Deliveries per rung, one entry per ``InjectionRung`` from construction.
        ///
        /// Every rung is present from the start, at zero, so two days' aggregates compare on
        /// their counts rather than on which keys happen to exist. A zero here is a *count* of
        /// deliveries — a fact — not a fabricated measurement; the thing that must never be
        /// invented is an entry for a session that named no rung, and only
        /// ``SessionOutcomeClass/delivered(rung:verified:)`` ever adds one.
        public private(set) var deliveriesByRung: [InjectionRung: Int]

        /// An empty column: every class at zero, every rung present and uncredited.
        public init() {
            delivered = 0
            failsafeHeld = 0
            aborted = 0
            failed = 0
            lost = 0
            emptySkip = 0
            deliveriesByRung = [:]
            for rung in InjectionRung.allCases {
                deliveriesByRung[rung] = 0
            }
        }

        /// A column rebuilt from counts — the store's way back from a persisted day.
        ///
        /// **Failable, and it refuses rather than repairs.** A count off disk is the one number
        /// here that did not come from ``count(_:)``, so a negative tally — the only way these
        /// six values can be nonsense — yields `nil` and leaves the store to skip the row, rather
        /// than being clamped into a plausible zero. Rung tallies are held to the same rule.
        ///
        /// The every-rung-present invariant is **maintained, not bypassed**: construction starts
        /// from ``init()``'s zero-filled table and `deliveriesByRung` is merged over it, so a
        /// column rebuilt from a file that named two rungs still holds all four and still
        /// compares with a folded column on counts rather than on which keys happen to exist. A
        /// rung the running build does not have is not this initialiser's problem — an unknown
        /// raw value never becomes an ``InjectionRung``, so it cannot arrive here at all.
        ///
        /// - Returns: `nil` if any outcome count or any rung tally is negative.
        public init?(
            delivered: Int, failsafeHeld: Int, aborted: Int, failed: Int, lost: Int,
            emptySkip: Int, deliveriesByRung: [InjectionRung: Int]
        ) {
            guard
                ![delivered, failsafeHeld, aborted, failed, lost, emptySkip]
                    .contains(where: { $0 < 0 }),
                !deliveriesByRung.values.contains(where: { $0 < 0 })
            else {
                return nil
            }
            self.init()
            self.delivered = delivered
            self.failsafeHeld = failsafeHeld
            self.aborted = aborted
            self.failed = failed
            self.lost = lost
            self.emptySkip = emptySkip
            for (rung, count) in deliveriesByRung {
                self.deliveriesByRung[rung] = count
            }
        }

        /// Every session in this column. The six classes are exhaustive over the routes the
        /// pipeline can exit by, so this is a sum and never an estimate.
        public var total: Int {
            delivered + failsafeHeld + aborted + failed + lost + emptySkip
        }

        /// The sessions in which a transcript existed — the day's actual dictations.
        ///
        /// Three of the six classes mean the user spoke and the engine transcribed:
        /// ``SessionOutcomeClass/delivered(rung:verified:)``,
        /// ``SessionOutcomeClass/failsafeHeld`` and ``SessionOutcomeClass/lost``. `lost` counts
        /// here precisely *because* the transcript existed — its existence is what makes its
        /// disappearance a loss rather than a failure, and that loss is already reported, at zero
        /// tolerance, by ``lost`` itself. Deducting it twice would let one defect quietly shrink
        /// an unrelated figure.
        ///
        /// The other three produced no text at all: ``SessionOutcomeClass/emptySkip`` is a press
        /// that recorded nothing, ``SessionOutcomeClass/aborted`` is a cancellation, and
        /// ``SessionOutcomeClass/failed`` is a day the tool did not work.
        ///
        /// The set is named once, here, because more than one reader needs it —
        /// ``UsageWindow/streak(asOf:)`` asks whether a day was a day of dictation, and the Usage
        /// tab will want to say how many dictations a day held without counting a stray hotkey
        /// press as one. Open-coded at each call site, the two would eventually disagree about
        /// what a dictation is.
        public var transcriptsProduced: Int {
            delivered + failsafeHeld + lost
        }

        /// How many sessions `rung` delivered.
        public func deliveries(via rung: InjectionRung) -> Int {
            deliveriesByRung[rung] ?? 0
        }

        /// Counts one outcome as itself.
        ///
        /// The switch is exhaustive without a `default`, on purpose: a seventh outcome class is a
        /// change to what the pipeline can do, and it must break this line rather than fall
        /// silently into an existing column.
        fileprivate mutating func count(_ outcome: SessionOutcomeClass) {
            switch outcome {
            case .delivered(let rung, _):
                delivered += 1
                deliveriesByRung[rung] = deliveries(via: rung) + 1
            case .failsafeHeld: failsafeHeld += 1
            case .aborted: aborted += 1
            case .failed: failed += 1
            case .lost: lost += 1
            case .emptySkip: emptySkip += 1
            }
        }
    }

    /// The day these numbers are about, as resolved by the caller.
    public let day: CalendarDay
    /// Real dictation — the column every P0 figure is computed from.
    public private(set) var realWork: OutcomeCounts
    /// Onboarding's TRY IT — counted in full, counted apart.
    public private(set) var onboarding: OutcomeCounts
    /// Per-cycle latency for ``SessionKind/dictation`` sessions **only**. See the type's doc
    /// comment: a setup demo's timing is not the figure the P2 gate is asking about.
    public private(set) var realWorkLatency: LatencyHistogram

    /// An empty day. A day with no sessions is *absent* from the ledger rather than stored as a
    /// row of zeros — this value is what the fold starts from, not a day anyone dictated on.
    public init(day: CalendarDay) {
        self.day = day
        realWork = OutcomeCounts()
        onboarding = OutcomeCounts()
        realWorkLatency = LatencyHistogram()
    }

    /// A day rebuilt from its three parts — the store's way back from a persisted row.
    ///
    /// Not failable, and it does not need to be: every part that can be nonsense already refused
    /// to be built. ``CalendarDay/init(year:month:day:)`` gates the date, ``OutcomeCounts``'
    /// counts initialiser gates the tallies and ``LatencyHistogram/init(bucketCounts:)`` gates
    /// the buckets, so by the time three of them exist there is nothing left here to validate.
    /// Nothing is cross-checked either — this type never held such a rule, and inventing one
    /// here (that `delivered` equals the rung tallies, say) would make the store the first place
    /// in the tree that decides what a consistent day is.
    public init(
        day: CalendarDay, realWork: OutcomeCounts, onboarding: OutcomeCounts,
        realWorkLatency: LatencyHistogram
    ) {
        self.day = day
        self.realWork = realWork
        self.onboarding = onboarding
        self.realWorkLatency = realWorkLatency
    }

    /// Every session the day saw, both kinds together.
    public var sessionCount: Int {
        realWork.total + onboarding.total
    }

    /// Folds one session record into the day.
    ///
    /// Total over both kinds and all six classes: every record lands in exactly one column and
    /// exactly one class, and a record whose cycle was measured also lands in the histogram —
    /// but only if it was real work, and only if something was actually measured.
    public mutating func fold(_ record: SessionRecord) {
        switch record.kind {
        case .dictation:
            realWork.count(record.outcome)
            if let sample = DayAggregate.cycleElapsed(of: record) {
                realWorkLatency.record(sample)
            }
        case .onboarding:
            onboarding.count(record.outcome)
        }
    }

    /// The day's aggregate over `records`, folded in order.
    ///
    /// Order cannot matter — counts and bucket counts both add — which is what lets a store
    /// rebuild a day from whatever it has without minding how the records arrived.
    public static func folded(_ records: [SessionRecord], on day: CalendarDay) -> DayAggregate {
        var aggregate = DayAggregate(day: day)
        for record in records {
            aggregate.fold(record)
        }
        return aggregate
    }

    /// The session's cycle time — the sum of its **recorded** spans — or `nil` when it measured
    /// nothing.
    ///
    /// The sum is the same definition the composite benchmark row uses (key-up to
    /// text-on-screen), so the ledger's latency and the benchmark's are the same quantity rather
    /// than two similar ones.
    ///
    /// `nil` is the load-bearing return. A ``LatencySpan/Presence/notPresent`` span contributes
    /// nothing — it is not a zero — and a record with no recorded spans at all therefore has no
    /// cycle time to report. Returning `.zero` there would count an aborted session as an
    /// instantaneous dictation.
    private static func cycleElapsed(of record: SessionRecord) -> Duration? {
        var total = Duration.zero
        var measuredAnything = false
        for span in record.spans where span.presence == .recorded {
            total += span.elapsed
            measuredAnything = true
        }
        return measuredAnything ? total : nil
    }
}
