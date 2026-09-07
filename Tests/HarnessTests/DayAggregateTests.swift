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

/// ``DayAggregate`` and the fold — `usage-vocabulary`'s B3–B6, written before the type exists.
///
/// The aggregate is where a day's session records stop being a list and become the numbers the
/// P0 gate reads. Everything this suite protects is a way that arithmetic can quietly lie:
///
/// - **Totality.** All six outcome classes are counted, and none is coerced into another at the
///   margin (`SessionOutcomeClass.swift:16-19`). The first-method-success metric is *derived*
///   from `delivered` counts, so a class rounded into `delivered` — or out of `lost` — changes a
///   gate figure without changing a single line of the pipeline.
/// - **Onboarding stays out of the real-work numbers.** Onboarding's TRY IT runs through the
///   production ledger, and its injector never holds, so a refused demo finalizes
///   ``SessionOutcomeClass/lost`` (``SessionKind``). `ROADMAP.md:95` fixes transcript loss at
///   exactly zero *for real dictation*; a setup failure counted there would fail a gate about
///   something it is not about, and dropping it instead would hide a real onboarding defect. So
///   both are counted, in separate columns, and neither is thrown away.
/// - **No fabricated rung.** Only a delivered session says which rung delivered it. A failure
///   tallying a rung would invent evidence for the injection matrix.
/// - **No fabricated latency.** A session whose spans all went unrecorded measured nothing, and
///   contributes *no sample* — never a zero sample, which would read as the fastest dictation on
///   record. This is ``LatencySpan/Presence/notPresent``'s rule one level up.
///
/// Nothing here reads a clock. A record carries no date — `VoccaCore` has none to give it — so
/// the day an aggregate belongs to is supplied by its caller at the wiring seam, exactly as
/// ``LatencySpan``'s elapsed arrives already measured.
final class DayAggregateTests: XCTestCase {

    // MARK: - Test helpers

    /// A day to hang the aggregate on. Which day is never load-bearing in this suite — the fold
    /// is arithmetic over records, and the day is only the label it is filed under.
    private static func aDay(
        year: Int = 2026, month: Int = 9, day: Int = 6
    ) throws -> CalendarDay {
        try XCTUnwrap(
            CalendarDay(year: year, month: month, day: day),
            "the suite's own fixture date must be a real date")
    }

    /// A hand-built record. `engine` follows the record's own rule — attribution for the routes
    /// that asked the engine, `nil` for the two that never did.
    private static func record(
        _ outcome: SessionOutcomeClass, kind: SessionKind = .dictation,
        spans: [LatencySpan] = [], id: Int = 1
    ) -> SessionRecord {
        let asked: Bool
        switch outcome {
        case .aborted, .emptySkip: asked = false
        default: asked = true
        }
        return SessionRecord(
            id: SessionRecord.ID(rawValue: id), outcome: outcome, spans: spans,
            engine: asked
                ? EngineIdentity(
                    id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet", isLocal: true)
                : nil,
            kind: kind)
    }

    /// The six outcome classes, one of each — the closed set the pipeline can exit by.
    private static func oneOfEachOutcome() -> [SessionOutcomeClass] {
        [
            .delivered(rung: .clipboardPaste, verified: true),
            .failsafeHeld,
            .aborted,
            .failed,
            .lost,
            .emptySkip,
        ]
    }

    // MARK: - B3 — totality

    /// Folding one record of each of the six outcome classes yields six counts of one.
    ///
    /// The classes are a closed set and the fold is total over it: every record the pipeline can
    /// produce lands somewhere, exactly once. A class silently dropped costs the gate a number it
    /// cannot recover; a class merged into its neighbour hands the gate a number that is wrong in
    /// the flattering direction, since the classes that would get merged into `delivered` are
    /// precisely the ones that were not delivered.
    func testFoldingOneOfEachOutcomeClassCountsAllSixWithNothingCoerced() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        for (index, outcome) in Self.oneOfEachOutcome().enumerated() {
            aggregate.fold(Self.record(outcome, id: index + 1))
        }

        let counts = aggregate.realWork
        XCTAssertEqual(
            counts.delivered, 1,
            "one session reached the focused field, so exactly one delivery is counted — this is the numerator of the first-method-success metric and nothing else may be rounded into it")
        XCTAssertEqual(
            counts.failsafeHeld, 1,
            "the failsafe held one transcript for the user. That is I1's floor, not a delivery and not a loss, and it has its own column so it can be read as neither")
        XCTAssertEqual(
            counts.aborted, 1,
            "one session was cancelled before anything was asked of the engine. An abort is a user's decision, not a defect, and counting it as a failure would make the product look broken by being used correctly")
        XCTAssertEqual(
            counts.failed, 1,
            "one session failed outright. A failure that never produced a transcript is not a lost transcript, and merging the two makes P0's count of zero losses uncomputable")
        XCTAssertEqual(
            counts.lost, 1,
            "one transcript existed and nobody has it. This is the only class the transcript-loss metric counts (ROADMAP.md:95), so it survives the fold as itself or the gate has no input")
        XCTAssertEqual(
            counts.emptySkip, 1,
            "one short press recorded nothing and skipped the injector. It is not an abort and not a failure — pressing the key by accident must not show up as either")
        XCTAssertEqual(
            counts.total, 6,
            "six records went in, so six sessions come out. A total that disagrees with the sum of the columns means a record landed in two places or in none")
    }

