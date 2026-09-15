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

/// The pluggable voice-activity boundary (`ARCHITECTURE.md:262-263`): a per-frame
/// speech/silence decision over the capture's own buffer type.
///
/// Every VAD adapter is this protocol and nothing else: ``EnergyVAD`` (the pure fallback in
/// `VoccaCore`, deterministic and headless — CI's implementation) and the `SileroVAD` adapter
/// (the `sdk-adapters` aspect, env-gated). The seam answers **one question per frame** — is
/// this frame speech or silence — and the frame is the seam's only input besides the carried
/// configuration.
///
/// ## The seam's contract
///
/// - **Synchronous, no actor hop.** The barge-in loop is synchronous and owner-isolated (the
///   `SessionMachine` precedent), and VAD runs per frame on the capture path — a 30 ms frame
///   decision cannot afford an actor hop. If the SDK forces an async adapter surface, that is
///   the `sdk-adapters` aspect's problem at its seam, not this one's.
/// - **The decision is over the present samples only.** ``AudioBuffer/missingSampleCount``
///   never reaches the decision — completeness is the ASR seam's concern
///   (`AudioBuffer.swift:50-58`), not VAD's.
/// - **Stateful by design.** Hysteresis (S1) is inherently stateful; the seam is `mutating`
///   because a struct keeps that state `Sendable` honestly — no `@unchecked` anywhere. The
///   owner holds `var detector: any VoiceActivityDetector`; a future class adapter satisfies a
///   `mutating` requirement vacuously.
/// - **Callers never branch on implementation.** The seam never names an engine: a caller
///   drives the existential and cannot tell `EnergyVAD` from `SileroVAD` — the family lint
///   (``VoiceDetectionSeamBoundaryTests``) confines both implementations to their own files so
///   a decision cannot quietly move somewhere CI cannot see it.
/// - **No identity.** The seam answers a yes/no question; attribution lives on the ASR/TTS
///   seams. If the loop needs attribution it can add it in `barge-in-loop` — recorded, not
///   added here.
public protocol VoiceActivityDetector: Sendable {
    /// The hysteresis the detector classifies with. Carried on the seam — callers tune the VAD
    /// through it, never around it.
    var configuration: VADConfiguration { get }

    /// Classifies one frame: the frame's evidence is accumulated against ``configuration`` and
    /// the current state is returned.
    ///
    /// An empty frame carries no evidence, accumulates nothing, and returns the current state.
    /// A frame whose RMS falls in the dead zone `[offsetRMS, onsetRMS)` also accumulates
    /// nothing. The first state is `.silence`.
    mutating func classify(_ frame: AudioBuffer) -> SpeechActivity
}