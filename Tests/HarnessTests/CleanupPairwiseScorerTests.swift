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

import XCTest

/// The pairwise-preference comparator's decision table (spec B1): every blind-answer ×
/// presentation row, the oracle, the percentage arithmetic and the seeded presentation order —
/// the measurement the P1 gate is judged on, pinned before any engine runs against it (the
/// `WERTests` purity shape). The comparator never sees the texts: the judge answers blind, the
/// presentation order carries the blindness, and the verdict maps the blind answer through it —
/// mechanical, not promised.
final class CleanupPairwiseScorerTests: XCTestCase {

    /// The comparator is pure: identical inputs yield identical outcomes, twice over — the
    /// `WERTests` purity shape, and the property determinism claims rest on.
    func testIdenticalInputsYieldIdenticalOutcomes() {
        let answers: [BlindJudgeAnswer] = [.left, .right, .tie, .noPreference]
        let presentations: [PairPresentation] = [.rawFirst, .cleanedFirst]
        for answer in answers {
            for presentation in presentations {
                let first = CleanupPairwiseScorer.verdict(
                    judgeAnswer: answer, presentation: presentation)
                let second = CleanupPairwiseScorer.verdict(
                    judgeAnswer: answer, presentation: presentation)
                XCTAssertEqual(
                    first, second, "\(answer) × \(presentation) must be deterministic")
            }
        }
        let oracleInputs = [
            ("raw text", "produced text", "golden"),
            ("golden", "produced text", "golden"),
            ("golden", "golden", "golden"),
        ]
        for (raw, produced, golden) in oracleInputs {
            XCTAssertEqual(
                CleanupPairwiseScorer.oracleVerdict(raw: raw, produced: produced, golden: golden),
                CleanupPairwiseScorer.oracleVerdict(raw: raw, produced: produced, golden: golden))
        }
    }

    /// Every one of the four verdicts is reachable from a blind answer — the judge's vocabulary
    /// is complete, and nothing maps into a hole.
    func testAllFourVerdictsAreReachableFromTheBlindAnswer() {
        let table: [(BlindJudgeAnswer, PairPresentation, PairwisePreference)] = [
            (.left, .rawFirst, .rawPreferred),
            (.right, .rawFirst, .cleanedPreferred),
            (.right, .cleanedFirst, .rawPreferred),
            (.left, .cleanedFirst, .cleanedPreferred),
            (.tie, .rawFirst, .tie),
            (.tie, .cleanedFirst, .tie),
            (.noPreference, .rawFirst, .noPreference),
            (.noPreference, .cleanedFirst, .noPreference),
        ]
        for (answer, presentation, expected) in table {
            XCTAssertEqual(
                CleanupPairwiseScorer.verdict(
                    judgeAnswer: answer, presentation: presentation),
                expected, "\(answer) × \(presentation) must map to \(expected)")
        }
    }

    /// The same blind answer under `rawFirst` vs `cleanedFirst` maps to the mirror verdict —
    /// presentation order is provably inert, which is what makes "blind" mechanical rather
    /// than a promise.
    func testTheLabelOrderCannotInfluenceTheOutcome() {
        XCTAssertEqual(
            CleanupPairwiseScorer.verdict(judgeAnswer: .left, presentation: .rawFirst),
            .rawPreferred)
        XCTAssertEqual(
            CleanupPairwiseScorer.verdict(judgeAnswer: .left, presentation: .cleanedFirst),
            .cleanedPreferred)
        XCTAssertEqual(
            CleanupPairwiseScorer.verdict(judgeAnswer: .right, presentation: .rawFirst),
            .cleanedPreferred)
        XCTAssertEqual(
            CleanupPairwiseScorer.verdict(judgeAnswer: .right, presentation: .cleanedFirst),
            .rawPreferred)
        XCTAssertEqual(
            CleanupPairwiseScorer.verdict(judgeAnswer: .tie, presentation: .rawFirst),
            .tie)
        XCTAssertEqual(
            CleanupPairwiseScorer.verdict(judgeAnswer: .tie, presentation: .cleanedFirst),
            .tie)
        XCTAssertEqual(
            CleanupPairwiseScorer.verdict(judgeAnswer: .noPreference, presentation: .rawFirst),
            .noPreference)
        XCTAssertEqual(
            CleanupPairwiseScorer.verdict(judgeAnswer: .noPreference, presentation: .cleanedFirst),
            .noPreference)
    }

