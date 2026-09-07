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

/// The Usage tab's strings, kept out of the views so they can be read without a window server —
/// the ``SettingsCopy``/``AppsTabCopy`` shape. Every one of them is written in `PRODUCT_SPEC.md`
/// §7's **Usage** entry, and ``UsageTabCopyTests`` reads that section back out of the file rather
/// than trusting a literal beside a line number.
///
/// **This enum is where four of the aspect's five honesty requirements actually land**, because a
/// requirement a user never reads is a requirement nobody is holding:
///
/// - a latency is a **bound** (`at most 400 ms`), never a spot value, and the overflow bucket says
///   `over 5 s` rather than inventing a number the histogram does not have;
/// - a day that measured nothing says `not recorded`, and there is deliberately no code path here
///   that can produce `0 ms`;
/// - a rung tally is a **count** with a label and a colon, and nothing in this file divides — the
///   injection-success percentage has a denominator the matrix owns, capped at 17 of 20 on this
///   machine (`docs/STATUS.md:44-46`);
/// - onboarding gets its own heading and its own noun, so nobody can add two columns and believe
///   the sum is their real use.
///
/// The fifth — never a gate verdict — is the absence of a word: no badge, no checkmark, no
/// "passed". A streak is written as something that happened, and ``notAVerdict`` says so out loud.
public enum UsageTabCopy {

    // MARK: - The window summary

    /// The streak, as a **fact about days**.
    ///
    /// "You've dictated on 4 days in a row" is something that happened. The same number rendered
    /// as a badge, a flame or "goal met" would be an achievement, and an achievement on this page
    /// reads as the P0 daily-use gate — which nothing on this machine has measured. That is the
    /// whole distinction the aspect's first honesty requirement draws, and it is drawn here, in
    /// the mood of a sentence.
    ///
    /// A run of nothing says so plainly rather than exhorting. "Start your streak today!" would be
    /// a product nagging a user about a number it collected on itself.
    public static func streak(days: Int) -> String {
        switch days {
        case ..<1: return "No run of days going right now."
        case 1: return "You've dictated on 1 day in a row."
        default: return "You've dictated on \(days) days in a row."
        }
    }

    /// How many days the ledger holds. Days recorded, not days used: a day is here because a
    /// session was folded into it, which includes a day of nothing but cancellations.
    public static func daysRecorded(_ count: Int) -> String {
        switch count {
        case ..<1: return "No days recorded"
        case 1: return "1 day recorded"
        default: return "\(count) days recorded"
        }
    }

    /// The window's real dictations — sessions in which a transcript existed. Never the setup
    /// demo's, which has ``onboardingSessions(_:)`` and a heading of its own.
    public static func dictations(_ count: Int) -> String {
        switch count {
        case ..<1: return "No dictations"
        case 1: return "1 dictation"
        default: return "\(count) dictations"
        }
    }

    /// What the ledger keeps, and for how long — with the number interpolated from the constant
    /// that enforces it, so the sentence cannot go on promising thirty days while the window keeps
    /// sixty. On a page whose job is disclosure, a stale retention claim is the worst kind of
    /// stale string.
    public static let retention =
        "Vocca keeps the last \(UsageWindowConstants.maximumRetainedDays) days "
        + "and forgets the rest."

    // MARK: - Latency, as a bound and never a number

    /// What a day with no samples says. **Not `0 ms`** — ``LatencySpan/Presence/notPresent``'s
    /// rule, arriving at a user: a fabricated zero would land in the fastest bucket the histogram
    /// has and read as the best day on record, and nothing downstream could tell it from a real
    /// reading.
    public static let notRecorded = "not recorded"

    /// One percentile, rendered as the bound it is.
    ///
    /// `nil` is the day that measured nothing. Everything else is hedged: `at most 400 ms` for a
    /// bucket with an upper bound, `over 5 s` for the overflow bucket, which has none and does not
    /// pretend to. The histogram knows a sample landed in the 400 ms bucket; it does not know it
    /// was 376 ms, and printing that would be an invention.
    public static func latency(_ bound: LatencyBucketBound?) -> String {
        switch bound {
        case .none: return notRecorded
        case .atMostMilliseconds(let milliseconds): return "at most \(duration(milliseconds))"
        case .aboveMilliseconds(let milliseconds): return "over \(duration(milliseconds))"
        }
    }

