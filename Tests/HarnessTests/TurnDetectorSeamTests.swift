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

/// The turn-detection seam: the protocol `ARCHITECTURE.md:262-263` specifies, as code, with
/// the scored threshold decision (R3) and the not-a-bare-silence-timer guard pinned.
///
/// Where ``ASREngineSeamTests`` pinned the ASR seam's shape and behaviour, this suite pins the
/// turn seam's — against the only `TurnDetector` a hosted runner can ever run,
/// ``SilenceThresholdDetector``. The real EOU adapter (`sdk-adapters`) is ASR-integrated and
/// env-gated; everything here is a claim about the seam as the adapters will find it:
///
/// - the seam decides on the two buffers passed in — synchronous, stateless by signature
///   (`CAPABILITY_ROADMAP.md:275`: below threshold keep listening, above threshold commit);
/// - ``TurnCommitment`` has exactly `.keepListening` and `.commit` — a caller's switch is
///   exhaustive today and breaks at compile time if the vocabulary grows;
/// - ``TurnScore`` is plain data — the implementation's P(user-finished) proxy plus the
///   commitment the 5×-weighted harness consumes (`ARCHITECTURE.md:575`);
/// - the committed fixture table classifies as written by hand — the commit boundary at
///   exactly 0.5 s is inclusive and Float-exact by construction (8000 ÷ 16000 = 0.5); every
///   other boundary carries margin;
/// - the **not-a-bare-silence-timer guard**: a long pause after a too-short utterance never
///   commits (score 0), and the guard is duration-only — speech-existence is the loop's
///   responsibility, pinned explicitly;
/// - callers never branch on implementation.
final class TurnDetectorSeamTests: XCTestCase {

    /// The fixture configuration (`plan_20260915.md` §Testing strategy):
    /// `commitAfterPause 0.50 s`, `minimumUtteranceDuration 0.20 s`. Utterance 4000 samples =
    /// 0.25 s; 2000 = 0.125 s; pause 8000 = 0.5 s (exactly representable), 12000 = 0.75 s.
    private static let configuration = SilenceThresholdConfiguration(
        commitAfterPause: 0.50, minimumUtteranceDuration: 0.20)

    /// A zero buffer of the given sample count. Content is irrelevant to the fallback — the
    /// decision is duration-based by design — and zeros are what make that honest.
    private static func buffer(samples: Int) -> AudioBuffer {
        AudioBuffer(samples: [Float](repeating: 0, count: samples), sampleRate: 16_000)
    }

    /// The seam exists and decides on the pause and utterance buffers — the compile pin
    /// `ASREngineSeamTests` applies: if the protocol's shape is ever weakened or renamed, this
    /// stops compiling rather than coercing. `TurnDetector` is stateless by signature: the
    /// decision is over the two buffers passed in (the real EOU adapter's internal history is
    /// its own business).
    func testTheSeamDecidesOnThePauseAndUtteranceBuffers() {
        func requireDetector(_ detector: any TurnDetector) -> any TurnDetector { detector }

        let detector = requireDetector(SilenceThresholdDetector(configuration: Self.configuration))
        let score = detector.decide(Self.buffer(samples: 4000), utterance: Self.buffer(samples: 4000))

        XCTAssertEqual(
            score.commitment, .keepListening,
            "a 0.25 s pause against commitAfterPause 0.50 s keeps listening")
        XCTAssertEqual(
            score.score, 0.5,
            "the score is pause ÷ threshold — 0.25 / 0.5 = 0.5, exactly representable")
    }

    /// ``TurnCommitment`` has exactly `.keepListening` and `.commit` — the exhaustive switch
    /// is the compile pin: a third case stops this test (and every caller's switch) from
    /// building.
    func testTurnCommitmentIsExactlyKeepListeningOrCommit() {
        func describe(_ commitment: TurnCommitment) -> String {
            switch commitment {
            case .keepListening: return "keepListening"
            case .commit: return "commit"
            }
        }
        XCTAssertEqual(describe(.keepListening), "keepListening")
        XCTAssertEqual(describe(.commit), "commit")
    }

    /// ``TurnScore`` is plain data: the score (the implementation's P(user-finished) proxy)
    /// and the commitment the 5×-weighted harness consumes — carried by value and `Sendable`.
    func testTurnScoreIsPlainDataAndSendable() {
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let score = requireSendable(TurnScore(score: 0.5, commitment: .keepListening))
        XCTAssertEqual(score.score, 0.5)
        XCTAssertEqual(score.commitment, .keepListening)
    }

    /// `pause-below-threshold`: utterance 4000 / pause 4000 (0.25 s pause) — below the 0.50 s
    /// threshold, keep listening, score 0.5.
    func testPauseBelowThresholdKeepsListening() {
        let score = SilenceThresholdDetector(configuration: Self.configuration)
            .decide(Self.buffer(samples: 4000), utterance: Self.buffer(samples: 4000))

        XCTAssertEqual(score.commitment, .keepListening)
        XCTAssertEqual(score.score, 0.5)
    }

    /// `pause-at-threshold`: utterance 4000 / pause 8000 (0.5 s pause) — the commit boundary is
    /// **inclusive** (`pause >= commitAfterPause` commits), and the boundary is Float-exact by
    /// construction: 8000 ÷ 16000 = 0.5 exactly.
    func testPauseAtThresholdCommits() {
        let score = SilenceThresholdDetector(configuration: Self.configuration)
            .decide(Self.buffer(samples: 8000), utterance: Self.buffer(samples: 4000))

        XCTAssertEqual(score.commitment, .commit, "the commit boundary is inclusive — 0.5 s commits")
        XCTAssertEqual(score.score, 1.0)
    }

