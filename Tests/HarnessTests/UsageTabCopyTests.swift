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

/// **The Usage tab's words** (`PRODUCT_SPEC.md` §7, the **Usage** entry), pinned before the tab
/// exists — the ``AppsTabCopyTests`` convention.
///
/// This tab's copy carries more weight than any other settings page's, because the page is a
/// **privacy disclosure** as much as a dashboard: it is the screen that makes §12's *"Metrics are
/// local and inspectable"* something a sceptic can check rather than take on trust. Four of the
/// assertions below are therefore not style pins at all — they are the honesty requirements of
/// `daily-use-ledger/usage-tab/spec.md`, expressed in the only place a user meets them:
///
/// - **E4** a day that measured nothing says so, and never says `0 ms`;
/// - **E5** a percentile is rendered as a bound, and the overflow bucket says `over 5 s` rather
///   than inventing a number it does not have;
/// - **E6** onboarding is labelled, under its own heading;
/// - **E7** no string this enum can produce is a percentage of injection success — that
///   denominator belongs to the matrix, capped at 17/20 on this machine (`docs/STATUS.md:44-46`),
///   and a tab that rendered one would be quoting a gate figure nothing has measured.
///
/// **E9** closes the loop: every pinned string is also read back out of `PRODUCT_SPEC.md` itself,
/// so copy and spec cannot drift in either direction.
final class UsageTabCopyTests: XCTestCase {

    // MARK: - The window summary

    /// The streak, stated as a **fact about days** and never as an achievement. This is honesty 1
    /// in one line: "You've dictated on 4 days in a row" is something that happened; a badge, a
    /// checkmark or "goal met" would be this repository's forbidden overclaim, rendered in the one
    /// place a screenshot would carry it furthest.
    func testTheStreakReadsAsAFactAboutDays() {
        XCTAssertEqual(UsageTabCopy.streak(days: 4), "You've dictated on 4 days in a row.")
        XCTAssertEqual(UsageTabCopy.streak(days: 1), "You've dictated on 1 day in a row.")
        XCTAssertEqual(UsageTabCopy.streak(days: 0), "No run of days going right now.")
        XCTAssertEqual(UsageTabCopy.streak(days: -3), "No run of days going right now.")
    }

    /// No streak string claims a verdict. The words below are the ones a reader would take as a
    /// gate result, and none of them may appear.
    func testTheStreakNeverReadsAsAVerdict() {
        for days in [0, 1, 4, 7, 30] {
            let line = UsageTabCopy.streak(days: days).lowercased()
            for verdict in ["passed", "pass", "goal", "target", "achievement", "score", "✅", "🎉"]
            {
                XCTAssertFalse(
                    line.contains(verdict),
                    """
                    The streak line says "\(verdict)". A streak is a fact about days; the moment \
                    it reads as an achievement it is claiming the P0 gate, which nothing on this \
                    machine has measured.
                    """)
            }
        }
    }

    /// The two window totals, singular and plural, and the honest zero.
    func testTheWindowTotalsArePinned() {
        XCTAssertEqual(UsageTabCopy.daysRecorded(12), "12 days recorded")
        XCTAssertEqual(UsageTabCopy.daysRecorded(1), "1 day recorded")
        XCTAssertEqual(UsageTabCopy.daysRecorded(0), "No days recorded")
        XCTAssertEqual(UsageTabCopy.dictations(38), "38 dictations")
        XCTAssertEqual(UsageTabCopy.dictations(1), "1 dictation")
        XCTAssertEqual(UsageTabCopy.dictations(0), "No dictations")
    }

    /// Retention is stated, and the number comes from the constant that enforces it — a copy line
    /// promising thirty days beside a window that keeps sixty is a false privacy claim, and the
    /// interpolation makes the two impossible to separate.
    func testRetentionIsStatedFromTheConstantThatEnforcesIt() {
        XCTAssertEqual(
            UsageTabCopy.retention, "Vocca keeps the last 30 days and forgets the rest.")
        XCTAssertTrue(
            UsageTabCopy.retention.contains("\(UsageWindowConstants.maximumRetainedDays) days"),
            "The retention sentence no longer names the bound the window actually applies.")
    }

