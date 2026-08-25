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

/// The one named table of the warm-start aspect's provisional target
/// (`warm-start/plan_20260825.md` Phase 1; the ``ProvisionalCleanupTargets`` single-source
/// precedent in the eval harness).
///
/// The multiple is **provisional by design**: it is the W2 gate's instrument
/// (`ROADMAP.md:174` — the first transcription after launch must land within twenty percent of
/// the steady-state transcriptions), recorded not proven. It lives in exactly this file — the
/// single-source scan in ``WarmStartRatioTests`` pins the literal to this file and its pinning
/// test — and a re-baseline from the founder's real run (spec W3) lands here, in exactly one
/// place.
public enum WarmStartTargets {
    /// The roadmap's "within twenty percent" bound, as a multiple of steady state. Inclusive:
    /// exactly this ratio is still within (the roadmap's "within" reads as ≤, not <).
    public static let maxFirstAfterLaunchMultiple = 1.2
}

/// The W2 decision: is the first transcription after launch within the bound of the steady-state
/// transcriptions?
///
/// The ratio is `median(firstAfterLaunch) / median(steadyState)` — the p50 discipline the
/// latency bench already uses, so a slow outlier in either side cannot move the verdict. Time
/// enters `VoccaCore` only as ``Duration`` (spec A7); this type reads no clock and converts to
/// a ratio without Foundation.
public enum WarmStartRatio {

    /// The evaluator's answer. The three cases are the whole vocabulary: judgeable-within,
    /// judgeable-past, or **unjudgeable**.
    public enum Verdict: Sendable, Equatable {
        /// Either side had no samples, so there is no ratio — never a fabricated verdict (the
        /// ``LatencySpan/Presence/notPresent`` precedent).
        case insufficientSamples
        /// The ratio is within the bound (inclusive).
        case withinBound(ratio: Double)
        /// The ratio is past the bound; the bound it was judged against is named so it cannot
        /// silently stop being the thing the verdict was measured against.
        case exceedsBound(ratio: Double, bound: Double)
    }

    /// Judges the first-after-launch samples against the steady-state samples.
    ///
    /// - Returns: ``Verdict/insufficientSamples`` when either side is empty;
    ///   ``Verdict/withinBound(ratio:)`` when the ratio is at most
    ///   ``WarmStartTargets/maxFirstAfterLaunchMultiple``; ``Verdict/exceedsBound(ratio:bound:)``
    ///   otherwise.
    public static func evaluate(
        firstAfterLaunch: [Duration], steadyState: [Duration]
    ) -> Verdict {
        guard !firstAfterLaunch.isEmpty, !steadyState.isEmpty else {
            return .insufficientSamples
        }
        let ratio = median(firstAfterLaunch) / median(steadyState)
        let bound = WarmStartTargets.maxFirstAfterLaunchMultiple
        if ratio <= bound {
            return .withinBound(ratio: ratio)
        }
        return .exceedsBound(ratio: ratio, bound: bound)
    }

    /// The p50 of a sample set: the middle element when odd, the mean of the two middles when
    /// even. Whole seconds and attoseconds are read off ``Duration``'s components — stdlib-only.
    private static func median(_ samples: [Duration]) -> Double {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return seconds(sorted[middle])
        }
        return (seconds(sorted[middle - 1]) + seconds(sorted[middle])) / 2
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}