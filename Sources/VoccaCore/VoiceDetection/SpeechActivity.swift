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

/// The VAD seam's frame-level answer: is this frame speech or silence?
///
/// Exactly two cases, by design — a caller's `switch` is exhaustive today and breaks at
/// compile time if the vocabulary ever grows (the `plan_20260915.md` compile pin). The
/// **stateful** decision — which state a frame flips to — lives in the ``VoiceActivityDetector``
/// implementation, not here: ``EnergyVAD`` (the pure fallback in `VoccaCore`) and the
/// `SileroVAD` adapter (the `sdk-adapters` aspect, env-gated) both answer through this
/// vocabulary, and callers never branch on which one they hold.
public enum SpeechActivity: Sendable, Hashable {
    /// No speech evidence in the current state: silence — or the state has not yet flipped
    /// into speech.
    case silence

    /// The detector's state is speech: a flip has happened, or the frame sustained it.
    case speech
}