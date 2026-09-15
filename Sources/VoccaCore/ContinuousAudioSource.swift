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

/// The continuous microphone, as the voice loop is permitted to know it: **open it, close it,
/// take the chunk stream.**
///
/// `streaming-capture` of `turn-taking-barge-in` (C10 — the P3 voice loop). The loop's capture is
/// **continuous, never started at interrupt time**: the microphone is open for the loop's whole
/// life and chunks arrive on a timer, so the lifecycle is a `start()`/`stop()` pair — not the
/// per-session pull of ``SessionAudioSource``, which is **not extended, not renamed, not touched**
/// by this seam (the plan's decision (a); `docs/planning/turn-taking-barge-in/streaming-capture/
/// plan_20260915.md`). Conforming a continuous source to ``SessionAudioSource`` would require it
/// to satisfy, per session-less life, the machine-custody contracts that protocol's one
/// conformance is guaranteed by its session machine's single funnel — "called exactly once for
/// every `beginCapture()` that returned `.opened`" and the trap-on-failure release obligation —
/// which the voice loop does not have and must not fake. `endCapture() -> Buffer` is a hand-over;
/// the loop needs a stream it can stop.
///
/// ## Ownership: one instance, one microphone
///
/// One instance owns one microphone. A second `start()` while the first stream is live is refused
/// (``ContinuousAudioSourceError/alreadyStarted``): a second stream would be a second consumer on
/// one ring, the single-producer/single-consumer violation the ring's warrant forbids. `stop()`
/// is idempotent and ends the stream, and the conformance releases the device on **every**
/// terminal path — a stream that ends is never a microphone that stayed open.
///
/// ## The seam family, and the interim state
///
/// The seam doctrine's "a seam with one implementation is not a seam" applies to the *family*:
/// the capture family has two implementations at ship — `MicrophoneSource` (push-to-talk, behind
/// ``SessionAudioSource``) and `StreamingCapture` (continuous, behind this protocol). This
/// protocol itself has one conformance, and that interim state is recorded here, honestly — no
/// second continuous engine is planned.
public protocol ContinuousAudioSource: AnyObject {
    /// Open the microphone and return the chunk stream. Throws once per start attempt; see
    /// ``ContinuousAudioSourceError``.
    func start() throws -> AsyncStream<AudioBuffer>

    /// Close the microphone and end the stream. Idempotent; a no-op before `start()`.
    func stop()
}

/// Everything that can go wrong opening the continuous microphone.
public enum ContinuousAudioSourceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A second `start()` while the first stream is live. The ownership refusal: a second stream
    /// would be a second consumer on one ring, the single-producer/single-consumer violation the
    /// ring's warrant forbids.
    case alreadyStarted

    /// The graph refused to open — the ``CaptureStart/unavailable`` analogue; the loop maps it
    /// the way the machine maps that case.
    case unavailable

    public var description: String {
        switch self {
        case .alreadyStarted:
            return "the continuous microphone is already open — one instance owns one stream"
        case .unavailable:
            return "the microphone refused to open"
        }
    }
}