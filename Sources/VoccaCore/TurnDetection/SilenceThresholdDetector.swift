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

/// The pure, headless ``TurnDetector`` fallback: pause duration ÷ threshold, with the
/// minimum-utterance guard that makes it **not a bare silence timer**.
///
/// The seam's CI implementation — deterministic, stdlib-only, and the loop's default work in
/// the zero-network probe (G6). The real EOU adapter (FluidAudio's ASR-integrated
/// `StreamingEouAsrManager`, the `sdk-adapters` aspect) replaces this score; a caller holding
/// `any TurnDetector` cannot and must not tell them apart.
///
/// ## The rules
///
/// - `pauseDuration = pause.audioDuration`; `utteranceDuration = utterance.audioDuration`
///   (both `Double`, samples ÷ 16 000 — exact for the fixture durations, including 0.5 s).
/// - **Guard:** `utteranceDuration < minimumUtteranceDuration` → score `0`, `.keepListening`.
///   This is what makes it **not a bare silence timer** in a headless-testable way: a long
///   pause after a too-short utterance never commits.
/// - Otherwise `score = pauseDuration / commitAfterPause` and
///   `commitment = pauseDuration >= commitAfterPause ? .commit : .keepListening`.
///
/// ## The guard is duration-only
///
/// Speech-existence is the caller's/loop's responsibility — the loop only calls `decide` after
/// VAD speech — so a silent-but-long-enough utterance with a long pause **commits** (pinned
/// explicitly by the `duration-guard-only` fixture so the composition cannot unknowingly rely
/// on the fallback to reject silence). The commit boundary is **inclusive**: a pause exactly
/// at `commitAfterPause` commits, and the boundary is Float-exact by construction (8000 ÷
/// 16000 = 0.5). The real EOU (sdk-adapters) replaces this score with its own P(user-finished)
/// proxy; the seam's ``TurnScore`` vocabulary and the 5×-weighted harness that consumes
/// `commitment` stay unchanged.
public struct SilenceThresholdDetector: TurnDetector {
    /// The thresholds this instance decides with.
    public let configuration: SilenceThresholdConfiguration

    public init(configuration: SilenceThresholdConfiguration) {
        self.configuration = configuration
    }

    public func decide(_ pause: AudioBuffer, utterance: AudioBuffer) -> TurnScore {
        let pauseDuration = pause.audioDuration
        let utteranceDuration = utterance.audioDuration

        guard utteranceDuration >= configuration.minimumUtteranceDuration else {
            return TurnScore(score: 0, commitment: .keepListening)
        }

        let score = pauseDuration / configuration.commitAfterPause
        let commitment: TurnCommitment =
            pauseDuration >= configuration.commitAfterPause ? .commit : .keepListening
        return TurnScore(score: score, commitment: commitment)
    }
}