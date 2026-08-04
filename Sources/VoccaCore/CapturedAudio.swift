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

/// What a session captured, as this module needs to know it: **not at all**.
///
/// Deliberately empty. `VoccaCore` imports nothing and must never learn what a sample rate is —
/// the buffer type belongs to `VoccaAudio`, and this marker is how ``SessionOutcome`` states "a
/// real buffer goes here" without the dependency.
///
/// ## Why a marker beats an unconstrained generic
///
/// ``SessionOutcome`` used to be generic over any `Sendable`, which meant the caller chose what
/// "audio" was — and `Optional` chose it badly. This compiled, and is the *obvious* way to write a
/// state machine, since a buffer is naturally nil while idle:
///
/// ```swift
/// var buffer: [Float]?                                   // nil while no capture is in flight
/// func endSession(reason: EndReason) -> SessionOutcome<[Float]?> {
///     SessionOutcome.make(reason: reason, audio: buffer)  // .completed(…, audio: nil) — legal
/// }
/// ```
///
/// `.completed(reason: .ceilingReached, audio: nil)` is "ended a session without producing audio",
/// type-approved, and task 4's property test — every reason but `.userCancelled` emits audio
/// exactly once — passes while emitting nothing. `SessionOutcome<Void>` had the same effect.
/// Neither `Optional` nor `Void` conforms to a protocol Vocca owns, so neither satisfies `Audio`
/// any more.
///
/// ## What this does not claim
///
/// It does not make emptiness unrepresentable. A conforming buffer type can be empty, and it
/// **should** be able to be: a 20 ms tap that captures almost nothing is a real session that ended
/// for a real reason, and its outcome is `.completed`, not a discard. What the constraint removes
/// is the case where the *absence* of a buffer satisfies the obligation to produce one.
///
/// A determined caller can still write `extension Optional: CapturedAudio where Wrapped:
/// CapturedAudio {}`. That is a deliberate line in a diff, which is the whole difference between
/// this and the shape above.
public protocol CapturedAudio: Sendable {}