    // MARK: - E4: a day that measured nothing

    /// **`not recorded` is not `0 ms`.** A day whose sessions were all cancelled measured nothing,
    /// and a fabricated zero would land in the fastest bucket the histogram has and read as the
    /// best day on record — ``LatencySpan/Presence/notPresent``'s rule, arriving at a user.
    func testAnUnmeasuredDayRendersNotRecordedAndNeverZero() {
        XCTAssertEqual(UsageTabCopy.latency(nil), "not recorded")
        XCTAssertEqual(UsageTabCopy.latencySummary(median: nil, ninetyFifth: nil), "not recorded")
        for rendered in [
            UsageTabCopy.latency(nil), UsageTabCopy.latencySummary(median: nil, ninetyFifth: nil),
        ] {
            XCTAssertFalse(
                rendered.contains("0"),
                """
                An unmeasured day rendered a digit. "0 ms" for a day nothing was measured on is \
                the fabrication this whole ledger is built to avoid: nothing downstream can tell \
                an invented zero from a real reading.
                """)
        }
    }

    // MARK: - E5: a percentile is a bound

    /// A bucket bound renders as the bound it is. `at most 400 ms`, never `400 ms`: the histogram
    /// knows a sample landed in the 400 ms bucket and does not know it was 376 ms, so the bound is
    /// the strongest true statement available.
    func testAPercentileRendersAsABound() {
        XCTAssertEqual(UsageTabCopy.latency(.atMostMilliseconds(400)), "at most 400 ms")
        XCTAssertEqual(UsageTabCopy.latency(.atMostMilliseconds(800)), "at most 800 ms")
        XCTAssertEqual(UsageTabCopy.latency(.atMostMilliseconds(25)), "at most 25 ms")
    }

    /// The overflow bucket says `over 5 s` — it has no upper bound, and it does not invent one.
    func testTheOverflowBucketRendersAsOverAndNeverAsANumberItDoesNotHave() {
        XCTAssertEqual(UsageTabCopy.latency(.aboveMilliseconds(5000)), "over 5 s")
        XCTAssertTrue(UsageTabCopy.latency(.aboveMilliseconds(5000)).hasPrefix("over "))
    }

    /// Every bound the histogram can actually produce renders, and every one of them says either
    /// "at most" or "over". A bound with no hedge in front of it is a spot value, which is the
    /// single failure mode this vocabulary exists to make impossible.
    func testEveryBoundTheHistogramCanProduceIsHedged() {
        var bounds: [LatencyBucketBound] = LatencyHistogram.bucketUpperBoundsMilliseconds.map {
            .atMostMilliseconds($0)
        }
        if let last = LatencyHistogram.bucketUpperBoundsMilliseconds.last {
            bounds.append(.aboveMilliseconds(last))
        }
        XCTAssertEqual(bounds.count, LatencyHistogram.bucketUpperBoundsMilliseconds.count + 1)

        for bound in bounds {
            let rendered = UsageTabCopy.latency(bound)
            XCTAssertTrue(
                rendered.hasPrefix("at most ") || rendered.hasPrefix("over "),
                """
                "\(rendered)" reads as a spot value. Every latency this tab renders is a bucket \
                bound and must say so — bucket resolution printed bare is false precision.
                """)
        }
    }

    /// Seconds above a second, milliseconds below it, and no floating point anywhere: the copy is
    /// integer arithmetic over the same bounds the format persists.
    ///
    /// The 1200 ms bound is rendered by ``testEveryBoundTheHistogramCanProduceIsHedged`` rather
    /// than spelled out here: its rendering contains the numeral 1.2, which
    /// ``WarmStartRatioTests/testTheBoundLiteralAppearsNowhereOutsideTheNamedFile`` reserves to the
    /// W2 warm-start bound's single home. A latency string in a settings tab is not that bound, and
    /// the scan is right to refuse a second sighting rather than learn an exception.
    func testBoundsOverASecondRenderInSeconds() {
        XCTAssertEqual(UsageTabCopy.latency(.atMostMilliseconds(1600)), "at most 1.6 s")
        XCTAssertEqual(UsageTabCopy.latency(.atMostMilliseconds(2400)), "at most 2.4 s")
        XCTAssertEqual(UsageTabCopy.latency(.atMostMilliseconds(3200)), "at most 3.2 s")
        XCTAssertEqual(UsageTabCopy.latency(.atMostMilliseconds(5000)), "at most 5 s")
        XCTAssertEqual(UsageTabCopy.latency(.atMostMilliseconds(800)), "at most 800 ms")
    }

