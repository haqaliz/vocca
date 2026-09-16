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

import Foundation
import VoccaCore
import XCTest

/// What the harness refuses to evaluate — a parse error is a **loud failure**, never a
/// skipped fixture: a corpus row the harness cannot read would otherwise read as green
/// while a leg goes unmeasured.
enum ConversationalHarnessError: Error, CustomStringConvertible {
    case unreadableCorpus(reason: String)
    case malformedFixture(index: Int, reason: String)

    var description: String {
        switch self {
        case .unreadableCorpus(let reason):
            return "the conversational corpus could not be read: \(reason)"
        case .malformedFixture(let index, let reason):
            return "fixture \(index) is malformed: \(reason)"
        }
    }
}

/// **The conversational-set harness** (`barge-in-loop/plan_20260915.md` Phase 4, G4/R8): parse
/// the scripted corpus (S2's replayable format — the founder's SMOKE 131 recording drops in
/// without harness changes), render the segments to frames, drive the real
/// ``TurnTakingLoop``, record every commit instant, classify every labelled boundary against
/// `boundary + commitAfterPause` ±100 ms, and score.
///
/// ## The VAD is the corpus's own labels — a recorded deviation from the plan's letter
///
/// The plan's harness description says "drive the loop (`EnergyVAD(configuration:)`...)".
/// That cannot produce the plan's own pinned arithmetic: EnergyVAD's `minimumSilence` hold
/// (0.20 s — the committed config) adds a fixed ~0.25 s to every pause before the loop's
/// pause accumulator starts, so every commit lands ~0.25 s after `boundary +
/// commitAfterPause` — every row a `.lateCommit`, the passing corpus failing. The plan's own
/// corpus note says "the corpus's job is the classification path", and the harness derives
/// `expectedCommitAt = boundary + commitAfterPause` (the detector's own threshold) — so the
/// harness drives the loop with a **VAD derived from the corpus's own segment labels** (a
/// perfect classifier by construction), which isolates the measurement exactly where the
/// plan puts it: the turn-commitment path. The planted false-cutoff corpus genuinely fails
/// because the false cutoff is in the **audio** (a hesitation pause long enough to trip the
/// planted 0.15 s threshold and short enough to be a real interruption) — a gate that cannot
/// fail proves nothing. The probe (G6) still drives the real `EnergyVAD` default work.
struct ConversationalHarness {

    /// One corpus run's verdict.
    struct Outcome {
        let corpusName: String
        let fixtureCount: Int
        let boundaryCount: Int
        let score: TurnCommitmentScore
    }

    /// The committed VAD configuration (the voice-detection plan's numbers), carried by the
    /// label-derived VAD for the seam's `configuration` surface.
    static let vadConfiguration = VADConfiguration(
        onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20)

