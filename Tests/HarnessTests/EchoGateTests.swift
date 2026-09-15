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

/// The echo gate's unit suite (`barge-in-loop/plan_20260915.md` Phase 3): the correlation
/// pins, the silence pins, and the **synthetic overlapped rows** — every expected value
/// hand-computed, never read back from the implementation (the voice-detection fixture-table
/// discipline). Reference and speech are **unit-RMS sines** (amplitude √2), so all the
/// arithmetic below is exact:
///
/// - `pure-echo` (capture = 0.85·ref): ρ = 1.0 ≥ 0.90 → discard.
/// - `mixed-ducked-overlap` (capture = 0.30·ref + 0.40·speech): rms = √(0.09+0.16) = 0.5;
///   ρ = 0.3/0.5 = 0.6 < 0.90 → the residue = 0.40·speech − 0.60·ref, rms = √(0.16+0.36) ≈
///   0.721 — both floors pass (≥ 0.02, and 0.721 ≥ 0.15·0.5 = 0.075) → accept(residue).
///   **The user's words survive under a ducked echo — the row the cancellation line
///   exists for.** (RED against the Phase-2 gate, which returned `.accept(nil)`.)
/// - `overwhelming-echo` (capture = 0.92·ref + 0.30·speech): rms = √(0.8464+0.09) ≈ 0.968;
///   ρ ≈ 0.951 ≥ 0.90 → discard — the deterministic gate's honest limit, with the ≥0.05
///   margin (0.951 − 0.90).
/// - `near-pure-echo-beneath-noise-floor` (capture = 0.30·ref + 0.01·noise): ρ ≈ 0.9994 ≥
///   0.90 → discard — a noise floor does not rescue an echo frame; the 0.02 silence floor
///   protects true silence only.
/// - `silence-with-hot-reference` (capture = zeros, reference loud): rms(capture) < 0.02 →
///   accept(nil) — **silence during playback never gates**, even with a hot reference (the
///   PRD pin verbatim).
///
/// Every row carries ≥0.05 margin against ρ = 0.90, the 0.02 silence floor and the 0.15
/// residue ratio; boundary equality is Float-ulp territory and deliberately not pinned.
final class EchoGateTests: XCTestCase {

    /// 1000-sample frames at 16 kHz (62.5 ms).
    private static let frameSamples = 1000

    /// A unit-RMS sine: amplitude √2, so mean(samples²) = 1 exactly over whole cycles.
    private static func unitRMSsine(frequency: Double, samples: Int = frameSamples) -> [Float] {
        (0..<samples).map { index in
            Float(2.0.squareRoot() * sin(2 * Double.pi * frequency * Double(index) / 16_000))
        }
    }

    /// The known-output reference — 440 Hz.
    private static var reference: [Float] { unitRMSsine(frequency: 440) }

    /// The orthogonal "user" speech — 880 Hz, ρ(reference, speech) ≈ 0.
    private static var speech: [Float] { unitRMSsine(frequency: 880) }

    /// The third orthogonal sine for the noise floor row — 1320 Hz.
    private static var noise: [Float] { unitRMSsine(frequency: 1320) }

    private static func scaled(_ signal: [Float], by gain: Float) -> [Float] {
        signal.map { $0 * gain }
    }

    private static func mixed(_ a: [Float], _ gainA: Float, _ b: [Float], _ gainB: Float) -> [Float] {
        zip(a, b).map { $0 * gainA + $1 * gainB }
    }