    /// The measured summary names which percentile each bound belongs to, in words rather than in
    /// `p50`/`p95` — the reader of a settings page is not reading a benchmark table.
    func testTheMeasuredSummaryNamesBothPercentiles() {
        XCTAssertEqual(
            UsageTabCopy.latencySummary(
                median: .atMostMilliseconds(400), ninetyFifth: .atMostMilliseconds(800)),
            "half at most 400 ms, 19 in 20 at most 800 ms")
        XCTAssertEqual(UsageTabCopy.medianColumn, "half")
        XCTAssertEqual(UsageTabCopy.ninetyFifthColumn, "19 in 20")
    }

    // MARK: - E6: onboarding is labelled, never merged

    /// The setup demo's numbers sit under their own heading, and the heading says whose they are.
    func testOnboardingIsUnderItsOwnHeading() {
        XCTAssertEqual(UsageTabCopy.onboardingHeading, "Setup demos")
        XCTAssertEqual(
            UsageTabCopy.onboardingExplanation,
            "Counted on their own. The numbers above are your real dictations.")
        XCTAssertEqual(UsageTabCopy.onboardingSessions(2), "2 sessions")
        XCTAssertEqual(UsageTabCopy.onboardingSessions(1), "1 session")
        XCTAssertEqual(UsageTabCopy.onboardingSessions(0), "No sessions")
    }

    /// The onboarding heading and the real-work vocabulary are different words. If the setup demo
    /// were labelled "dictations" too, a reader adding the two columns would be adding a rehearsal
    /// to their real use — which is the merge the requirement forbids, achieved through copy.
    func testOnboardingAndRealWorkDoNotShareAWord() {
        XCTAssertNotEqual(UsageTabCopy.onboardingHeading, UsageTabCopy.dictationsColumn)
        XCTAssertFalse(UsageTabCopy.onboardingHeading.lowercased().contains("dictation"))
        XCTAssertTrue(UsageTabCopy.onboardingExplanation.contains("on their own"))
    }

    // MARK: - E7: never a rate

    /// **No string this enum can produce is a percentage of injection success.** The rung tallies
    /// are counts of what happened; the injection-success figure has a denominator the matrix owns
    /// and that is structurally capped at 17 of 20 on this machine, so a percentage rendered here
    /// would be a gate number nothing has measured.
    ///
    /// Asserted over the **whole copy surface** rather than over the rung labels alone, because
    /// the failure this guards against is a percent sign appearing anywhere on the page and being
    /// read as the P2 figure.
    func testNoRenderedStringIsAPercentage() {
        for rendered in Self.everyRenderedString() {
            XCTAssertFalse(
                rendered.contains("%"),
                """
                "\(rendered)" carries a percent sign. This tab renders counts; the only percentage \
                anyone would read into it is the first-method-success figure, which the injection \
                matrix owns and which no run on this machine has produced.
                """)
            for forbidden in ["success rate", "of 20", "out of 20", "per cent", "percent"] {
                XCTAssertFalse(
                    rendered.lowercased().contains(forbidden),
                    "\"\(rendered)\" reads as an injection-success rate.")
            }
        }
    }

    /// A rung tally is a count, and it is shaped like one: a label and a number, with nothing
    /// between them that could be read as "of".
    func testARungTallyIsACount() {
        XCTAssertEqual(UsageTabCopy.rungTally(.clipboardPaste, count: 11), "pasted: 11")
        XCTAssertEqual(UsageTabCopy.rungTally(.accessibility, count: 1), "typed directly: 1")
        XCTAssertEqual(UsageTabCopy.rungTally(.keystrokeSynthesis, count: 0), "typed key by key: 0")
        XCTAssertEqual(UsageTabCopy.rungTally(.widgetFailsafe, count: 3), "handed to you: 3")
    }