    /// Evaluates one corpus file: parse → render → drive → classify → score.
    static func evaluate(corpusURL: URL, clock: TurnLoopTestClock) async throws -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOf: corpusURL)
        } catch {
            throw ConversationalHarnessError.unreadableCorpus(reason: "\(error)")
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ConversationalHarnessError.unreadableCorpus(reason: "\(error)")
        }
        guard let fixtures = json as? [[String: Any]], !fixtures.isEmpty else {
            throw ConversationalHarnessError.unreadableCorpus(
                reason: "expected a non-empty JSON array of fixtures")
        }

        let stub = StubSynthesizer(
            identity: VoiceIdentity(engineID: "harness-stub-synth", voiceName: nil), chunks: [])
        let playback = FakePlaybackEngine()
        var allClasses: [TurnCommitmentClass] = []
        var boundaryCount = 0

        for (index, rawFixture) in fixtures.enumerated() {
            let fixture = try parseFixture(rawFixture, index: index)
            let (frames, classifications) = render(fixture)

            var effects: [TurnEffect] = []
            var commitInstants: [Duration] = []
            let loop = TurnTakingLoop(
                vad: ConversationalLabelVAD(
                    configuration: Self.vadConfiguration, script: classifications),
                turnDetector: SilenceThresholdDetector(configuration: fixture.detector),
                clock: clock,
                gate: EchoGate(),
                onEffect: { effects.append($0) })

            let fixtureStart = clock.now

            /// Applies the loop's effects as the owner would. `.turnCommitted` records the
            /// instant (relative to the fixture's start — the clock is shared across
            /// fixtures) and schedules the chunk-free reply; `.speakReply` runs the
            /// empty-script stub through the fake playback (nothing to hear, no reference —
            /// nothing can be gated) and reports the window open/closed; the other effects
            /// need no owner work here.
            func drain() async throws {
                while !effects.isEmpty {
                    let effect = effects.removeFirst()
                    switch effect {
                    case .turnCommitted:
                        commitInstants.append(clock.now - fixtureStart)
                        loop.scheduleReply("ok")
                    case .speakReply(let text):
                        try await playback.play(stub.speak(text))
                        loop.reportPlaybackStarted()
                        loop.reportPlaybackEnded()
                    case .started, .stopped, .speechBegan, .bargeIn, .captureFailed:
                        break
                    }
                }
            }

            loop.start()
            for frame in frames {
                clock.advance(by: frameDuration(frame))
                loop.feed(frame)
                try await drain()
            }
            loop.stop()

            // The k-th commit answers the k-th labelled boundary. Extra commits (a planted
            // false cutoff is followed by the speaker's continuation, which commits again)
            // are unlabelled and ignored by the k-th mapping; a missing commit is a
            // `.missedCommit` per the classify rule.
            for (boundaryIndex, boundary) in fixture.boundaries.enumerated() {
                let commitAt = commitInstants.indices.contains(boundaryIndex)
                    ? commitInstants[boundaryIndex] : nil
                let expected = Duration.milliseconds(
                    Int64((boundary + fixture.detector.commitAfterPause) * 1000))
                allClasses.append(
                    TurnCommitmentScorer.classify(commitAt: commitAt, expectedCommitAt: expected))
            }
            boundaryCount += fixture.boundaries.count
        }

        return Outcome(
            corpusName: corpusURL.lastPathComponent,
            fixtureCount: fixtures.count,
            boundaryCount: boundaryCount,
            score: try TurnCommitmentScorer.score(allClasses))
    }

    /// A parsed fixture's shape.
    private struct Fixture {
        let name: String
        let detector: SilenceThresholdConfiguration
        let segments: [(kind: String, seconds: Double, amplitude: Double)]
        let boundaries: [Double]
    }

    private static func parseFixture(
        _ raw: [String: Any], index: Int
    ) throws -> Fixture {
        func require<T>(_ key: String, as: T.Type) throws -> T {
            guard let value = raw[key] as? T else {
                throw ConversationalHarnessError.malformedFixture(
                    index: index, reason: "missing or mistyped field '\(key)'")
            }
            return value
        }
        let name = try require("name", as: String.self)
        guard let detector = raw["detector"] as? [String: Any],
            let commitAfterPause = detector["commitAfterPause"] as? Double,
            let minimumUtteranceDuration = detector["minimumUtteranceDuration"] as? Double
        else {
            throw ConversationalHarnessError.malformedFixture(
                index: index, reason: "the detector block must carry commitAfterPause and "
                    + "minimumUtteranceDuration")
        }
        guard let rawSegments = raw["segments"] as? [[String: Any]], !rawSegments.isEmpty else {
            throw ConversationalHarnessError.malformedFixture(
                index: index, reason: "segments must be a non-empty array")
        }
        let segments: [(kind: String, seconds: Double, amplitude: Double)] = try rawSegments.map {
            segment in
            guard let kind = segment["kind"] as? String,
                kind == "silence" || kind == "speech",
                let seconds = segment["seconds"] as? Double, seconds > 0
            else {
                throw ConversationalHarnessError.malformedFixture(
                    index: index, reason: "each segment needs a 'silence'/'speech' kind and a "
                        + "positive duration")
            }
            return (kind, seconds, (segment["amplitude"] as? Double) ?? 0.4)
        }
        guard let rawBoundaries = raw["boundaries"] as? [[String: Any]], !rawBoundaries.isEmpty else {
            throw ConversationalHarnessError.malformedFixture(
                index: index, reason: "boundaries must be a non-empty array")
        }
        let boundaries = try rawBoundaries.map { boundary -> Double in
            guard let atSeconds = boundary["atSeconds"] as? Double else {
                throw ConversationalHarnessError.malformedFixture(
                    index: index, reason: "each boundary needs an atSeconds field")
            }
            return atSeconds
        }
        return Fixture(
            name: name, detector: SilenceThresholdConfiguration(
                commitAfterPause: commitAfterPause,
                minimumUtteranceDuration: minimumUtteranceDuration),
            segments: segments, boundaries: boundaries)
    }

    /// Renders the fixture's segments to 1000-sample frames at 16 kHz (silence = zeros,
    /// speech = 440 Hz tone at the amplitude — **440 Hz is safe here**: the harness's reply
    /// playback is chunk-free, so no reference ever exists and nothing can be gated) and
    /// derives the label VAD's script: one `SpeechActivity` per frame, by the segment
    /// covering the frame's first sample.
    private static func render(
        _ fixture: Fixture
    ) -> (frames: [AudioBuffer], classifications: [SpeechActivity]) {
        var samples: [Float] = []
        var classifications: [SpeechActivity] = []
        var segmentStart = 0
        var nextFrameStart = 0

        for segment in fixture.segments {
            let count = Int((segment.seconds * 16_000).rounded())
            while nextFrameStart < segmentStart + count {
                classifications.append(segment.kind == "speech" ? .speech : .silence)
                nextFrameStart += 1000
            }
            if segment.kind == "speech" {
                let frequency = 440.0
                samples.append(contentsOf: (0..<count).map { offset in
                    Float(segment.amplitude)
                        * Float(sin(2 * Double.pi * frequency * Double(segmentStart + offset) / 16_000))
                })
            } else {
                samples.append(contentsOf: [Float](repeating: 0, count: count))
            }
            segmentStart += count
        }
        // Any frames whose first sample lands past the last segment's end — the tail of the
        // final segment's last frame — stay with the last classification (the loop stops
        // feeding when the samples run out; the script must only cover the frames it gets).
        let frameCount = (samples.count + 999) / 1000
        while classifications.count < frameCount {
            classifications.append(classifications.last ?? .silence)
        }

        let frames = (0..<frameCount).map { frameIndex in
            let start = frameIndex * 1000
            let end = min(start + 1000, samples.count)
            return AudioBuffer(samples: Array(samples[start..<end]), sampleRate: 16_000)
        }
        return (frames, classifications)
    }

    /// One frame's duration at 16 kHz — exactly 62.5 ms per full 1000-sample frame.
    private static func frameDuration(_ frame: AudioBuffer) -> Duration {
        .nanoseconds(62_500 * Int64(frame.samples.count))
    }
}

