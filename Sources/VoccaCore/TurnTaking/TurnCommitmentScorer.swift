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

/// The conversational-set scorer (G4/R8, `ROADMAP.md:211`, `ARCHITECTURE.md:575`): false
/// cutoffs weighted **5× worse** than late commits, and **≥95% correct turn commitment**
/// on the recorded conversational set — a pure, stdlib-only function the CI harness runs
/// over the scripted corpus (`Tests/HarnessTests/Fixtures/Conversational/`).
///
/// ## The pinned formula
///
/// `weightedErrorCount = 5·falseCutoffs + 2·missedCommits + 1·lateCommits`;
/// `weightedScore = 1 − weightedErrorCount / (weightedErrorCount + correctCount)`;
/// `passThreshold = 0.95`, **inclusive** (`weightedScore ≥ 0.95` passes).
///
/// The weights are the risk ranking, not taste: a false cutoff cuts the user off
/// mid-sentence (R6's "cut me off" failure — High/High), a missed commit stalls the
/// conversation, and a late commit only costs latency. The arithmetic's three
/// demonstrations are pinned in `TurnCommitmentHarnessTests`:
///
/// - **1 false cutoff in 20 → 1 − 5/24 ≈ 0.792 — fails** (the planted corpus's shape);
/// - **1 late commit in 20 → exactly 0.95 — passes** (the 5× asymmetry, at the bar by
///   design);
/// - **1 missed commit in 20 → 1 − 2/21 ≈ 0.905 — fails** (a turn nobody commits stalls the
///   conversation — worse than late, less catastrophic than a cutoff).
///
/// `score(_:)` **throws on an empty corpus** — "a harness that cannot measure must never
/// read green" (the `CleanupPairwiseScorerError.noPreferenceSample` precedent).
public enum TurnCommitmentScorer {
    /// The inclusive pass bar: `weightedScore ≥ 0.95` passes.
    public static let passThreshold: Double = 0.95

    /// Classifies one labelled boundary's commit against its expected instant, with the
    /// loop's own commit latency (the detector's `commitAfterPause`) already added to the
    /// boundary by the harness.
    ///
    /// - `nil` (no commit ever landed for this boundary) → `.missedCommit`.
    /// - `commitAt < expected − tolerance` → `.falseCutoff` (the loop cut the speaker off).
    /// - `commitAt ≤ expected + tolerance` → `.correct` (the tolerance absorbs the
    ///   detector's own frame-quantized latency).
    /// - otherwise → `.lateCommit`.
    public static func classify(
        commitAt: Duration?, expectedCommitAt: Duration, tolerance: Duration = .milliseconds(100)
    ) -> TurnCommitmentClass {
        guard let commitAt else { return .missedCommit }
        if commitAt < expectedCommitAt - tolerance { return .falseCutoff }
        if commitAt <= expectedCommitAt + tolerance { return .correct }
        return .lateCommit
    }

    /// Scores a corpus run: the weighted error count and the weighted score under the
    /// pinned formula. Throws ``TurnCommitmentScorerError/emptyCorpus`` when there is
    /// nothing to score.
    public static func score(_ classes: [TurnCommitmentClass]) throws -> TurnCommitmentScore {
        guard !classes.isEmpty else { throw TurnCommitmentScorerError.emptyCorpus }

        let falseCutoffs = classes.filter { $0 == .falseCutoff }.count
        let missedCommits = classes.filter { $0 == .missedCommit }.count
        let lateCommits = classes.filter { $0 == .lateCommit }.count
        let correct = classes.filter { $0 == .correct }.count

        let weightedErrorCount = 5 * falseCutoffs + 2 * missedCommits + lateCommits
        let denominator = weightedErrorCount + correct
        let weightedScore = 1 - Double(weightedErrorCount) / Double(denominator)
        return TurnCommitmentScore(
            classes: classes, weightedErrorCount: weightedErrorCount, weightedScore: weightedScore)
    }
}

/// What went wrong (or right) for one labelled boundary.
public enum TurnCommitmentClass: Sendable, Equatable {
    /// The commit landed within the tolerance of the labelled turn end.
    case correct

    /// The loop committed the turn before the speaker was done — the 5×-weighted failure.
    case falseCutoff

    /// The loop committed later than the tolerance — only latency, weighed once.
    case lateCommit

    /// No commit ever landed for this boundary — the turn stalled.
    case missedCommit
}

/// One corpus run's verdict: the per-boundary classes, the weighted error count and the
/// weighted score.
public struct TurnCommitmentScore: Sendable, Equatable {
    /// Every labelled boundary's classification, in corpus order.
    public let classes: [TurnCommitmentClass]

    /// `5·falseCutoffs + 2·missedCommits + 1·lateCommits`.
    public let weightedErrorCount: Int

    /// `1 − weightedErrorCount / (weightedErrorCount + correctCount)`.
    public let weightedScore: Double

    public init(
        classes: [TurnCommitmentClass], weightedErrorCount: Int, weightedScore: Double
    ) {
        self.classes = classes
        self.weightedErrorCount = weightedErrorCount
        self.weightedScore = weightedScore
    }
}

/// The scorer's refusal: an empty corpus cannot be measured, and a harness that cannot
/// measure must never read green.
public enum TurnCommitmentScorerError: Error, Equatable, CustomStringConvertible {
    case emptyCorpus

    public var description: String {
        "an empty corpus cannot be scored — a harness that cannot measure must never read green"
    }
}