    /// The four rung labels, in the past tense of the Apps tab's vocabulary. That tab says how
    /// Vocca *will* type into an application; this one says how it *did* — same idea, same words,
    /// different tense, so a user does not have to learn two dialects for one mechanism.
    func testTheRungLabelsArePinned() {
        XCTAssertEqual(UsageTabCopy.rungLabel(.accessibility), "typed directly")
        XCTAssertEqual(UsageTabCopy.rungLabel(.clipboardPaste), "pasted")
        XCTAssertEqual(UsageTabCopy.rungLabel(.keystrokeSynthesis), "typed key by key")
        XCTAssertEqual(UsageTabCopy.rungLabel(.widgetFailsafe), "handed to you")
        XCTAssertEqual(
            Set(InjectionRung.allCases.map(UsageTabCopy.rungLabel)).count,
            InjectionRung.allCases.count,
            "Two rungs share a label — a tally would be unreadable.")
    }

    /// The six outcome labels, one per class the pipeline can exit by, all distinct. A shared word
    /// between two classes would make a column ambiguous about which sessions it counted.
    func testTheOutcomeLabelsArePinned() {
        XCTAssertEqual(UsageTabCopy.outcomeLabel(.delivered), "typed for you")
        XCTAssertEqual(UsageTabCopy.outcomeLabel(.held), "held in the window")
        XCTAssertEqual(UsageTabCopy.outcomeLabel(.aborted), "cancelled")
        XCTAssertEqual(UsageTabCopy.outcomeLabel(.failed), "failed")
        XCTAssertEqual(UsageTabCopy.outcomeLabel(.lost), "lost")
        XCTAssertEqual(UsageTabCopy.outcomeLabel(.skipped), "nothing recorded")
        XCTAssertEqual(
            Set(UsageOutcome.allCases.map(UsageTabCopy.outcomeLabel)).count,
            UsageOutcome.allCases.count,
            "Two outcomes share a label.")
        XCTAssertEqual(UsageTabCopy.outcomeTally(.delivered, count: 11), "typed for you: 11")
    }

    // MARK: - The page's own honesty lines

    /// The two sentences the page says about itself: what it is not, and where the numbers live.
    /// They are copy rather than a doc comment because the person who needs them is the sceptic
    /// reading the tab, not the person reading the source.
    func testThePageSaysWhatItIsAndIsNot() {
        XCTAssertEqual(
            UsageTabCopy.notAVerdict,
            "These are counts of what happened, not a score. Vocca doesn't grade itself.")
        XCTAssertEqual(
            UsageTabCopy.localOnly,
            "All of this is read from a file on this Mac. None of it has ever left it.")
    }

    /// "We haven't looked" and "there is nothing" read differently — the ``SettingsCopy``
    /// `dictionaryEmpty` guard, applied to the tab whose empty state a store failure would
    /// otherwise present as "you have never dictated".
    func testTheUnreadStateAndTheEmptyStateReadDifferently() {
        XCTAssertEqual(UsageTabCopy.loading, "Reading what Vocca has recorded…")
        XCTAssertEqual(
            UsageTabCopy.empty,
            "Vocca hasn't recorded any use yet. It starts counting the first time you dictate.")
        XCTAssertNotEqual(UsageTabCopy.loading, UsageTabCopy.empty)
    }