/// The label-derived VAD the harness drives: the corpus's own segment labels as the perfect
/// classifier, so the measurement isolates the turn-commitment path (the recorded deviation
/// in ``ConversationalHarness``'s doc). The script advances per classify call, exactly like
/// a stateful detector.
struct ConversationalLabelVAD: VoiceActivityDetector {
    let configuration: VADConfiguration
    let script: [SpeechActivity]
    private var index = 0

    init(configuration: VADConfiguration, script: [SpeechActivity]) {
        precondition(!script.isEmpty, "a label VAD with no classifications classifies nothing")
        self.configuration = configuration
        self.script = script
    }

    mutating func classify(_ frame: AudioBuffer) -> SpeechActivity {
        defer { index += 1 }
        return script[min(index, script.count - 1)]
    }
}

/// The conversational-set scorer (G4/R8): the 5× false-cutoff weight, the inclusive 0.95
/// bar, and the corpus runs — **the passing corpus clears the bar with zero false cutoffs,
/// the planted false-cutoff corpus genuinely fails, and the late-commit corpus fails at the
/// pinned 0.25 all-late**.
final class TurnCommitmentHarnessTests: XCTestCase {

    private static func corpusURL(named name: String) throws -> URL {
        try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Tests/HarnessTests/Fixtures/Conversational/\(name).json")
    }

