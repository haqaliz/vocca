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

/// The CI leg of the `VoiceActivityFixtureSuite`: the committed fixture cases run over
/// ``EnergyVAD`` — the "CI's implementation" leg (`plan_20260915.md` Phase 1 file 5). The
/// `sdk-adapters` aspect adds the env-gated real leg over the same body.
///
/// One detector instance, cases applied in order — a case's expected sequence is written
/// against the state the previous cases left (VAD hysteresis is stateful; the loop is one
/// continuous run). The expected classifications are the plan's committed table, written by
/// hand: every row carries ≥10% amplitude margin against every boundary it crosses.
final class VoiceActivitySuiteTests: XCTestCase {

    func testTheCommittedVoiceActivityFixtureCasesClassifyAsLabelled() throws {
        let configuration = VADConfiguration(
            onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)
        var detector: any VoiceActivityDetector = EnergyVAD(configuration: configuration)

        let cases: [VoiceActivityFixtureCase] = [
            VoiceActivityFixtureCase(
                name: "all-silence",
                frames: (0..<4).map { _ in VoiceActivityFixtures.makeSilence(samples: 1000) },
                expected: [.silence, .silence, .silence, .silence]),
            VoiceActivityFixtureCase(
                name: "tone-burst",
                frames: (0..<2).map { _ in VoiceActivityFixtures.makeSilence(samples: 1000) }
                    + (0..<6).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000) },
                expected: [.silence, .silence, .silence, .speech, .speech, .speech, .speech,
                    .speech]),
            VoiceActivityFixtureCase(
                name: "onset-offset-hysteresis",
                frames: (0..<2).map { _ in VoiceActivityFixtures.makeSilence(samples: 1000) }
                    + (0..<2).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000) }
                    + (0..<3).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.035, samples: 1000) }
                    + (0..<4).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.01, samples: 1000) },
                expected: [.silence, .silence, .silence, .speech, .speech, .speech, .speech,
                    .speech, .speech, .speech, .silence]),
            VoiceActivityFixtureCase(
                name: "amplitude-ramp",
                frames: VoiceActivityFixtures.makeRamp(
                    amplitudes: [0, 0.08, 0.16, 0.24, 0.32, 0.4])
                    + (0..<4).map { _ in VoiceActivityFixtures.makeTone(amplitude: 0.4, samples: 1000) }
                    + (0..<4).map { _ in VoiceActivityFixtures.makeSilence(samples: 1000) },
                expected: [.silence, .silence, .speech, .speech, .speech, .speech, .speech,
                    .speech, .speech, .speech, .speech, .speech, .speech, .silence]),
            VoiceActivityFixtureCase(
                name: "constant-at-margin",
                frames: (0..<3).map { _ in VoiceActivityFixtures.makeConstant(0.06, samples: 1000) },
                expected: [.silence, .speech, .speech]),
        ]

        let results = try VoiceActivityFixtureSuite.evaluate(&detector, cases: cases)

        XCTAssertEqual(
            results.count, cases.count,
            "the suite records one result per fixture — a missing result would hide a fixture")
        for (result, fixture) in zip(results, cases) {
            XCTAssertEqual(
                result.classifications, fixture.expected,
                "fixture \(result.name) classified off its hand-written expectations")
        }
    }
}