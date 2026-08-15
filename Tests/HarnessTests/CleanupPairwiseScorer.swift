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

/// The per-pair class tag (`eval-harness/spec.md:24-36`): the corpus's six rule classes, so a
/// run can print a per-class breakdown. The raw values are exactly the tag words the on-disk
/// `<name>.class.txt` sidecar carries.
///
/// Defined here rather than in ``CleanupPairSuite`` because ``PairVerdict`` — the scorer's
/// outcome row — carries it, and the scorer is the first type to need it; the loader consumes
/// the same definition (a class is one type in this suite, not one per file).
enum CleanupPairClass: String, Sendable, CaseIterable {
    case fillers
    case punctuation
    case capitalization
    case numbersUnits = "numbers-units"
    case dictionary
    case tokenProtection = "token-protection"
}

/// Which side the runner presented first for one pair — the carrier of the blindness: the
/// judge answers `left`/`right` and never sees labels, and the presentation maps the answer to
/// a verdict.
enum PairPresentation: Sendable, Equatable {
    case rawFirst
    case cleanedFirst
}

/// A blind judge's answer for one pair: `left`/`right` are the presented sides, `tie` and
/// `noPreference` are the no-preference vocabulary (both excluded from the percentage's
/// denominator, `spec.md:42-43`).
enum BlindJudgeAnswer: Sendable, Equatable {
    case left
    case right
    case tie
    case noPreference
}

/// The comparator's outcome vocabulary — the four verdicts the P1 gate's percentage is
/// computed over.
enum PairwisePreference: Sendable, Equatable {
    case cleanedPreferred
    case rawPreferred
    case tie
    case noPreference
}

/// One pair's scored outcome: which pair, which verdict, and which class it belongs to — the
/// row the per-class tallies and the preference percentage are computed from.
struct PairVerdict: Sendable, Equatable {
    let name: String
    let preference: PairwisePreference
    let className: CleanupPairClass
}

/// Why a pairwise-preference computation failed, named.
enum CleanupPairwiseScorerError: Error, Equatable, CustomStringConvertible {
    /// No pair in the sample has a preference (all `tie`, all `noPreference`, or an empty
    /// corpus) — the percentage is undefined, and a harness that cannot measure must never
    /// read green.
    case noPreferenceSample

    var description: String {
        switch self {
        case .noPreferenceSample:
            return "no pair in the sample has a preference (all tie / all noPreference / "
                + "empty) — the preference percentage is undefined; a harness that cannot "
                + "measure must never read green"
        }
    }
}

/// The deterministic blind pairwise-preference comparator (`eval-harness/spec.md:37-46`) — the
/// measurement the P1 gate is judged on, pinned before any engine runs against it (the
/// `WERTests` framing).
///
/// **Blind by construction:** the comparator never receives the texts. The judge answers over
/// presented sides (`left`/`right`/`tie`/`noPreference`), ``presentedOrder(_:seed:)`` randomizes
/// the presentation under a printed seed, and ``verdict(judgeAnswer:presentation:)`` maps the
/// blind answer through the presentation order into the labelled verdict — the mapping makes
/// "blind" mechanical rather than a promise, and the seed makes the presentation reproducible.
///
/// Pure stdlib, no IO, no clock, no randomness outside the injected seed: identical inputs
/// yield identical outcomes, byte for byte, on every machine.
enum CleanupPairwiseScorer {

    /// The CI judge: prefer the side equal to the pair's golden clean target; both or neither
    /// ⇒ `noPreference` — the oracle never fabricates a preference (`ROADMAP.md:132`).
    static func oracleVerdict(raw: String, produced: String, golden: String) -> PairwisePreference {
        switch (raw == golden, produced == golden) {
        case (true, false): return .rawPreferred
        case (false, true): return .cleanedPreferred
        default: return .noPreference
        }
    }

    /// Maps a blind answer through the presentation order into the labelled verdict.
    ///
    /// The mirror rows are the whole of the mapping: the same blind answer under `rawFirst` vs
    /// `cleanedFirst` lands on the mirror verdict, so the presentation cannot influence the
    /// outcome (B1 — the label-order row).
    static func verdict(judgeAnswer: BlindJudgeAnswer, presentation: PairPresentation) -> PairwisePreference {
        switch judgeAnswer {
        case .tie:
            return .tie
        case .noPreference:
            return .noPreference
        case .left:
            return presentation == .rawFirst ? .rawPreferred : .cleanedPreferred
        case .right:
            return presentation == .rawFirst ? .cleanedPreferred : .rawPreferred
        }
    }

    /// The aggregate the P1 gate is judged on: `cleanedPreferred ÷ (pairs with a preference)` —
    /// `tie` and `noPreference` rows are excluded from the denominator (`spec.md:42-43`, the
    /// choice re-openable only at the F2 re-baseline). A run with nothing preferred — or
    /// nothing at all — throws ``CleanupPairwiseScorerError/noPreferenceSample`` rather than
    /// dividing by zero.
    static func preferencePercentage(_ verdicts: [PairVerdict]) throws -> Double {
        let cleanedPreferred = verdicts.filter { $0.preference == .cleanedPreferred }.count
        let withPreference =
            verdicts.filter {
                $0.preference == .cleanedPreferred || $0.preference == .rawPreferred
            }.count
        guard withPreference > 0 else {
            throw CleanupPairwiseScorerError.noPreferenceSample
        }
        return Double(cleanedPreferred) / Double(withPreference)
    }

    /// The presentation order for a ballot, seeded and deterministic: Fisher-Yates over the
    /// suite's shared ``SeededGenerator``, so the same seed presents the same order and the
    /// seed printed beside the verdicts makes the ballot reproducible (`spec.md:205-207` — a
    /// checked-in fixed order would let a judge pattern-match).
    static func presentedOrder(_ names: [String], seed: UInt64) -> [String] {
        var generator = SeededGenerator(seed: seed)
        var result = names
        guard result.count > 1 else { return result }
        for i in stride(from: result.count - 1, through: 1, by: -1) {
            let j = Int(generator.next() % UInt64(i + 1))
            result.swapAt(i, j)
        }
        return result
    }
}