    // MARK: - The scorer's unit rows (every number hand-computed)

    /// 1 false cutoff in 20 → 1 − 5/24 ≈ 0.792 — **fails** (the planted corpus's shape).
    func testOneFalseCutoffInTwentyFailsBelowTheBar() throws {
        let classes = [.falseCutoff] + Array(repeating: TurnCommitmentClass.correct, count: 19)
        let score = try TurnCommitmentScorer.score(classes)
        XCTAssertEqual(score.weightedErrorCount, 5)
        XCTAssertEqual(score.weightedScore, 19.0 / 24.0, accuracy: 0.0001)
        XCTAssertLessThan(score.weightedScore, TurnCommitmentScorer.passThreshold)
    }

    /// 1 late commit in 20 → **exactly 0.95 — passes** (the 5× asymmetry, at the bar by
    /// design).
    func testOneLateCommitInTwentyPassesExactlyAtTheBar() throws {
        let classes = [.lateCommit] + Array(repeating: TurnCommitmentClass.correct, count: 19)
        let score = try TurnCommitmentScorer.score(classes)
        XCTAssertEqual(score.weightedErrorCount, 1)
        XCTAssertEqual(score.weightedScore, 0.95, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(score.weightedScore, TurnCommitmentScorer.passThreshold)
    }

    /// 1 missed commit in 20 → 1 − 2/21 ≈ 0.905 — **fails** (a turn nobody commits stalls
    /// the conversation — worse than late, less catastrophic than a cutoff).
    func testOneMissedCommitInTwentyFailsBelowTheBar() throws {
        let classes = [.missedCommit] + Array(repeating: TurnCommitmentClass.correct, count: 19)
        let score = try TurnCommitmentScorer.score(classes)
        XCTAssertEqual(score.weightedErrorCount, 2)
        XCTAssertEqual(score.weightedScore, 19.0 / 21.0, accuracy: 0.0001)
        XCTAssertLessThan(score.weightedScore, TurnCommitmentScorer.passThreshold)
    }

    /// An empty corpus throws — a harness that cannot measure must never read green.
    func testAnEmptyCorpusThrows() {
        XCTAssertThrowsError(try TurnCommitmentScorer.score([])) { error in
            XCTAssertEqual(error as? TurnCommitmentScorerError, .emptyCorpus)
        }
    }

    /// The tolerance rows of `classify`: at/before/after/never with the 100 ms tolerance.
    func testClassifyRoundsTheBoundariesAtTheTolerance() {
        let expected = Duration.milliseconds(2100)
        let tolerance = Duration.milliseconds(100)

        XCTAssertEqual(
            TurnCommitmentScorer.classify(commitAt: nil, expectedCommitAt: expected), .missedCommit)
        XCTAssertEqual(
            TurnCommitmentScorer.classify(
                commitAt: expected - tolerance - .nanoseconds(1), expectedCommitAt: expected),
            .falseCutoff)
        XCTAssertEqual(
            TurnCommitmentScorer.classify(
                commitAt: expected - tolerance, expectedCommitAt: expected),
            .correct,
            "commitAt exactly at expected - tolerance is not a cutoff — the comparison is strict")
        XCTAssertEqual(
            TurnCommitmentScorer.classify(
                commitAt: expected + tolerance, expectedCommitAt: expected),
            .correct,
            "commitAt exactly at expected + tolerance is correct — the comparison is inclusive")
        XCTAssertEqual(
            TurnCommitmentScorer.classify(
                commitAt: expected + tolerance + .nanoseconds(1), expectedCommitAt: expected),
            .lateCommit)
    }

    // MARK: - The corpus runs

    /// The passing corpus clears the bar with zero false cutoffs — every labelled boundary
    /// commits within the tolerance of `boundary + commitAfterPause`.
    func testThePassingCorpusClearsTheBarWithZeroFalseCutoffs() async throws {
        let outcome = try await ConversationalHarness.evaluate(
            corpusURL: try Self.corpusURL(named: "passing-corpus"), clock: TurnLoopTestClock())
        print(
            "CONVERSATIONAL passing score=\(String(format: "%.4f", outcome.score.weightedScore))"
                + " boundaries=\(outcome.boundaryCount) classes=\(outcome.score.classes)")
        XCTAssertGreaterThanOrEqual(outcome.score.weightedScore, TurnCommitmentScorer.passThreshold)
        XCTAssertEqual(
            outcome.score.classes.filter { $0 == .falseCutoff }.count, 0,
            "the passing corpus must commit without a single false cutoff")
        XCTAssertEqual(
            outcome.score.classes.filter { $0 == .missedCommit }.count, 0,
            "every labelled boundary must commit")
    }

    /// The planted false-cutoff corpus **genuinely fails**: every boundary is a false
    /// cutoff — a gate that cannot fail proves nothing.
    func testThePlantedFalseCutoffCorpusGenuinelyFails() async throws {
        let outcome = try await ConversationalHarness.evaluate(
            corpusURL: try Self.corpusURL(named: "planted-false-cutoff-corpus"),
            clock: TurnLoopTestClock())
        print(
            "CONVERSATIONAL planted score=\(String(format: "%.4f", outcome.score.weightedScore))"
                + " boundaries=\(outcome.boundaryCount) classes=\(outcome.score.classes)")
        XCTAssertLessThan(outcome.score.weightedScore, TurnCommitmentScorer.passThreshold)
        XCTAssertEqual(
            outcome.score.classes.filter { $0 == .falseCutoff }.count, outcome.boundaryCount,
            "the planted corpus fails with every labelled boundary a false cutoff — a fail "
                + "that cannot happen vacuously")
    }

    /// The late-commit corpus fails at the pinned 0.25 — L=3, C=1 — with the 5× asymmetry
    /// demonstrated at the harness level (the classification path; the arithmetic stays in
    /// the scorer's unit rows).
    func testTheLateCommitCorpusFailsAtThePinnedQuarter() async throws {
        let outcome = try await ConversationalHarness.evaluate(
            corpusURL: try Self.corpusURL(named: "late-commit-corpus"),
            clock: TurnLoopTestClock())
        print(
            "CONVERSATIONAL late score=\(String(format: "%.4f", outcome.score.weightedScore))"
                + " boundaries=\(outcome.boundaryCount) classes=\(outcome.score.classes)")
        XCTAssertEqual(
            outcome.score.weightedErrorCount, 3,
            "the late corpus must score exactly L=3, C=1 — weightedErrorCount 3")
        XCTAssertEqual(
            outcome.score.weightedScore, 0.25, accuracy: 0.0001,
            "weightedScore = 1 − 3/4 = 0.25, the plan's pin")
        XCTAssertLessThan(outcome.score.weightedScore, TurnCommitmentScorer.passThreshold)
        XCTAssertEqual(
            outcome.score.classes.filter { $0 == .lateCommit }.count, 3,
            "three of the four boundaries are late")
        XCTAssertEqual(
            outcome.score.classes.filter { $0 == .correct }.count, 1,
            "the near-instant tail boundary is within tolerance — correct")
    }
}