    /// `pause-above-threshold`: utterance 4000 / pause 12000 (0.75 s pause) — above the
    /// threshold, commit, score 1.5.
    func testPauseAboveThresholdCommits() {
        let score = SilenceThresholdDetector(configuration: Self.configuration)
            .decide(Self.buffer(samples: 12000), utterance: Self.buffer(samples: 4000))

        XCTAssertEqual(score.commitment, .commit)
        XCTAssertEqual(score.score, 1.5)
    }

    /// `long-pause-short-utterance`: utterance 2000 (0.125 s) / pause 12000 (0.75 s) — the
    /// **not-a-bare-silence-timer guard**: an utterance below `minimumUtteranceDuration` never
    /// commits, however long the pause, and the score is 0. A bare silence timer would commit
    /// here.
    func testLongPauseWithShortUtteranceNeverCommits() {
        let score = SilenceThresholdDetector(configuration: Self.configuration)
            .decide(Self.buffer(samples: 12000), utterance: Self.buffer(samples: 2000))

        XCTAssertEqual(
            score.commitment, .keepListening,
            "a 0.75 s pause after a 0.125 s utterance must not commit — a bare silence timer would")
        XCTAssertEqual(
            score.score, 0,
            "the guard's score is 0, not a pause-derived fraction — the minimum-utterance guard is "
                + "the seam's answer, not a discount")
    }

    /// `empty-pause`: utterance 4000 / pause 0 — no pause, no commitment.
    func testEmptyPauseKeepsListening() {
        let score = SilenceThresholdDetector(configuration: Self.configuration)
            .decide(Self.buffer(samples: 0), utterance: Self.buffer(samples: 4000))

        XCTAssertEqual(score.commitment, .keepListening)
        XCTAssertEqual(score.score, 0)
    }

    /// `empty-utterance`: utterance 0 / pause 8000 — the guard catches it: nothing spoken is
    /// not a turn to commit.
    func testEmptyUtteranceKeepsListening() {
        let score = SilenceThresholdDetector(configuration: Self.configuration)
            .decide(Self.buffer(samples: 8000), utterance: Self.buffer(samples: 0))

        XCTAssertEqual(score.commitment, .keepListening)
        XCTAssertEqual(score.score, 0)
    }

    /// `duration-guard-only`: utterance 4000 samples of **zeros** / pause 8000 — the guard is
    /// duration-only (speech-existence is the loop's/EOU's responsibility; the loop only calls
    /// `decide` after VAD speech). Pinned explicitly so the composition cannot unknowingly rely
    /// on the fallback to reject silence.
    func testTheGuardIsDurationOnly() {
        let score = SilenceThresholdDetector(configuration: Self.configuration)
            .decide(Self.buffer(samples: 8000), utterance: Self.buffer(samples: 4000))

        XCTAssertEqual(
            score.commitment, .commit,
            "a silent-but-long-enough utterance with a long pause commits — the fallback's guard "
                + "measures duration, never content")
        XCTAssertEqual(score.score, 1.0)
    }

    /// Score monotonicity: same utterance, longer pause → strictly higher score — the scored
    /// decision (R3) that the 5×-weighted harness consumes, not a bare boolean.
    func testScoreIsStrictlyMonotonicInPauseDuration() {
        let detector = SilenceThresholdDetector(configuration: Self.configuration)
        let utterance = Self.buffer(samples: 4000)
        let pauses = [4000, 8000, 12000]

        let scores = pauses.map { detector.decide(Self.buffer(samples: $0), utterance: utterance).score }

        XCTAssertEqual(scores, [0.5, 1.0, 1.5])
        XCTAssertTrue(
            zip(scores, scores.dropFirst()).allSatisfy { $0 < $1 },
            "a longer pause must score strictly higher — the commitment harness weights false "
                + "cutoffs 5× worse than late commits and needs an ordered score, not a boolean")
    }

    /// Callers never branch on implementation: the driver below is written against the seam's
    /// existential alone — the concrete fallback is invisible to it — and the stub double
    /// proves the protocol (not the fallback) is what the driver speaks. A caller that names
    /// `SilenceThresholdDetector` at a decision point would not satisfy this shape.
    func testCallersDriveTheSeamThroughTheProtocolOnly() {
        struct FixedTurnDetector: TurnDetector {
            func decide(_ pause: AudioBuffer, utterance: AudioBuffer) -> TurnScore {
                TurnScore(
                    score: pause.audioDuration,
                    commitment: pause.audioDuration > 0 ? .commit : .keepListening)
            }
        }

        func decide(_ detector: any TurnDetector, pause: AudioBuffer, utterance: AudioBuffer)
            -> TurnScore
        {
            detector.decide(pause, utterance: utterance)
        }

        let detector = FixedTurnDetector()
        let decision = decide(
            detector, pause: Self.buffer(samples: 8000), utterance: Self.buffer(samples: 4000))

        XCTAssertEqual(
            decision.commitment, .commit,
            "the driver's contract is the protocol — the stub double's answer flows through the "
                + "existential, and the caller never names the implementation")
    }
}