    /// The day's cycle time in one cell: both percentiles, each hedged, named in words rather than
    /// in `p50`/`p95` — a settings page is not a benchmark table.
    ///
    /// Either bound being absent means the day measured nothing at all (a histogram with no
    /// samples has no percentile of any rank), so the whole cell reads ``notRecorded`` rather than
    /// half a summary.
    public static func latencySummary(
        median: LatencyBucketBound?, ninetyFifth: LatencyBucketBound?
    ) -> String {
        guard let median, let ninetyFifth else { return notRecorded }
        return "\(medianColumn) \(latency(median)), \(ninetyFifthColumn) \(latency(ninetyFifth))"
    }

    /// What "the 50th percentile" is called in front of a person.
    public static let medianColumn = "half"

    /// And the 95th. "19 in 20" rather than "95%", because a percent sign anywhere on this page is
    /// the thing a reader will mistake for the injection-success figure.
    public static let ninetyFifthColumn = "19 in 20"

    // MARK: - Outcomes and rungs, as counts

    /// What a session ending that way is called. The six classes the pipeline can exit by, in a
    /// user's words rather than the machine's: nobody outside this repository knows what
    /// `emptySkip` is.
    public static func outcomeLabel(_ outcome: UsageOutcome) -> String {
        switch outcome {
        case .delivered: return "typed for you"
        case .held: return "held in the window"
        case .aborted: return "cancelled"
        case .failed: return "failed"
        case .lost: return "lost"
        case .skipped: return "nothing recorded"
        }
    }

    /// One outcome and its tally. Label, colon, number — the shape of a count, with nothing in it
    /// that could be read as "out of".
    public static func outcomeTally(_ outcome: UsageOutcome, count: Int) -> String {
        "\(outcomeLabel(outcome)): \(count)"
    }

    /// How the text arrived, per rung — the **past tense** of the Apps tab's health vocabulary
    /// (``AppsTabCopy/healthLabel(_:)``). That tab says how Vocca *will* type into an application;
    /// this one says how it *did*. One idea, one set of words, two tenses, so a user is not handed
    /// two dialects for the same mechanism.
    ///
    /// Unlike the health column these are four labels and not three: the health column collapses
    /// keystroke synthesis and the failsafe into "manual only" because it is answering *what will
    /// happen*, while a tally is reporting *what did*, and the two are different events.
    public static func rungLabel(_ rung: InjectionRung) -> String {
        switch rung {
        case .accessibility: return "typed directly"
        case .clipboardPaste: return "pasted"
        case .keystrokeSynthesis: return "typed key by key"
        case .widgetFailsafe: return "handed to you"
        }
    }

    /// One rung and its tally — **a count of deliveries, and never a share of them**.
    ///
    /// The number after the colon is how many dictations that rung carried. It is not a rate, and
    /// this page renders no denominator it could be divided by: the first-method-success figure
    /// belongs to the injection matrix, whose ceiling on this machine is 17 of 20 and whose runs
    /// have never produced a quotable percentage (`docs/STATUS.md:44-46`). A tally rendered as
    /// "82%" here would be a gate number nothing has measured, in the one place a screenshot would
    /// carry it furthest.
    public static func rungTally(_ rung: InjectionRung, count: Int) -> String {
        "\(rungLabel(rung)): \(count)"
    }

    /// The cell for a day whose real work delivered nothing. An em dash rather than four zeroes: a
    /// column of `0`s reads as four measurements, and there were none.
    public static let noDeliveries = "—"

    // MARK: - Onboarding, labelled and apart

    /// The setup demo's own heading. Deliberately shares no word with ``dictationsColumn``: if the
    /// rehearsal were also called "dictations", a reader adding the two columns would be adding a
    /// demo to their real use, which is the merge the requirement forbids — achieved in copy
    /// rather than only in the type.
    public static let onboardingHeading = "Setup demos"

    /// Why it has its own heading, said rather than implied.
    public static let onboardingExplanation =
        "Counted on their own. The numbers above are your real dictations."

