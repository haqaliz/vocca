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

/// The pure, headless ``VoiceActivityDetector`` fallback: RMS energy with a two-level
/// hysteresis (onset/offset dead zone) and duration-based hold times.
///
/// The seam's CI implementation — deterministic, stdlib-only, and the loop's default work in
/// the zero-network probe (G6). The `SileroVAD` adapter (FluidAudio, the `sdk-adapters`
/// aspect) is the real implementation; a caller holding `any VoiceActivityDetector` cannot and
/// must not tell them apart.
///
/// ## The rules
///
/// - `rms` = `sqrt(mean(samples²))` via `Float.squareRoot()` — stdlib only.
/// - `rms >= onsetRMS` → **speech evidence**; `rms < offsetRMS` → **silence evidence**;
///   `[offsetRMS, onsetRMS)` → the dead zone, no evidence accumulates (no drift toward either
///   state).
/// - Hold times are converted from seconds to **samples at init**
///   (`Int((seconds * 16_000).rounded())`) — duration-based, so flips are chunk-shape-
///   invariant: any chunking of the same waveform flips at the same cumulative sample count.
/// - **A flip resets both accumulators.** The silence hold starts fresh after a flip to
///   speech, and vice versa — pinned by the `amplitude-ramp` fixture (a flip during frame 3
///   means frame 14, not 13, for the 3200-sample silence hold).
/// - Initial state: `.silence`. An empty frame accumulates nothing and returns the current
///   state. A NaN/±inf RMS satisfies neither comparison, falls in the dead zone, and the state
///   is retained (producer-bug territory, pinned so it is explicit).
///
/// `mutating` state on a struct is `Sendable` by construction under strict concurrency — no
/// `@unchecked` (the house's documented aversion; `StubSynthesizer`'s doc at
/// `SpeechSynthesizerSeamTests.swift:196-199`). The owner holds `var vad: any
/// VoiceActivityDetector`; a future class adapter satisfies the `mutating` requirement
/// vacuously.
public struct EnergyVAD: VoiceActivityDetector {
    /// The hysteresis this instance classifies with.
    public let configuration: VADConfiguration

    /// `minimumSpeech` in samples at the interchange 16 kHz rate — the silence → speech hold.
    private let onsetHoldSamples: Int

    /// `minimumSilence` in samples at the interchange 16 kHz rate — the speech → silence hold.
    private let offsetHoldSamples: Int

    /// Continuous speech-evidence samples accumulated in the current state.
    private var speechEvidenceSamples = 0

    /// Continuous silence-evidence samples accumulated in the current state.
    private var silenceEvidenceSamples = 0

    /// The current state. The initial state is `.silence`; only a completed hold flips it.
    private var state: SpeechActivity = .silence

    public init(configuration: VADConfiguration) {
        self.configuration = configuration
        self.onsetHoldSamples = Int((configuration.minimumSpeech * 16_000).rounded())
        self.offsetHoldSamples = Int((configuration.minimumSilence * 16_000).rounded())
    }

    public mutating func classify(_ frame: AudioBuffer) -> SpeechActivity {
        guard !frame.samples.isEmpty else { return state }
        let rms = Self.rms(of: frame.samples)
        let sampleCount = frame.samples.count
        if rms >= configuration.onsetRMS {
            speechEvidenceSamples += sampleCount
        } else if rms < configuration.offsetRMS {
            silenceEvidenceSamples += sampleCount
        } else {
            // Dead zone [offsetRMS, onsetRMS): no evidence accumulates — the state freezes.
        }
        return flippedState()
    }

    /// The RMS of the samples: `sqrt(mean(samples²))`, stdlib only.
    private static func rms(of samples: [Float]) -> Float {
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// Applies the current state's flip rule: when the state's hold has been met, flip it and
    /// reset **both** accumulators. The state's own hold is the only rule that applies —
    /// silence evidence accumulated in the silence state never flips to speech.
    private mutating func flippedState() -> SpeechActivity {
        switch state {
        case .silence:
            if speechEvidenceSamples >= onsetHoldSamples {
                state = .speech
                speechEvidenceSamples = 0
                silenceEvidenceSamples = 0
            }
        case .speech:
            if silenceEvidenceSamples >= offsetHoldSamples {
                state = .silence
                speechEvidenceSamples = 0
                silenceEvidenceSamples = 0
            }
        }
        return state
    }
}