    /// The RMS of the samples, computed in the test (the formula pin, never read back).
    private static func rms(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    // MARK: - The correlation pins

    /// Identical frames correlate at 1.0 → discard.
    func testIdenticalFramesDiscard() {
        XCTAssertEqual(
            EchoGate.decision(capture: Self.reference, reference: Self.reference), .discard,
            "an identical frame is the loop's own output, ρ = 1.0")
    }

    /// A scaled copy discards at any gain — correlation is gain-invariant.
    func testAScaledCopyDiscardsAtAnyGain() {
        XCTAssertEqual(
            EchoGate.decision(capture: Self.scaled(Self.reference, by: 0.85), reference: Self.reference),
            .discard,
            "a scaled copy correlates at 1.0 whatever the gain — the pure-echo case")
    }

    /// Orthogonal sines (440 vs 880) → ρ ≈ 0 → the residue path: the orthogonal speech is
    /// recovered as the reference-cancelled residue, which both floors pass.
    func testOrthogonalSpeechTakesTheResiduePath() {
        let decision = EchoGate.decision(capture: Self.speech, reference: Self.reference)
        guard case .accept(let samples) = decision, let residue = samples else {
            XCTFail("orthogonal speech must be accepted with the residue — got \(decision)")
            return
        }
        let expected = zip(Self.speech, Self.reference).map { $0 - Float(0.9) * $1 }
        XCTAssertEqual(
            residue, expected,
            "the residue is capture − 0.9·reference, elementwise")
    }

    /// Silence capture (rms < 0.02) with a loud reference → `.accept(nil)` — silence during
    /// playback **never gates**, even with a hot reference.
    func testSilenceCaptureWithALoudReferenceAcceptsTheRawFrame() {
        let capture = [Float](repeating: 0, count: Self.frameSamples)
        XCTAssertEqual(
            EchoGate.decision(capture: capture, reference: Self.reference),
            .accept(samples: nil),
            "silence during playback never gates — the 0.02 silence floor comes first")
    }

    // MARK: - The synthetic overlapped rows

    /// `pure-echo`: capture = 0.85 × reference → ρ = 1.0 ≥ 0.90 → discard (correlation is
    /// gain-invariant — a scaled copy at any gain discards).
    func testPureEchoDiscards() {
        let capture = Self.scaled(Self.reference, by: 0.85)
        XCTAssertEqual(
            EchoGate.decision(capture: capture, reference: Self.reference), .discard,
            "the pure-echo frame is the loop's own output")
    }

    /// `mixed-ducked-overlap`: capture = 0.30·ref + 0.40·speech → rms = 0.5, ρ = 0.6 < 0.90
    /// → residue = 0.40·speech − 0.60·ref (rms ≈ 0.721, both floors pass) → accept(residue).
    /// The user's words survive under a ducked echo — the row the cancellation line exists
    /// for.
    func testMixedDuckedOverlapAcceptsTheResidue() {
        let capture = Self.mixed(Self.reference, 0.30, Self.speech, 0.40)
        let decision = EchoGate.decision(capture: capture, reference: Self.reference)
        guard case .accept(let samples) = decision, let residue = samples else {
            XCTFail("the mixed frame must be accepted with the residue — got \(decision)")
            return
        }
        XCTAssertEqual(
            Self.rms(capture), 0.5, accuracy: 0.001,
            "rms = √(0.09 + 0.16) — the hand-computed capture level")
        let expected = zip(capture, Self.reference).map { $0 - Float(0.9) * $1 }
        XCTAssertEqual(
            residue, expected,
            "the residue is capture − 0.9·reference, elementwise")
        XCTAssertEqual(
            Self.rms(residue), 0.721, accuracy: 0.001,
            "rms(residue) = √(0.16 + 0.36) ≈ 0.721 — both floors pass (≥ 0.02 and "
                + "≥ 0.15·0.5 = 0.075)")
    }

    /// `overwhelming-echo`: capture = 0.92·ref + 0.30·speech → ρ ≈ 0.951 ≥ 0.90 → discard —
    /// the deterministic gate's honest limit, pinned with its ≥0.05 margin.
    func testOverwhelmingEchoDiscards() {
        let capture = Self.mixed(Self.reference, 0.92, Self.speech, 0.30)
        XCTAssertEqual(
            EchoGate.decision(capture: capture, reference: Self.reference), .discard,
            "an overwhelmingly mixed frame is lost to the hard gate — O3/SMOKE 133's question, "
                + "never silently improved")
    }

    /// `near-pure-echo-beneath-noise-floor`: capture = 0.30·ref + 0.01·noise → ρ ≈ 0.9994 →
    /// discard — a noise floor does not rescue an echo frame.
    func testNearPureEchoBeneathTheNoiseFloorDiscards() {
        let capture = Self.mixed(Self.reference, 0.30, Self.noise, 0.01)
        XCTAssertEqual(
            EchoGate.decision(capture: capture, reference: Self.reference), .discard,
            "a noise floor does not rescue an echo frame — the 0.02 silence floor protects "
                + "true silence only")
    }

    /// `silence-with-hot-reference`: capture = zeros → `.accept(nil)` — the PRD pin verbatim.
    func testSilenceWithAHotReferenceNeverGates() {
        let capture = [Float](repeating: 0, count: Self.frameSamples)
        XCTAssertEqual(
            EchoGate.decision(capture: capture, reference: Self.reference),
            .accept(samples: nil),
            "silence during playback never gates, even with a hot reference")
    }

    // MARK: - The residue function

    /// The residue's exact values for the 0.30/0.40 row — elementwise
    /// `capture − 0.9·reference`, and `gain = 0` is the identity.
    func testResidueIsCaptureMinusGainTimesReference() {
        let capture = Self.mixed(Self.reference, 0.30, Self.speech, 0.40)
        let residue = EchoGate.residue(capture: capture, reference: Self.reference, gain: 0.90)
        let expected = zip(capture, Self.reference).map { $0 - Float(0.9) * $1 }
        XCTAssertEqual(
            residue, expected,
            "residue = capture − gain·reference, elementwise")

        let identity = EchoGate.residue(capture: capture, reference: Self.reference, gain: 0)
        XCTAssertEqual(
            identity, capture,
            "gain = 0 leaves the capture unchanged — the identity")
    }

    /// A reference longer than the capture pairs its own **tail** — the freshest reference.
    func testResidueTailAlignsALongerReference() {
        let capture = Self.speech  // 1000 samples
        let longReference = Self.reference + Self.reference  // 2000 samples
        let residue = EchoGate.residue(capture: capture, reference: longReference, gain: 1.0)
        let expected = zip(capture, longReference.suffix(capture.count)).map { $0 - $1 }
        XCTAssertEqual(
            residue, expected,
            "the pairing is trailing — the capture pairs against the reference's last "
                + "\(capture.count) samples")
    }

    // MARK: - The vacuous paths

    /// An empty reference is a vacuous accept — nothing to correlate against is an answer.
    func testAnEmptyReferenceAcceptsTheRawFrame() {
        XCTAssertEqual(
            EchoGate.decision(capture: Self.speech, reference: []),
            .accept(samples: nil))
        XCTAssertEqual(
            EchoGate.decision(capture: [], reference: Self.reference),
            .accept(samples: nil))
    }

    /// An empty capture is the silence floor's own vacuous accept.
    func testAnEmptyCaptureAcceptsTheRawFrame() {
        XCTAssertEqual(
            EchoGate.decision(capture: [], reference: []),
            .accept(samples: nil))
    }
}