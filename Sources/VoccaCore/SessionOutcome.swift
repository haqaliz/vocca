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

/// What a finished session produced — **the only way audio leaves one**.
///
/// The shape is the whole argument, so it is worth stating plainly: there is no case that carries
/// audio and throws it away. Discarding is not an operation this type offers; it is what
/// necessarily happens when there is nothing attached, and nothing is attached only on
/// ``cancelled``.
///
/// That makes `.userCancelled` structurally distinct rather than merely handled differently:
///
/// - ``completed(reason:audio:)`` **requires** an `Audio` value. A stop rule cannot end a session
///   without producing one — "forgot to hand the buffer downstream" does not compile.
/// - ``cancelled`` carries no ``RetainedEndReason``, so a future refactor cannot route
///   `.ceilingReached` or a newly-added stop rule down the discarding path. There is nowhere to
///   put the reason, and there is no audio parameter to drop.
///
/// The invariant this exists for: a transcript is never lost. An unexpectedly-ended session yields
/// its audio to custody rather than discarding it, and the single exception — the user pressing
/// Escape — is the one case that cannot be reached from any other reason.
///
/// Generic over `Audio` because the captured buffer's type belongs to `VoccaAudio`, and this
/// module imports nothing that can record. The generic parameter is how the obligation is stated
/// here without the dependency.
public enum SessionOutcome<Audio: Sendable>: Sendable {
    /// The session ended for one of the six stop rules, and here is what it captured.
    case completed(reason: RetainedEndReason, audio: Audio)

    /// The user asked to abandon the session. There is nothing to hand on, by construction.
    case cancelled
}

extension SessionOutcome: Equatable where Audio: Equatable {}
