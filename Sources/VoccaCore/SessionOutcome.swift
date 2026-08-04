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

/// What a finished session produced.
///
/// This is where "a transcript is never lost" stops being a rule someone has to remember. Every
/// terminal transition hands its captured audio downstream, and the single exception is the user
/// pressing Escape, which is an instruction rather than an accident.
///
/// ## Why this is a struct wrapping a sealed enum
///
/// The obvious shape — a public enum with `completed` and `cancelled` cases — does not work, and
/// the first version of this file was that shape. A public enum has publicly constructible cases,
/// so every call site picks its own and nothing ties the case to the reason. This compiled clean
/// under strict concurrency, in exactly the single-funnel shape the aspect spec asks task 4 to
/// write:
///
/// ```swift
/// mutating func endSession(reason: EndReason) -> SessionOutcome<Buffer> {
///     switch reason {
///     case .retained(.ceilingReached), .retained(.tapDisabled):
///         buffer = .empty
///         return .cancelled          // audio discarded, and the user never asked
///     ...
/// ```
///
/// Making `init` private closed *that* signature and no more. The same funnel typed
/// `-> SessionOutcome<Buffer>.Content` compiled again — five characters, an ordinary-looking
/// return type, and behaviourally identical downstream because every consumer destructures
/// `.content` anyway. A second route did too: `private` is file-scoped, so an
/// `extension SessionOutcome { public init(escapeHatch: Content) { self.content = escapeHatch } }`
/// in a sibling file of this module assigned the stored property directly. Both are the original
/// hole wearing a different hat, and both are why the cases now carry a ``Seal``: a token whose
/// initializer only this file can reach.
///
/// So the freedom to pick a case is gone. ``make(reason:audio:)`` switches exhaustively over
/// ``EndReason``, the mapping from reason to fate exists in exactly one place, and a new stop rule
/// added to ``RetainedEndReason`` lands inside `.retained`, where it is handed its audio
/// automatically.
///
/// Pattern matching is unaffected on the discard side — `case .cancelled:` and
/// `if case .cancelled = outcome.content` both still compile from anywhere. Reading a completed
/// outcome costs one `_`: `case .completed(let reason, let audio, _)`.
///
/// ## What this still does not prevent
///
/// Two residuals, both far narrower than what they replace, and both requiring a deliberate line
/// rather than an ordinary-looking signature:
///
/// - **A false reason.** `make(reason: .userCancelled, audio: buffer)` called from a ceiling-expiry
///   path does discard. No type can tell a lie about the reason from the truth; what it costs is
///   one visible false statement instead of a silently dropped value.
/// - **Obtaining a seal.** A caller can bind one out of a real outcome — from either case,
///   `if case .cancelled(let seal) = …` or `.completed(_, _, let seal)` — and mint a forged
///   `Content` with it. Obtaining a real outcome first is not even necessary: ``Seal`` is an empty
///   struct, so it is zero bytes wide, and `unsafeBitCast((), to: Seal.self)` produces one from
///   nothing. What the token buys is not impossibility; it is that every route reads as forgery at
///   a glance, in a deliberate line, instead of hiding behind an ordinary-looking signature.
///
/// See ``CapturedAudio`` for the third one that used to be here — `Optional` satisfying `Audio` —
/// and how the constraint closes it.
public struct SessionOutcome<Audio: CapturedAudio>: Sendable {

    /// Proof that a ``Content`` was minted by ``SessionOutcome/make(reason:audio:)``.
    ///
    /// Its initializer is `fileprivate`, so no other file — in this module or any other — can
    /// produce one **without an unsafe primitive**, and therefore no other file can construct a
    /// `Content` at all. That is what makes `make` the only route rather than merely the intended
    /// one. The qualifier is not pedantry: this type is empty and therefore zero bytes wide, so
    /// `unsafeBitCast((), to: Seal.self)` still mints one. See the owning type's "What this still
    /// does not prevent".
    ///
    /// `Hashable`, not just `Sendable`: `Content`'s `Equatable` synthesis needs every payload to
    /// be `Equatable`, and the synthesis fails without it.
    public struct Seal: Sendable, Hashable {
        fileprivate init() {}
    }

    /// The two fates. Constructible only through ``SessionOutcome/make(reason:audio:)``, because
    /// both cases demand a ``Seal`` — see the type's documentation for the two routes that were
    /// open before the seal existed.
    public enum Content: Sendable {
        /// The session ended for one of the stop rules, and here is what it captured.
        case completed(reason: RetainedEndReason, audio: Audio, seal: Seal)

        /// The user asked to abandon the session. There is nothing to hand on, by construction:
        /// this case carries no ``RetainedEndReason`` and no audio, so no stop rule can be routed
        /// through it and no buffer can be dropped into it.
        case cancelled(Seal)
    }

    public let content: Content

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
            return SessionOutcome(.completed(reason: retained, audio: audio(), seal: Seal()))
        case .userCancelled:
            return SessionOutcome(.cancelled(Seal()))
        }
    }
}

extension SessionOutcome: Equatable where Audio: Equatable {}
extension SessionOutcome.Content: Equatable where Audio: Equatable {}