    /// The CI judge's own table: prefer the side equal to the pair's golden clean target; both
    /// or neither ⇒ `noPreference` (spec B1 — the oracle never fabricates a preference).
    func testTheOraclePrefersTheSideEqualToTheGolden() {
        let golden = "Twelve people came to the meeting."
        XCTAssertEqual(
            CleanupPairwiseScorer.oracleVerdict(
                raw: "um twelve people came to the meeting", produced: golden, golden: golden),
            .cleanedPreferred, "produced == golden only ⇒ cleanedPreferred")
        XCTAssertEqual(
            CleanupPairwiseScorer.oracleVerdict(
                raw: golden, produced: "12 people came to the meeting.", golden: golden),
            .rawPreferred, "raw == golden only ⇒ rawPreferred")
        XCTAssertEqual(
            CleanupPairwiseScorer.oracleVerdict(raw: golden, produced: golden, golden: golden),
            .noPreference, "both sides equal the golden ⇒ noPreference, never a fabricated verdict")
        XCTAssertEqual(
            CleanupPairwiseScorer.oracleVerdict(
                raw: "raw", produced: "produced", golden: golden),
            .noPreference, "neither side equals the golden ⇒ noPreference")
    }

    /// The percentage arithmetic is exact: 3 of 4 preferred ⇒ 0.75 — the number the P1 gate is
    /// judged on, pinned before any engine runs against it.
    func testPercentageArithmeticIsExact() throws {
        let verdicts = [
            PairVerdict(name: "a", preference: .cleanedPreferred, className: .fillers),
            PairVerdict(name: "b", preference: .cleanedPreferred, className: .fillers),
            PairVerdict(name: "c", preference: .cleanedPreferred, className: .fillers),
            PairVerdict(name: "d", preference: .rawPreferred, className: .fillers),
        ]
        XCTAssertEqual(try CleanupPairwiseScorer.preferencePercentage(verdicts), 0.75)
    }

    /// `tie` and `noPreference` rows are excluded from the denominator — the percentage is over
    /// pairs *with* a preference (spec §2.4, re-openable only at the F2 re-baseline).
    func testTiesAreExcludedFromTheDenominator() throws {
        let verdicts = [
            PairVerdict(name: "a", preference: .cleanedPreferred, className: .fillers),
            PairVerdict(name: "b", preference: .tie, className: .fillers),
            PairVerdict(name: "c", preference: .noPreference, className: .fillers),
            PairVerdict(name: "d", preference: .rawPreferred, className: .fillers),
            PairVerdict(name: "e", preference: .cleanedPreferred, className: .fillers),
        ]
        XCTAssertEqual(try CleanupPairwiseScorer.preferencePercentage(verdicts), 2.0 / 3.0)
    }

    /// An all-tie or all-no-preference run throws the named `noPreferenceSample` error — never
    /// a divide-by-zero, never a fabricated green.
    func testAnAllTieOrAllNoPreferenceRunThrowsTheNamedError() {
        let allTies = [PairVerdict(name: "a", preference: .tie, className: .fillers)]
        XCTAssertThrowsError(try CleanupPairwiseScorer.preferencePercentage(allTies)) { error in
            XCTAssertEqual(error as? CleanupPairwiseScorerError, .noPreferenceSample)
        }
        let allNoPreference = [
            PairVerdict(name: "a", preference: .noPreference, className: .fillers)
        ]
        XCTAssertThrowsError(
            try CleanupPairwiseScorer.preferencePercentage(allNoPreference)
        ) { error in
            XCTAssertEqual(error as? CleanupPairwiseScorerError, .noPreferenceSample)
        }
    }

    /// Percentage over zero pairs throws the same named error — the WER empty-reference rule:
    /// the degenerate case is defined, not a crash.
    func testTheEmptyCorpusRule() {
        XCTAssertThrowsError(try CleanupPairwiseScorer.preferencePercentage([])) { error in
            XCTAssertEqual(error as? CleanupPairwiseScorerError, .noPreferenceSample)
        }
    }

    /// The seeded presentation order is deterministic — and the blindness mechanism's
    /// determinism: the same seed presents the same order, a different seed presents a
    /// different one, and the seeded order is never the checked-in order (a fixed order would
    /// let a judge pattern-match, spec `spec.md:205-207`).
    func testTheSeededPresentationOrderIsDeterministic() {
        let names = (0..<24).map { "pair-\($0)" }
        let firstRun = CleanupPairwiseScorer.presentedOrder(names, seed: 0x5EED_C0DE)
        let secondRun = CleanupPairwiseScorer.presentedOrder(names, seed: 0x5EED_C0DE)
        XCTAssertEqual(firstRun, secondRun, "the same seed must produce the same order")
        XCTAssertEqual(
            firstRun.sorted(), names.sorted(),
            "the shuffle is a permutation — nothing lost, nothing invented")
        XCTAssertFalse(
            firstRun == names,
            "the seeded order must differ from the checked-in order — blindness is mechanical, "
                + "not assumed")
        let otherSeed = CleanupPairwiseScorer.presentedOrder(names, seed: 0x5EED_CAFE)
        XCTAssertNotEqual(
            firstRun, otherSeed, "a different seed must produce a different order")
    }
}
