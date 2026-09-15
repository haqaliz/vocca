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

/// The turn-detector fixture suite's machinery: fixtures in, per-detector legs out — one
/// harness, run parameterized over every `TurnDetector` (the `SpeechFixtureSuite` shape,
/// `plan_20260915.md` Phase 1 file 4; the `sdk-adapters` aspect drives the same body over the
/// real EOU adapter env-gated).
///
/// Everything here runs headlessly: the fixtures are synthetic buffers built by hand at a fixed
/// sample count, and the detector under test is `SilenceThresholdDetector` in CI. The body
/// measures and records; the assertions live in the tests, where the expected commitments and
/// scores are written by hand rather than read back from the detector.
struct TurnDetectorFixtureCase: Sendable {
    /// The fixture's base name — `pause-below-threshold`, `long-pause-short-utterance`, …
    let name: String
    /// The utterance buffer: the speech the candidate pause follows.
    let utterance: AudioBuffer
    /// The pause buffer: the silence being scored.
    let pause: AudioBuffer
    /// The hand-written expected commitment.
    let expectedCommitment: TurnCommitment
    /// The hand-written expected score.
    let expectedScore: Double
}

/// One detector's measured leg on one fixture.
struct TurnDetectorFixtureResult: Sendable {
    let name: String
    let score: Double
    let commitment: TurnCommitment
}

enum TurnDetectorFixtureSuite {

    /// Runs one detector over the fixtures and records every leg.
    ///
    /// `TurnDetector` is stateless by signature — the decision is over the two buffers passed
    /// in — so cases are independent and no `inout` is needed. The body measures and records;
    /// the assertions live in the tests.
    static func evaluate(
        _ detector: any TurnDetector, cases: [TurnDetectorFixtureCase]
    ) -> [TurnDetectorFixtureResult] {
        var results: [TurnDetectorFixtureResult] = []
        for fixture in cases {
            let score = detector.decide(fixture.pause, utterance: fixture.utterance)
            results.append(
                TurnDetectorFixtureResult(
                    name: fixture.name, score: score.score, commitment: score.commitment))
        }
        return results
    }
}