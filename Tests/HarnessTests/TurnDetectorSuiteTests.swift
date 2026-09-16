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
import XCTest

/// The CI leg of the `TurnDetectorFixtureSuite`: the committed fixture cases run over
/// ``SilenceThresholdDetector`` (`plan_20260915.md` Phase 1 file 6). The `sdk-adapters` aspect
/// adds the env-gated real leg over the same body.
///
/// `TurnDetector` is stateless by signature — cases are independent. The expected commitments
/// and scores are the plan's committed table, written by hand: the commit boundary at exactly
/// 0.5 s is inclusive and Float-exact by construction (8000 ÷ 16000 = 0.5), and the scores are
/// exactly representable binary fractions.
final class TurnDetectorSuiteTests: XCTestCase {

    func testTheCommittedTurnDetectorFixtureCasesClassifyAsLabelled() {
        let configuration = SilenceThresholdConfiguration(
            commitAfterPause: 0.50, minimumUtteranceDuration: 0.20)
        let detector = SilenceThresholdDetector(configuration: configuration)

        func buffer(samples: Int) -> AudioBuffer {
            AudioBuffer(samples: [Float](repeating: 0, count: samples), sampleRate: 16_000)
        }

        let cases: [TurnDetectorFixtureCase] = [
            TurnDetectorFixtureCase(
                name: "pause-below-threshold",
                utterance: buffer(samples: 4000), pause: buffer(samples: 4000),
                expectedCommitment: .keepListening, expectedScore: 0.5),
            TurnDetectorFixtureCase(
                name: "pause-at-threshold",
                utterance: buffer(samples: 4000), pause: buffer(samples: 8000),
                expectedCommitment: .commit, expectedScore: 1.0),
            TurnDetectorFixtureCase(
                name: "pause-above-threshold",
                utterance: buffer(samples: 4000), pause: buffer(samples: 12000),
                expectedCommitment: .commit, expectedScore: 1.5),
            TurnDetectorFixtureCase(
                name: "long-pause-short-utterance",
                utterance: buffer(samples: 2000), pause: buffer(samples: 12000),
                expectedCommitment: .keepListening, expectedScore: 0),
            TurnDetectorFixtureCase(
                name: "empty-pause",
                utterance: buffer(samples: 4000), pause: buffer(samples: 0),
                expectedCommitment: .keepListening, expectedScore: 0),
            TurnDetectorFixtureCase(
                name: "empty-utterance",
                utterance: buffer(samples: 0), pause: buffer(samples: 8000),
                expectedCommitment: .keepListening, expectedScore: 0),
            TurnDetectorFixtureCase(
                name: "duration-guard-only",
                utterance: buffer(samples: 4000), pause: buffer(samples: 8000),
                expectedCommitment: .commit, expectedScore: 1.0),
        ]

        let results = TurnDetectorFixtureSuite.evaluate(detector, cases: cases)

        XCTAssertEqual(
            results.count, cases.count,
            "the suite records one result per fixture — a missing result would hide a fixture")
        for (result, fixture) in zip(results, cases) {
            XCTAssertEqual(
                result.commitment, fixture.expectedCommitment,
                "fixture \(result.name) committed off its hand-written expectation")
            XCTAssertEqual(
                result.score, fixture.expectedScore,
                "fixture \(result.name) scored off its hand-written expectation")
        }
    }
}