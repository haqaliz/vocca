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

/// The voice-activity fixture suite's machinery: fixtures in, per-detector legs out — one
/// harness, run parameterized over every `VoiceActivityDetector` (the `SpeechFixtureSuite`
/// shape, `plan_20260915.md` Phase 1 file 3; the `sdk-adapters` aspect drives the same body
/// over the real `SileroVAD` env-gated).
///
/// Everything here runs headlessly: the fixtures are synthetic frames built by hand at a fixed
/// sample count, and the detector under test is `EnergyVAD` in CI. The body measures and
/// records; the assertions live in the tests, where the expected classifications are written by
/// hand rather than read back from the detector.
struct VoiceActivityFixtureCase: Sendable {
    /// The fixture's base name — `all-silence`, `tone-burst`, …
    let name: String
    /// The frames to classify, in order, against **one** detector instance.
    let frames: [AudioBuffer]
    /// The hand-written expected classification per frame.
    let expected: [SpeechActivity]
}

/// One detector's measured legs on one fixture.
struct VoiceActivityFixtureResult: Sendable {
    let name: String
    /// The classifications in frame order.
    let classifications: [SpeechActivity]
}

enum VoiceActivityFixtureSuite {

    /// Runs one detector over the fixtures and records every leg.
    ///
    /// Cases are applied **in order to one detector instance** — a case's expected sequence is
    /// written against the state the previous cases left (VAD hysteresis is stateful; the loop
    /// is one continuous run). The body measures and records; the assertions live in the tests,
    /// where the ground truth is written by hand rather than read back from the detector.
    ///
    /// Throws on a corrupted fixture — an `expected` sequence that is not one classification
    /// per frame — because a fixture whose expectation is meaningless is a harness bug, not a
    /// detector failure.
    static func evaluate(
        _ detector: inout any VoiceActivityDetector, cases: [VoiceActivityFixtureCase]
    ) throws -> [VoiceActivityFixtureResult] {
        var results: [VoiceActivityFixtureResult] = []
        for fixture in cases {
            guard fixture.expected.count == fixture.frames.count else {
                throw VoiceActivityFixtureSuiteError.corruptedFixture(name: fixture.name)
            }
            var classifications: [SpeechActivity] = []
            for frame in fixture.frames {
                classifications.append(detector.classify(frame))
            }
            results.append(
                VoiceActivityFixtureResult(name: fixture.name, classifications: classifications))
        }
        return results
    }

    private enum VoiceActivityFixtureSuiteError: Error, CustomStringConvertible {
        case corruptedFixture(name: String)

        var description: String {
            switch self {
            case .corruptedFixture(let name):
                return "fixture \(name): the expected sequence is not one classification per frame — a corrupted fixture, not a detector failure"
            }
        }
    }
}