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

/// The VAD's hysteresis, carried as plain data (S1) from the composition root.
///
/// Two levels plus two hold times: `onsetRMS` is the level at which a frame counts as
/// **speech evidence**, `offsetRMS` the level below which it counts as **silence evidence**,
/// and `[offsetRMS, onsetRMS)` is the dead zone where no evidence accumulates. A flip
/// (silence → speech) needs `minimumSpeech` **seconds of continuous speech evidence**; the
/// opposite flip needs `minimumSilence` seconds of continuous silence evidence. The two levels
/// are what make the detector *hysteretic* — it cannot chatter on a level hovering near one
/// boundary, because the boundary it must cross back over is lower (or higher) than the one it
/// crossed.
///
/// Plain data, `Sendable + Hashable`: the composition root tunes it, the ``VoiceActivityDetector``
/// implementations consume it, and both the `EnergyVAD` fallback and the `SileroVAD` adapter
/// (whose FluidAudio surface carries its own `VadSegmentationConfig` — the `sdk-adapters`
/// aspect translates) can be tuned together in the env-gated suite. Hold times are durations in
/// seconds, converted to samples at an implementation's init, so flips are chunk-shape-invariant.
public struct VADConfiguration: Sendable, Hashable {
    /// A frame whose RMS is **≥** this counts as speech evidence.
    public let onsetRMS: Float

    /// A frame whose RMS is **<** this counts as silence evidence. Frames in
    /// `[offsetRMS, onsetRMS)` are the dead zone: no evidence accumulates.
    public let offsetRMS: Float

    /// Seconds of continuous speech evidence required to flip silence → speech.
    public let minimumSpeech: Double

    /// Seconds of continuous silence evidence required to flip speech → silence.
    public let minimumSilence: Double

    public init(
        onsetRMS: Float, offsetRMS: Float, minimumSpeech: Double, minimumSilence: Double
    ) {
        precondition(
            onsetRMS > offsetRMS,
            "onsetRMS \(onsetRMS) must exceed offsetRMS \(offsetRMS) — without a dead zone the "
                + "detector would chatter on a level hovering near one boundary")
        precondition(
            onsetRMS > 0,
            "onsetRMS must be positive — a zero onset would classify silence itself as speech evidence")
        precondition(
            offsetRMS >= 0,
            "offsetRMS must be non-negative — the producer's amplitude convention is -1.0...1.0")
        precondition(
            minimumSpeech > 0,
            "minimumSpeech must be positive — a zero hold would flip on a single frame")
        precondition(
            minimumSilence > 0,
            "minimumSilence must be positive — a zero hold would flip on a single frame")
        self.onsetRMS = onsetRMS
        self.offsetRMS = offsetRMS
        self.minimumSpeech = minimumSpeech
        self.minimumSilence = minimumSilence
    }
}