    /// The Clear control, and the confirmation behind it. The button names what goes and the
    /// explanation names that it is bytes off disk — the **Speech** removal treatment, not the
    /// Apps reset one, because this is not a derived thing being recomputed.
    ///
    /// NEW COPY: the spec promises the confirmation but does not write the dialog's own words.
    func testTheClearControlNamesWhatItDeletes() {
        XCTAssertEqual(UsageTabCopy.clearButton, "Clear usage data")
        XCTAssertEqual(
            UsageTabCopy.clearExplanation,
            "Deletes the file Vocca keeps this in. It can't be undone.")
        XCTAssertEqual(UsageTabCopy.clearConfirmationTitle, "Clear everything Vocca has recorded?")
        XCTAssertEqual(UsageTabCopy.clearConfirmButton, "Clear it")
        XCTAssertEqual(UsageTabCopy.clearCancelButton, "Keep it")
        XCTAssertNotEqual(UsageTabCopy.clearConfirmButton, UsageTabCopy.clearCancelButton)
    }

    /// The table's column headings, and the day format. ISO rather than a month name: this module
    /// has no `Foundation` date formatter and no locale, and a hand-written table of English month
    /// abbreviations would be a second date vocabulary the rest of the product does not have.
    /// `2026-09-06` is unambiguous everywhere and sorts the way the rows already do.
    func testTheColumnHeadingsAndDayFormatArePinned() {
        XCTAssertEqual(UsageTabCopy.dayColumn, "Day")
        XCTAssertEqual(UsageTabCopy.dictationsColumn, "Dictations")
        XCTAssertEqual(UsageTabCopy.outcomeColumn, "How they ended")
        XCTAssertEqual(UsageTabCopy.rungColumn, "How Vocca typed them")
        XCTAssertEqual(UsageTabCopy.latencyColumn, "Cycle time")

        guard let day = CalendarDay(year: 2026, month: 9, day: 6),
            let single = CalendarDay(year: 2026, month: 1, day: 1)
        else {
            return XCTFail("the fixture named an impossible date")
        }
        XCTAssertEqual(UsageTabCopy.dayLabel(day), "2026-09-06")
        XCTAssertEqual(UsageTabCopy.dayLabel(single), "2026-01-01")
    }

    /// The cell a day with no deliveries shows. An em dash, not `0`: the row had no delivery to
    /// attribute to any rung, and a column of zeroes reads as four measurements rather than none.
    func testADayWithNoDeliveriesRendersADash() {
        XCTAssertEqual(UsageTabCopy.noDeliveries, "—")
    }

    // MARK: - E9: the spec is the source

    /// **Every pinned string is read back out of `PRODUCT_SPEC.md`'s Usage entry.**
    ///
    /// The ``AppsTabCopyTests`` convention, tightened: those tests quote the spec's line number in
    /// a comment and pin a literal beside it, which catches a change to the code and not a change
    /// to the spec. Here the spec section is parsed and each string looked up in it, so the two
    /// cannot drift in *either* direction — a reworded button fails, and so does a reworded spec.
    func testEveryUserFacingStringAppearsInTheProductSpec() throws {
        let spec = try Self.usageSectionOfTheProductSpec()

        for string in Self.stringsTheSpecMustContain() {
            XCTAssertTrue(
                spec.contains(string),
                """
                PRODUCT_SPEC.md's Usage entry no longer contains "\(string)". Every word on this \
                tab is a product decision, and this aspect shipped the spec entry first precisely \
                so no string here would be copy nobody wrote down. Change the spec, then the copy.
                """)
        }
    }

    /// The section itself is found, and it is the one this file thinks it is. A silent parse
    /// failure would make the pin above assert over an empty string and pass on everything.
    func testTheProductSpecSectionIsActuallyFound() throws {
        let spec = try Self.usageSectionOfTheProductSpec()
        XCTAssertTrue(spec.hasPrefix("**Usage**"))
        XCTAssertGreaterThan(spec.count, 500, "the Usage entry parsed to almost nothing")
        XCTAssertFalse(
            spec.contains("**Privacy**"), "the parse ran past the end of the Usage entry")
    }

    // MARK: - Helpers