    // MARK: - B4 — onboarding is counted apart from real work

    /// An onboarding session lands in the onboarding counts and never in the real-work ones —
    /// including the `.lost` that motivated the whole distinction.
    ///
    /// Onboarding's injector never holds: the sink owns delivery, so a refused TRY IT reaches the
    /// failsafe arm with the journal holding nothing and finalizes ``SessionOutcomeClass/lost``.
    /// `ROADMAP.md:95` fixes transcript loss at exactly zero with no acceptable non-zero value,
    /// and it is about *dictation* — a setup demo counted there fails a gate about daily use on
    /// the strength of a window the user had not started working in yet. The demo is not
    /// discarded either: it is a real onboarding failure and stays visible in its own column.
    func testAnOnboardingSessionNeverLandsInTheRealWorkCounts() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        aggregate.fold(Self.record(.lost, kind: .onboarding, id: 1))
        aggregate.fold(
            Self.record(.delivered(rung: .clipboardPaste, verified: true), kind: .onboarding, id: 2)
        )

        XCTAssertEqual(
            aggregate.realWork.lost, 0,
            "a refused TRY IT is an onboarding loss, and P0's zero-loss figure is about real dictation. Counting it here fails the gate on a setup demo — the exact confusion SessionKind exists to prevent")
        XCTAssertEqual(
            aggregate.realWork.total, 0,
            "no real dictation happened, so the real-work column is empty. A demo counted as work also inflates the daily-use figures the streak reads")
        XCTAssertEqual(
            aggregate.onboarding.lost, 1,
            "the onboarding loss is still a real defect and is counted where it can be seen. Separating the two must never mean throwing one away")
        XCTAssertEqual(
            aggregate.onboarding.delivered, 1,
            "the successful demo is counted too — onboarding gets the same six classes, in its own column, not a reduced summary")
        XCTAssertEqual(
            aggregate.onboarding.total, 2,
            "both onboarding sessions are accounted for")
        XCTAssertEqual(
            aggregate.sessionCount, 2,
            "the day saw two sessions in total. The split is about which figure each one answers, not about hiding any of them")
    }

    /// Real work and onboarding on the same day are counted side by side, neither leaking.
    ///
    /// The day a user first runs Vocca is a day with both on it, and it is the day the two
    /// figures are most likely to be confused. Read from either column, the other one's sessions
    /// must be invisible.
    func testRealWorkAndOnboardingOnTheSameDayAreCountedSideBySide() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        aggregate.fold(
            Self.record(.delivered(rung: .accessibility, verified: true), id: 1))
        aggregate.fold(Self.record(.lost, kind: .onboarding, id: 2))

        XCTAssertEqual(
            aggregate.realWork.delivered, 1,
            "the real dictation is counted as real work")
        XCTAssertEqual(
            aggregate.realWork.lost, 0,
            "the onboarding loss did not leak into the real-work loss count, which is the one the P0 gate reads")
        XCTAssertEqual(
            aggregate.onboarding.delivered, 0,
            "the real delivery did not leak into onboarding either — a demo's success rate must be about demos, or it says nothing about onboarding")
        XCTAssertEqual(
            aggregate.onboarding.lost, 1,
            "the demo's loss is counted, once, on the onboarding side")
    }

    // MARK: - B5 — the rung tally is evidence, never an invention

    /// A delivered record increments exactly its own rung's tally and no other's.
    ///
    /// The per-rung tallies are the same evidence the injection matrix records by hand: which
    /// rung actually delivered. A tally that drifted one rung over would report accessibility
    /// insertions the app never performed, in the one place a reader would trust as measurement
    /// rather than a claim.
    func testADeliveredRecordTalliesExactlyItsOwnRung() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        aggregate.fold(Self.record(.delivered(rung: .accessibility, verified: true), id: 1))
        aggregate.fold(Self.record(.delivered(rung: .clipboardPaste, verified: true), id: 2))
        aggregate.fold(Self.record(.delivered(rung: .clipboardPaste, verified: false), id: 3))

        XCTAssertEqual(
            aggregate.realWork.deliveries(via: .accessibility), 1,
            "one session was delivered by the accessibility rung, so that rung is credited once")
        XCTAssertEqual(
            aggregate.realWork.deliveries(via: .clipboardPaste), 2,
            "two sessions were delivered by clipboard paste, verified or not — delivery is the fact the tally counts, and the verified flag is a separate question this column does not answer")
        XCTAssertEqual(
            aggregate.realWork.deliveries(via: .keystrokeSynthesis), 0,
            "no session used keystroke synthesis, and a rung that delivered nothing is credited with nothing")
        XCTAssertEqual(
            aggregate.realWork.deliveries(via: .widgetFailsafe), 0,
            "no session was delivered from the failsafe window either")
        XCTAssertEqual(
            aggregate.realWork.delivered, 3,
            "the rung tallies add up to the delivered count — a delivery credited to no rung, or to two, would make the columns disagree")
    }

    /// A non-delivered record increments no rung at all.
    ///
    /// None of the other five classes knows which rung it stopped at, and the fold must not
    /// guess. A `failsafeHeld` credited to `.widgetFailsafe` is the tempting mistake: the
    /// failsafe *window* did open, but nothing was inserted anywhere, and the tally is a record
    /// of insertions.
    func testANonDeliveredRecordTalliesNoRung() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        for (index, outcome) in Self.oneOfEachOutcome().enumerated()
        where outcome != .delivered(rung: .clipboardPaste, verified: true) {
            aggregate.fold(Self.record(outcome, id: index + 1))
        }

        for rung in InjectionRung.allCases {
            XCTAssertEqual(
                aggregate.realWork.deliveries(via: rung), 0,
                "five non-delivered sessions credited \(rung) with a delivery it never made. Only SessionOutcomeClass.delivered carries a rung; every other class stopped somewhere the record does not name, and inventing a rung for it fabricates injection evidence")
        }
        XCTAssertEqual(
            aggregate.realWork.delivered, 0,
            "nothing was delivered, so nothing is counted as delivered")
    }

    // MARK: - B6 — the loss distinction survives the fold

    /// `lost` is counted apart from `failed`, and `failsafeHeld` counts as neither.
    ///
    /// `loss-observability` exists because these three were one number. A transcript the user
    /// can still copy out of the failsafe window is not lost; a failure that never produced a
    /// transcript has nothing to lose. Only the middle case — text produced, custody refused —
    /// is what `ROADMAP.md:95` fixes at zero, and it is only measurable while the three stay
    /// apart.
    func testALostTranscriptIsCountedApartFromAFailureAndFromTheFailsafe() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        aggregate.fold(Self.record(.failed, id: 1))
        aggregate.fold(Self.record(.failsafeHeld, id: 2))
        aggregate.fold(Self.record(.failsafeHeld, id: 3))

        XCTAssertEqual(
            aggregate.realWork.lost, 0,
            "no transcript was lost: one session never produced text, and two were held for the user. A loss count that includes either reports a P0 gate failure that did not happen")
        XCTAssertEqual(
            aggregate.realWork.failed, 1,
            "the failure is counted as a failure, on its own")
        XCTAssertEqual(
            aggregate.realWork.failsafeHeld, 2,
            "both held transcripts are counted as held — I1's floor working, which is a success of the ladder's design and must not read as a defect")

        aggregate.fold(Self.record(.lost, id: 4))
        XCTAssertEqual(
            aggregate.realWork.lost, 1,
            "the one genuinely lost transcript is counted, and it is the only thing in this column. That is the number the zero-loss gate reads")
        XCTAssertEqual(
            aggregate.realWork.failed, 1,
            "a loss did not also increment failed — the two classes were separated deliberately and must not be re-merged by the arithmetic above them")
        XCTAssertEqual(
            aggregate.realWork.failsafeHeld, 2,
            "and it did not increment the failsafe column either")
    }

    // MARK: - Latency: a sample only where something was measured

    /// A session whose spans all went unrecorded adds no latency sample — not a zero sample.
    ///
    /// ``LatencySpan/Presence/notPresent`` exists so "this never ran" is representable without
    /// writing a `0`, and the fold is where that rule is most easily lost: summing spans
    /// naïvely yields `.zero`, which is a perfectly valid `Duration` and lands in the fastest
    /// bucket the histogram has. A day of aborted sessions would then report the best latency in
    /// the product's history, computed entirely from measurements that were never taken.
    func testASessionWhoseSpansAllWentUnrecordedAddsNoLatencySample() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        aggregate.fold(Self.record(.aborted, spans: [LatencySpan.cleanupNotPresent()], id: 1))
        aggregate.fold(Self.record(.emptySkip, spans: [], id: 2))

        XCTAssertEqual(
            aggregate.realWorkLatency.sampleCount, 0,
            "neither session measured anything — one carried only a span that never ran, the other carried none at all — so the day holds no latency samples. A zero sample here is a fabricated 0 ms dictation, which is worse than an absent one because nothing downstream can tell it from a real reading")
        XCTAssertNil(
            aggregate.realWorkLatency.percentile(50),
            "no samples, no percentile — the day must render n/a, never a fabricated number")
        XCTAssertEqual(
            aggregate.realWork.total, 2,
            "the two sessions are still counted as sessions. Having measured no latency is not the same as not having happened")
    }

    /// A session with recorded spans contributes exactly one sample, equal to their sum.
    ///
    /// The sample is the per-cycle total — key-up to text-on-screen — which is the same
    /// definition the composite benchmark row already uses
    /// (``LatencyBenchmarkRealEngineTests/testTheCompositeRowTotalsPerCycleAndNamesTheCleanupSpan``).
    /// Two spans of 100 ms make a 200 ms cycle, not a 100 ms one: a fold that took the longest
    /// span, or the first, would report a latency the user never experienced, and the two land in
    /// different buckets on purpose so the difference is visible here.
    func testASessionsLatencySampleIsTheSumOfItsRecordedSpans() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        aggregate.fold(
            Self.record(
                .delivered(rung: .clipboardPaste, verified: true),
                spans: [
                    .recorded(name: .captureClose, elapsed: .milliseconds(100)),
                    .recorded(name: .asr, elapsed: .milliseconds(100)),
                    .cleanupNotPresent(),
                ], id: 1))

        XCTAssertEqual(
            aggregate.realWorkLatency.sampleCount, 1,
            "one session, one sample — a session is a cycle, and the histogram counts cycles, not spans")
        XCTAssertEqual(
            aggregate.realWorkLatency.percentile(100),
            .atMostMilliseconds(200),
            "100 ms of capture-close plus 100 ms of ASR is a 200 ms cycle, which lands in the 200 ms bucket. A reading of 100 ms would mean the fold took one span and dropped the other, reporting half the latency the user actually waited; the cleanup span never ran and correctly added nothing")
    }

    /// Onboarding latency never enters the real-work histogram.
    ///
    /// The P2 targets (`ROADMAP.md:171`) are about the dictation loop. A setup demo runs through
    /// a different injector — a sink that always accepts — so its timings are not the timings the
    /// gate is asking about, and a slow first-run demo on a cold model would drag a figure it has
    /// no business being in.
    func testOnboardingLatencyNeverEntersTheRealWorkHistogram() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        aggregate.fold(
            Self.record(
                .delivered(rung: .clipboardPaste, verified: true), kind: .onboarding,
                spans: [.recorded(name: .asr, elapsed: .milliseconds(3200))], id: 1))
        aggregate.fold(
            Self.record(
                .delivered(rung: .clipboardPaste, verified: true),
                spans: [.recorded(name: .asr, elapsed: .milliseconds(100))], id: 2))

        XCTAssertEqual(
            aggregate.realWorkLatency.sampleCount, 1,
            "only the real dictation is a latency sample. Two samples here means the demo's timing was folded into the figure the P2 gate reads")
        XCTAssertEqual(
            aggregate.realWorkLatency.percentile(100),
            .atMostMilliseconds(100),
            "the real dictation took 100 ms and that is the day's slowest reading. A 3200 ms answer would be the onboarding demo's cold first run, contaminating a gate about the dictation loop with a measurement of the setup window")
    }

    /// A fresh aggregate is empty in every column and has no latency at all.
    ///
    /// A day is only present in the ledger because something happened on it, but the empty value
    /// is what the fold starts from, and it must start from nothing rather than from a plausible
    /// zero reading.
    func testAFreshAggregateCountsNothingAndReportsNoPercentile() throws {
        let day = try Self.aDay()
        let aggregate = DayAggregate(day: day)

        XCTAssertEqual(aggregate.day, day, "the aggregate is filed under the day it was made for")
        XCTAssertEqual(
            aggregate.sessionCount, 0, "nothing has been folded in, so nothing is counted")
        XCTAssertEqual(
            aggregate.realWork.total, 0, "the real-work column starts empty")
        XCTAssertEqual(
            aggregate.onboarding.total, 0, "so does the onboarding column")
        XCTAssertNil(
            aggregate.realWorkLatency.percentile(95),
            "an empty histogram has no p95 — nil, never 0, or an untouched day reads as the fastest in the window")
    }

    // MARK: - The fold as a pure function

    /// Folding a day's records is order-independent: the same records in any order give the same
    /// aggregate.
    ///
    /// This is what makes the fold a *function* of the day's records rather than of the sequence
    /// they happened to arrive in, and it is the property `usage-store` will lean on when it
    /// rebuilds a day from whatever it has on disk. It holds because both halves of the aggregate
    /// add: counts add, and so do the histogram's bucket counts — which is the same reason a
    /// window's percentile can be computed from summed days while an averaged per-day percentile
    /// cannot.
    func testFoldingADaysRecordsIsOrderIndependent() throws {
        let day = try Self.aDay()
        let records = [
            Self.record(
                .delivered(rung: .accessibility, verified: true),
                spans: [.recorded(name: .asr, elapsed: .milliseconds(100))], id: 1),
            Self.record(.lost, kind: .onboarding, id: 2),
            Self.record(
                .delivered(rung: .clipboardPaste, verified: false),
                spans: [.recorded(name: .asr, elapsed: .milliseconds(600))], id: 3),
            Self.record(.aborted, id: 4),
        ]

        let forwards = DayAggregate.folded(records, on: day)
        let backwards = DayAggregate.folded(records.reversed(), on: day)

        XCTAssertEqual(
            forwards, backwards,
            "the same four sessions in the other order are the same day. If order changed the answer, a day rebuilt from storage would disagree with the day that was lived, and no figure computed from it would be reproducible")
        XCTAssertEqual(
            forwards.sessionCount, 4,
            "every record was folded in — a convenience that stopped early would silently under-count the day it was asked to summarise")
        XCTAssertEqual(
            forwards.realWorkLatency.sampleCount, 2,
            "the two measured dictations are both sampled; the abort measured nothing and the onboarding loss is not real work")
    }

    // MARK: - Structural: equality distinguishes every field

    /// Aggregate equality distinguishes every field it carries.
    ///
    /// The ``AppsTabReducerTests/testStateEqualityDistinguishesEveryField`` precedent. Every
    /// assertion in this suite that compares two aggregates — and every future one, in
    /// `usage-store`'s round-trip especially — is only worth as much as this: if equality
    /// compared a subset of the fields, a decoder that dropped the onboarding column or the
    /// histogram would round-trip "equal" and the loss would be invisible.
    func testAggregateEqualityDistinguishesEveryField() throws {
        let day = try Self.aDay()
        let base = DayAggregate(day: day)

        XCTAssertEqual(
            base, DayAggregate(day: day),
            "two aggregates over the same day with nothing folded in are the same value")
        XCTAssertNotEqual(
            base, DayAggregate(day: try Self.aDay(day: 7)),
            "the day is part of the value — two different days' aggregates are never the same aggregate, however identical their counts")

        for outcome in Self.oneOfEachOutcome() {
            var folded = base
            folded.fold(Self.record(outcome))
            XCTAssertNotEqual(
                folded, base,
                "folding a \(outcome) session must change the value. A field equality ignores is a field a decoder can drop in silence")

            var onboarded = base
            onboarded.fold(Self.record(outcome, kind: .onboarding))
            XCTAssertNotEqual(
                onboarded, base,
                "the onboarding column is part of the value too — it is kept separate from real work, not kept out of the record")
            XCTAssertNotEqual(
                onboarded, folded,
                "the same outcome counted as onboarding is a different value from the same outcome counted as real work. Equality that cannot tell them apart is equality that has not read the distinction the whole aggregate is built around")
        }

        for rung in InjectionRung.allCases {
            var delivered = base
            delivered.fold(Self.record(.delivered(rung: rung, verified: true)))
            var elsewhere = base
            elsewhere.fold(
                Self.record(
                    .delivered(
                        rung: rung == .accessibility ? .clipboardPaste : .accessibility,
                        verified: true)))
            XCTAssertNotEqual(
                delivered, elsewhere,
                "a delivery by \(rung) is a different value from a delivery by another rung — the per-rung tally is part of the aggregate, not a derived view of it")
        }

        var measured = base
        measured.fold(
            Self.record(
                .delivered(rung: .clipboardPaste, verified: true),
                spans: [.recorded(name: .asr, elapsed: .milliseconds(100))]))
        var unmeasured = base
        unmeasured.fold(Self.record(.delivered(rung: .clipboardPaste, verified: true)))
        XCTAssertNotEqual(
            measured, unmeasured,
            "two days with the same counts and different latencies are different days. If equality ignored the histogram, a store that lost every sample would still compare equal to one that kept them")
    }

    // MARK: - Which sessions are evidence a dictation happened

    /// ``DayAggregate/OutcomeCounts/transcriptsProduced`` counts the three classes in which a
    /// transcript existed, and only those.
    ///
    /// The claim is named here, once, because two different readers need it: ``UsageWindow``'s
    /// streak, which asks whether the day was a day of dictation, and the Usage tab, which will
    /// want to say how many dictations a day held without implying that a stray hotkey press was
    /// one. `delivered`, `failsafeHeld` and `lost` all mean the user spoke and the engine
    /// transcribed — `lost` included, since the transcript's existence is exactly what makes its
    /// disappearance a loss. `emptySkip`, `aborted` and `failed` produced no text at all.
    ///
    /// Open-coding that set at each call site is how the two readers eventually disagree about
    /// what a dictation is, so the set lives on the counts and the callers read a claim.
    func testTranscriptsProducedCountsExactlyTheClassesInWhichATranscriptExisted() throws {
        var aggregate = DayAggregate(day: try Self.aDay())
        for (index, outcome) in Self.oneOfEachOutcome().enumerated() {
            aggregate.fold(Self.record(outcome, id: index + 1))
        }

        XCTAssertEqual(
            aggregate.realWork.transcriptsProduced, 3,
            """
            One session of each of the six classes yields three transcripts: the delivered one, \
            the one the failsafe held, and the lost one. The other three — a stray press, a \
            cancellation and a transcription failure — produced no text, and counting them would \
            let days nobody dictated on look like days of use.
            """)

        var noTranscripts = DayAggregate(day: try Self.aDay())
        for (index, outcome) in [SessionOutcomeClass.emptySkip, .aborted, .failed].enumerated() {
            noTranscripts.fold(Self.record(outcome, id: index + 1))
        }
        XCTAssertEqual(
            noTranscripts.realWork.transcriptsProduced, 0,
            """
            A day of presses that recorded nothing, cancellations and engine failures produced no \
            transcript at all. Its sessions are still counted as themselves — the day is not \
            hidden — but none of them is evidence that a dictation happened.
            """)
        XCTAssertEqual(
            noTranscripts.realWork.total, 3,
            """
            The day still holds three sessions. Producing no transcript is not the same as not \
            existing, and the class counts stay whole so the Usage tab can show a day of \
            failures as the defect it is.
            """)

        var onboardingOnly = DayAggregate(day: try Self.aDay())
        onboardingOnly.fold(
            Self.record(.delivered(rung: .clipboardPaste, verified: true), kind: .onboarding))
        XCTAssertEqual(
            onboardingOnly.realWork.transcriptsProduced, 0,
            "an onboarding demo's transcript is counted in the onboarding column, and the real-work column stays empty — the two columns never mix, here as everywhere else")
        XCTAssertEqual(
            onboardingOnly.onboarding.transcriptsProduced, 1,
            "the same claim is available on the onboarding column, because it is the same shape twice — a question asked of one column must be askable of the other")
    }
}
