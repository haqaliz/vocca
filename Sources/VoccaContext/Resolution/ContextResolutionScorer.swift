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

/// The context-resolution scorer (S1, `prd.md:127-130`): **≥95% correct resolution** of the
/// active application and selection on the recorded corpus — a pure, stdlib-only function the
/// CI harness runs over the scripted corpus
/// (`Tests/HarnessTests/Fixtures/ContextResolution/`).
///
/// ## The pinned formula
///
/// `percentage = correctCount / totalCount`; `passThreshold = 0.95`, **inclusive**
/// (`percentage ≥ 0.95` passes).
///
/// Resolution is **bundle ID + selected text match** — the window title is carried for the
/// failsafe copy's "{app}" vocabulary and is **not scored** (D5): titles vary with focus, and
/// only the app identity and the selection are decisions. The arithmetic's three demonstrations
/// are pinned in `ContextResolutionHarnessTests`:
///
/// - **22/22 → 1.0000 — passes** (the passing corpus's shape: the matrix's rows, all correct);
/// - **21/22 ≈ 0.9545 — passes**, at the bar by design (the honest boundary);
/// - **20/22 ≈ 0.909 — fails loudly** (the planted corpus's shape: 2 misresolutions in 22 —
///   1 miss in 22 = 21/22 ≈ 0.9545 ≥ 0.95 passes at the bar by design; 2 misses in 22 ≈ 0.909
///   fails).
///
/// The corpus's rows are `Scripts/injection-matrix.sh` `ROWS` (22 rows), so the CI harness and
/// the founder's real run measure the same shape.
///
/// `score(_:)` **throws on an empty corpus** — "a harness that cannot measure must never read
/// green" (the `TurnCommitmentScorerError.emptyCorpus` precedent).
public enum ContextResolutionScorer {
    /// The inclusive pass bar: `percentage ≥ 0.95` passes.
    public static let passThreshold: Double = 0.95

    /// Classifies one resolution against its expected answer.
    ///
    /// - Bundle ID **and** selected text both match → `.correct`.
    /// - Either differs (including an absent bundle ID or selection) → `.misresolved`.
    /// - The window title is not consulted.
    public static func classify(
        bundleID: String?,
        selectedText: String?,
        expectedBundleID: String,
        expectedSelectedText: String
    ) -> ContextResolutionClass {
        if bundleID == expectedBundleID && selectedText == expectedSelectedText {
            return .correct
        }
        return .misresolved
    }

    /// Scores a corpus run: the correct count, the total, and the percentage. Throws
    /// ``ContextResolutionScorerError/emptyCorpus`` when there is nothing to score.
    public static func score(_ classes: [ContextResolutionClass]) throws -> ContextResolutionScore {
        guard !classes.isEmpty else { throw ContextResolutionScorerError.emptyCorpus }

        let correct = classes.filter { $0 == .correct }.count
        return ContextResolutionScore(
            classes: classes,
            correctCount: correct,
            totalCount: classes.count,
            percentage: Double(correct) / Double(classes.count))
    }
}

/// What went right (or wrong) for one resolution.
public enum ContextResolutionClass: Sendable, Equatable {
    /// The adapter's bundle ID and selected text both matched the row's expected answer.
    case correct

    /// The bundle ID or the selected text differed — a wrong app identified, or a wrong
    /// selection reported.
    case misresolved
}

/// One corpus run's verdict: the per-row classifications, the correct count, the total, the
/// percentage, and whether it clears the inclusive bar.
public struct ContextResolutionScore: Sendable, Equatable {
    /// Every row's classification, in corpus order.
    public let classes: [ContextResolutionClass]

    /// The number of `.correct` rows.
    public let correctCount: Int

    /// The corpus's row count — the denominator.
    public let totalCount: Int

    /// `correctCount / totalCount`.
    public let percentage: Double

    /// `percentage ≥ ContextResolutionScorer.passThreshold` — inclusive.
    public var passes: Bool {
        percentage >= ContextResolutionScorer.passThreshold
    }

    public init(
        classes: [ContextResolutionClass], correctCount: Int, totalCount: Int, percentage: Double
    ) {
        self.classes = classes
        self.correctCount = correctCount
        self.totalCount = totalCount
        self.percentage = percentage
    }
}

/// The scorer's refusal: an empty corpus cannot be measured, and a harness that cannot measure
/// must never read green.
public enum ContextResolutionScorerError: Error, Equatable, CustomStringConvertible {
    case emptyCorpus

    public var description: String {
        "an empty corpus cannot be scored — a harness that cannot measure must never read green"
    }
}