    /// How many setup sessions the window holds. "Sessions", not "dictations".
    public static func onboardingSessions(_ count: Int) -> String {
        switch count {
        case ..<1: return "No sessions"
        case 1: return "1 session"
        default: return "\(count) sessions"
        }
    }

    // MARK: - What the page says about itself

    /// **The page is not a scorecard**, and says so. The sentence is copy rather than a doc
    /// comment because the person who needs it is the sceptic reading the tab, not the person
    /// reading this file.
    public static let notAVerdict =
        "These are counts of what happened, not a score. Vocca doesn't grade itself."

    /// The disclosure the whole tab exists to make checkable (`PRODUCT_SPEC.md` §12: *"No usage
    /// analytics. Metrics are local and inspectable"*). The claim is only worth anything on the
    /// screen that lets a user look, which is this one.
    public static let localOnly =
        "All of this is read from a file on this Mac. None of it has ever left it."

    /// Before the file has been read. Distinct from ``empty`` on purpose: a store that failed to
    /// load must never present itself as "you have never dictated" to a user who dictates daily.
    public static let loading = "Reading what Vocca has recorded…"

    /// Read, and holding nothing — honest about *why* it is empty rather than reading like a
    /// fault, the ``AppsTabCopy/empty`` treatment.
    public static let empty =
        "Vocca hasn't recorded any use yet. It starts counting the first time you dictate."

    // MARK: - The Clear control

    /// The button. Names what goes, not what happens to a screen.
    public static let clearButton = "Clear usage data"

    /// What it does, and the part that earns the confirmation: this deletes bytes rather than
    /// resetting something derived, so it is the **Speech** removal treatment and not the Apps
    /// reset one.
    public static let clearExplanation =
        "Deletes the file Vocca keeps this in. It can't be undone."

    /// The confirmation's question. Asks about everything, because that is what goes.
    public static let clearConfirmationTitle = "Clear everything Vocca has recorded?"

    /// The destructive choice.
    public static let clearConfirmButton = "Clear it"

    /// The way out, phrased as the outcome rather than as "Cancel" — at a dialog a user reads two
    /// buttons and picks the one describing what they want to be true afterwards.
    public static let clearCancelButton = "Keep it"

    // MARK: - The table's own words

    /// The day column's heading.
    public static let dayColumn = "Day"
    /// The count of dictations — real work only.
    public static let dictationsColumn = "Dictations"
    /// The six-class breakdown's heading.
    public static let outcomeColumn = "How they ended"
    /// The rung tallies' heading — the Apps tab's question, in the past tense.
    public static let rungColumn = "How Vocca typed them"
    /// The latency column's heading.
    public static let latencyColumn = "Cycle time"

    /// A day, as `2026-09-06`.
    ///
    /// ISO rather than "6 Sep 2026" for two reasons that both come down to not inventing anything:
    /// this module has no `Foundation` date formatter and no locale to ask, and a hand-written
    /// table of English month abbreviations would be a second date vocabulary the rest of the
    /// product does not have. `2026-09-06` is unambiguous in every locale and sorts the way the
    /// rows already do.
    public static func dayLabel(_ day: CalendarDay) -> String {
        "\(padded(day.year, width: 4))-\(padded(day.month, width: 2))-\(padded(day.day, width: 2))"
    }

    // MARK: - Formatting

    /// A bound in milliseconds, as a person reads a duration: milliseconds under a second, seconds
    /// above it, at one decimal place and no more.
    ///
    /// Integer arithmetic throughout, and no `Foundation`. That is not asceticism: the bounds are
    /// the persisted format (``LatencyHistogram/bucketUpperBoundsMilliseconds``), every one of
    /// them is a whole hundred milliseconds at or above a second, and a formatter that rounded
    /// would be a second opinion about a number this file is only supposed to be transcribing.
    private static func duration(_ milliseconds: Int) -> String {
        guard milliseconds >= 1000 else { return "\(milliseconds) ms" }
        let seconds = milliseconds / 1000
        let tenths = (milliseconds % 1000) / 100
        return tenths == 0 ? "\(seconds) s" : "\(seconds).\(tenths) s"
    }

    /// `value` left-padded with zeroes to `width`. Negative years cannot reach here from the
    /// ledger, and are rendered as themselves rather than mangled into a padded absurdity.
    private static func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        guard !digits.hasPrefix("-"), digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}
