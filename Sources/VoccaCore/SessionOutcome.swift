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
/// This is where "a transcript is never lost" stops being a rule someone has to remember. Every
/// terminal transition hands its captured audio downstream, and the single exception is the user
/// pressing Escape, which is an instruction rather than an accident.
///
/// ## Why this is a struct wrapping an enum
///
/// The obvious shape — a public enum with `completed` and `cancelled` cases — does not work, and
/// the first version of this file was that shape. A public enum has publicly constructible cases,
/// so every call site picks its own and nothing ties the case to the reason. This compiled clean
/// under strict concurrency, in exactly the single-funnel shape the aspect spec asks task 4 to
/// write:
///
/// ```swift
/// mutating func endSession(reason: EndReason) -> SessionOutcome<[Int]> {
///     switch reason {
///     case .retained(.ceilingReached), .retained(.tapDisabled):
///         buffer = []
///         return .cancelled          // audio discarded, and the user never asked
///     ...
/// ```
///
/// The refactor does not need anywhere to *put* the reason — it drops it. Requiring an `Audio`
/// value on `completed` does not help either, because the caller chooses the generic parameter:
/// `SessionOutcome<[Int]?>.completed(reason:, audio: nil)` and `SessionOutcome<Void>` both satisfy
/// "requires an audio value" while carrying nothing.
///
/// So the freedom to pick a case is removed. ``Content`` can only be built by `init(_:)`, which is
/// `private` — and `private` at type scope is *file*-scoped, so the state machine that will live in
/// a sibling file of this same module cannot reach it either. The one way to construct an outcome
/// is ``make(reason:audio:)``, which switches exhaustively over ``EndReason``. The reason-to-fate
/// mapping therefore exists in exactly one place, and a new stop rule added to
/// ``RetainedEndReason`` lands inside `.retained`, where it is handed its audio automatically.
///
/// ## What this still does not prevent
///
/// A caller can pass the wrong reason: `make(reason: .userCancelled, audio: buffer)` from a
/// ceiling-expiry path does discard the audio. That is a false statement on one visible line rather
/// than a value silently dropped, and no type can tell a lie about the reason from the truth. It is
/// the residual, and it is far smaller than what it replaces.
///
/// Generic over `Audio` because the captured buffer's type belongs to `VoccaAudio`, and this module
/// imports nothing that can record. The generic parameter is how the obligation is stated here
/// without the dependency.
public struct SessionOutcome<Audio: Sendable>: Sendable {

    /// The two fates. Constructible only through ``SessionOutcome/make(reason:audio:)`` — see the
    /// type's documentation for why the cases are not API anyone can select.
    public enum Content: Sendable {
        /// The session ended for one of the stop rules, and here is what it captured.
        case completed(reason: RetainedEndReason, audio: Audio)

        /// The user asked to abandon the session. There is nothing to hand on, by construction:
        /// this case carries no ``RetainedEndReason`` and no audio, so no stop rule can be routed
        /// through it and no buffer can be dropped into it.
        case cancelled
    }

    public let content: Content

    /// Private so that ``Content`` cannot be chosen at a call site — not from another module, and
    /// not from another file of `VoccaCore`.
    private init(_ content: Content) {
        self.content = content
    }

    /// The only way to build an outcome: total over ``EndReason``, and reviewed once.
    ///
    /// `audio` is an autoclosure so that cancellation never evaluates it. Discarding a buffer and
    /// never asking for one are different things, and this is the one path where that difference is
    /// real.
    public static func make(
        reason: EndReason, audio: @autoclosure () -> Audio
    ) -> SessionOutcome {
        switch reason {
        case .retained(let retained):
            return SessionOutcome(.completed(reason: retained, audio: audio()))
        case .userCancelled:
            return SessionOutcome(.cancelled)
        }
    }
}

extension SessionOutcome: Equatable where Audio: Equatable {}
extension SessionOutcome.Content: Equatable where Audio: Equatable {}
