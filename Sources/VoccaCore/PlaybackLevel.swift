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

/// The N2 duck knob, as plain data — the level a barge-in ducks to and the ramp it ducks over,
/// tunable by C11 without touching the loop (`PRODUCT_SPEC.md` N2, the "−6 dB-ish" duck).
public struct PlaybackLevel: Sendable, Hashable {
    /// The duck target, 0...1. `0.5` ≈ −6.02 dB — the N2 "−6 dB-ish" as a number.
    public var duckGain: Double

    /// The duck ramp, `> 0`; the default is 20 ms, which fits the recorded barge-in
    /// decomposition (`PlaybackEngine`).
    public var rampDuration: Duration

    /// The shipped duck: −6 dB-ish over 20 ms.
    public static let `default` = PlaybackLevel(duckGain: 0.5, rampDuration: .milliseconds(20))

    /// Whether this level can describe a gain: a finite `duckGain` in `0...1` and a positive
    /// ramp. `SystemPlayback.init` traps on an invalid level — loud by construction, the
    /// `AudioBuffer` precedent — and this predicate is the tested rule.
    public var isValid: Bool {
        duckGain.isFinite && (0...1).contains(duckGain) && rampDuration > .zero
    }

    public init(duckGain: Double, rampDuration: Duration) {
        self.duckGain = duckGain
        self.rampDuration = rampDuration
    }
}