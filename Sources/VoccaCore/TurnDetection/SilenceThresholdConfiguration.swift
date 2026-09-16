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

/// The pure fallback's configuration, carried as plain data from the composition root.
///
/// Two durations: how long a pause must be to commit a turn, and how long an utterance must
/// have been for the pause to count at all — the second is what makes the fallback **not a
/// bare silence timer** (R3): a long pause after a too-short utterance never commits, in a
/// headless-testable way. Speech-existence beyond duration is the loop's/EOU's responsibility
/// (the loop only calls `decide` after VAD speech), so the fallback's guard is duration-only —
/// pinned explicitly by the `duration-guard-only` fixture.
///
/// Plain data, `Sendable + Hashable`.
public struct SilenceThresholdConfiguration: Sendable, Hashable {
    /// Seconds of pause after which a turn commits. The boundary is **inclusive**: a pause ≥
    /// this commits.
    public let commitAfterPause: Double

    /// Seconds of utterance below which a turn never commits — the not-a-bare-silence-timer
    /// guard.
    public let minimumUtteranceDuration: Double

    public init(commitAfterPause: Double, minimumUtteranceDuration: Double) {
        precondition(
            commitAfterPause > 0,
            "commitAfterPause must be positive — a zero threshold would commit on the first pause")
        precondition(
            minimumUtteranceDuration > 0,
            "minimumUtteranceDuration must be positive — a zero minimum would disable the "
                + "not-a-bare-silence-timer guard")
        self.commitAfterPause = commitAfterPause
        self.minimumUtteranceDuration = minimumUtteranceDuration
    }
}