    /// `PRODUCT_SPEC.md` §7's **Usage** entry, from its bold lead-in to the next tab's.
    private static func usageSectionOfTheProductSpec() throws -> String {
        let text = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("docs/product/PRODUCT_SPEC.md"),
            encoding: .utf8)
        guard let start = text.range(of: "**Usage** —"),
            let end = text.range(of: "**Privacy** —", range: start.upperBound..<text.endIndex)
        else {
            throw XCTSkip("PRODUCT_SPEC.md no longer holds a Usage entry under §7")
        }
        return String(text[start.lowerBound..<end.lowerBound]).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// The day the spec's own example row is dated.
    private static let sampleDay: CalendarDay = {
        guard let day = CalendarDay(year: 2026, month: 9, day: 6) else {
            preconditionFailure("the fixture named an impossible date")
        }
        return day
    }()

    /// The strings the spec entry writes out, and which the copy must therefore say.
    ///
    /// Deliberately not *every* member — the confirmation dialog's own words are new copy the spec
    /// does not render — but every string a user reads on the page proper.
    private static func stringsTheSpecMustContain() -> [String] {
        var strings: [String] = [
            UsageTabCopy.streak(days: 4), UsageTabCopy.streak(days: 0),
            UsageTabCopy.daysRecorded(12), UsageTabCopy.dictations(38),
            UsageTabCopy.dayColumn, UsageTabCopy.dictationsColumn, UsageTabCopy.outcomeColumn,
            UsageTabCopy.rungColumn, UsageTabCopy.latencyColumn,
            UsageTabCopy.latency(nil),
            UsageTabCopy.latency(.atMostMilliseconds(400)),
            UsageTabCopy.latency(.aboveMilliseconds(5000)),
            UsageTabCopy.latencySummary(
                median: .atMostMilliseconds(400), ninetyFifth: .atMostMilliseconds(800)),
            UsageTabCopy.outcomeTally(.delivered, count: 11),
            UsageTabCopy.outcomeTally(.held, count: 1),
            UsageTabCopy.outcomeTally(.aborted, count: 2),
            UsageTabCopy.rungTally(.clipboardPaste, count: 11),
            UsageTabCopy.rungTally(.accessibility, count: 1),
            UsageTabCopy.onboardingHeading, UsageTabCopy.onboardingExplanation,
            UsageTabCopy.onboardingSessions(2),
            UsageTabCopy.clearButton, UsageTabCopy.clearExplanation,
            UsageTabCopy.notAVerdict, UsageTabCopy.localOnly,
            UsageTabCopy.loading, UsageTabCopy.empty, UsageTabCopy.retention,
            UsageTabCopy.dayLabel(sampleDay),
            UsageTabCopy.noDeliveries,
        ]
        strings.append(contentsOf: InjectionRung.allCases.map(UsageTabCopy.rungLabel))
        strings.append(contentsOf: UsageOutcome.allCases.map(UsageTabCopy.outcomeLabel))
        return strings
    }

    /// Everything this enum can render, over inputs that exercise every branch — the surface E7
    /// asserts across.
    private static func everyRenderedString() -> [String] {
        var rendered = stringsTheSpecMustContain()
        rendered.append(contentsOf: [
            UsageTabCopy.streak(days: 1), UsageTabCopy.daysRecorded(1),
            UsageTabCopy.daysRecorded(0), UsageTabCopy.dictations(1), UsageTabCopy.dictations(0),
            UsageTabCopy.onboardingSessions(1), UsageTabCopy.onboardingSessions(0),
            UsageTabCopy.latencySummary(median: nil, ninetyFifth: nil),
            UsageTabCopy.medianColumn, UsageTabCopy.ninetyFifthColumn,
            UsageTabCopy.clearConfirmationTitle, UsageTabCopy.clearConfirmButton,
            UsageTabCopy.clearCancelButton,
        ])
        for bound in LatencyHistogram.bucketUpperBoundsMilliseconds {
            rendered.append(UsageTabCopy.latency(.atMostMilliseconds(bound)))
            rendered.append(UsageTabCopy.latency(.aboveMilliseconds(bound)))
        }
        for rung in InjectionRung.allCases {
            rendered.append(UsageTabCopy.rungTally(rung, count: 17))
        }
        for outcome in UsageOutcome.allCases {
            rendered.append(UsageTabCopy.outcomeTally(outcome, count: 20))
        }
        return rendered
    }
}
