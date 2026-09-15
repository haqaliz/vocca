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

/// The echo gate (`ARCHITECTURE.md:573`, R7): a hard gate discarding capture whose energy
/// correlates with the synthesizer's output within the playback window, plus known-output
/// reference cancellation as the second line. Pure, headless, stdlib-only — synthetic
/// overlapped signals gate deterministically, and **silence during playback never gates**.
///
/// The loop's feed path owns the gate's composition: the capture-side filter sits between
/// capture and VAD, which in this design is inside ``TurnTakingLoop/feed(_:)``. This struct
/// is the pure decision that composition is built on.
///
/// ## The decision (`decision(capture:reference:)`)
///
/// 1. **Silence floor first:** `rms(capture) < 0.02` → `.accept(nil)` — silence during
///    playback **never gates** (and never invokes cancellation). Empty inputs are vacuous
///    accepts: nothing to correlate against is an answer, not a discard.
/// 2. **Correlation:** `ρ = Σ(c·r) / (√Σc² · √Σr²)` over the trailing `min(c.count,
///    r.count)` samples — tail-aligned, the freshest reference. Acoustic-latency alignment
///    is O3/SMOKE-133 territory, recorded, never guessed here.
/// 3. `ρ ≥ 0.90` → `.discard` (a scaled copy of the reference correlates at 1.0 whatever
///    the gain — the pure-echo case).
/// 4. `ρ < 0.90` → the **reference-cancellation line** (Phase 3): compute the residue
///    ``EchoGate/residue(capture:reference:gain:)`` and accept it as the classification
///    signal **iff both** `rms(residue) ≥ 0.02` (the EnergyVAD offset twin — a
///    silence-floor residue is not speech) **and** `rms(residue) ≥ 0.15 · rms(capture)`
///    (the residue is a meaningful fraction of what arrived — recovered user speech, not
///    cancellation leftovers) → `.accept(samples: residue)`; otherwise `.discard`. One
///    condition alone is not enough: a gain-mismatched echo (echo at 0.30 against α = 0.90)
///    leaves a residue of −0.60·r, which passes the absolute floor but is not user speech;
///    only a residue that is both loud enough and a real fraction of what arrived is
///    classified. The `.accept(nil)` case survives only for the silence-floor and
///    no-reference paths — that is what "silence during playback never gates" means
///    mechanically.
///
/// ## The pinned numbers, and the margin doctrine
///
/// `0.90` (the correlation threshold), `0.02` (the silence floor), `0.15` (the residue
/// ratio), and the injected `gain` (default `0.90` — the loop's estimate of the echo path
/// gain) are the gate's four constants. Every synthetic fixture row in `EchoGateTests`
/// carries ≥0.05 margin against `ρ = 0.90`, the `0.02` floor and the `0.15` ratio; boundary
/// equality is Float-ulp territory and deliberately not pinned. The **honest limit** is
/// recorded, not improved: an overwhelmingly mixed echo (`ρ ≥ 0.90`) is lost to the hard
/// gate; whether real speakers need more than reference cancellation is
/// O3/`ARCHITECTURE.md:727` — SMOKE 133's question, never this gate's claim.
public struct EchoGate: Sendable, Equatable {
    /// The loop's injected estimate of the echo path gain, consumed by the cancellation line.
    public let gain: Double

    /// The default estimate: 0.90 — the known-output reference is expected to arrive at
    /// nearly its played level on the capture side.
    public static let defaultGain: Double = 0.90

    public init(gain: Double = EchoGate.defaultGain) {
        self.gain = gain
    }

    /// The gate's answer for one capture frame against the held reference.
    ///
    /// `.accept(samples:)` — `nil` means classify the raw frame, non-nil means classify the
    /// reference-cancelled residue.
    public enum EchoGateDecision: Sendable, Equatable {
        /// The frame is the loop's own output — drop it before the VAD sees it.
        case discard

        /// The frame passes the gate: classify the raw frame (`nil`) or the residue (non-nil).
        case accept(samples: [Float]?)
    }

    /// The gate's decision for `capture` against the trailing `reference`.
    ///
    /// `gain` defaults to ``EchoGate/defaultGain`` — the loop passes its injected estimate.
    public static func decision(
        capture: [Float], reference: [Float], gain: Double = EchoGate.defaultGain
    ) -> EchoGateDecision {
        guard !capture.isEmpty, !reference.isEmpty else { return .accept(samples: nil) }

        let captureRMS = rms(capture)
        // Silence floor first: silence during playback never gates, even with a hot reference.
        guard captureRMS >= 0.02 else { return .accept(samples: nil) }

        let rho = correlation(capture: capture, reference: reference)
        // A zero-energy reference correlates to NaN — the vacuous accept.
        guard rho.isFinite else { return .accept(samples: nil) }

        if rho >= 0.90 {
            return .discard
        }

        // The reference-cancellation line: recover user speech under a ducked echo.
        let cancelled = residue(capture: capture, reference: reference, gain: gain)
        let residueRMS = rms(cancelled)
        if residueRMS >= 0.02 && residueRMS >= 0.15 * captureRMS {
            return .accept(samples: cancelled)
        }
        return .discard
    }

    /// The known-output reference cancellation: `capture − gain·reference`, elementwise over
    /// the **trailing** `min(count)` pairing (the freshest reference; a reference longer than
    /// the capture pairs its own tail). Samples with no reference to pair against are
    /// unchanged — with `gain = 0` the capture comes back untouched (the identity).
    public static func residue(
        capture: [Float], reference: [Float], gain: Double = EchoGate.defaultGain
    ) -> [Float] {
        guard !capture.isEmpty, !reference.isEmpty else { return capture }
        let paired = min(capture.count, reference.count)
        guard paired > 0 else { return capture }

        var result = capture
        let captureOffset = capture.count - paired
        let referenceOffset = reference.count - paired
        for index in 0..<paired {
            result[captureOffset + index] -= Float(gain) * reference[referenceOffset + index]
        }
        return result
    }

    /// `sqrt(mean(samples²))` — stdlib only.
    private static func rms(_ samples: [Float]) -> Float {
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// Pearson-style correlation over the trailing `min(count)` samples:
    /// `Σ(c·r) / (√Σc² · √Σr²)`. `NaN` when either side has zero energy.
    private static func correlation(capture: [Float], reference: [Float]) -> Float {
        let paired = min(capture.count, reference.count)
        var dot: Float = 0
        var captureEnergy: Float = 0
        var referenceEnergy: Float = 0
        for index in 0..<paired {
            let c = capture[capture.count - paired + index]
            let r = reference[reference.count - paired + index]
            dot += c * r
            captureEnergy += c * c
            referenceEnergy += r * r
        }
        return dot / (captureEnergy.squareRoot() * referenceEnergy.squareRoot())
    }
}