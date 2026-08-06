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

/// What one input did to the session.
///
/// ``Decision`` says what the *rules* make of one key event; this says what the *machine* did about
/// it, and the two are different by one whole layer — most inputs the rules call `.stop` arrive when
/// there is nothing to stop.
///
/// An enum rather than an optional outcome, for the reason every enum in this module is one: it is
/// switched without a `default:`, so a fifth thing the machine can do has to be given a meaning at
/// every call site instead of quietly landing in someone else's branch.
public enum SessionEffect<Audio: CapturedAudio>: Sendable {
    /// Nothing happened. The input was not one this state had anything to do with — a key-up with
    /// no session behind it, a tick before the deadline, a poll finding the key still held.
    case unchanged

    /// The microphone is open and a session is recording.
    case started

    /// **The hotkey was pressed, the start was decided, and the microphone has not opened yet.**
    ///
    /// Only ``SessionMachine/observe(_:)-(RawKeyEvent)`` returns this, and only under
    /// ``CaptureStartTiming/whenTheOwnerAsks``. The owner owes the machine a
    /// ``SessionMachine/completePendingOpening()``, after which the *real* effect —
    /// ``started``, ``captureUnavailable``, or even ``ended`` if the user let go inside the window —
    /// arrives by whatever route the owner delivers effects.
    ///
    /// **It is a distinct case rather than ``unchanged``, and the measurement is why.**
    /// `AVAudioEngine.start()` costs ~114 ms (see ``CaptureStartTiming``), so this state lasts about
    /// seven display frames — far past the 16 ms `PRODUCT_SPEC.md:71` gives the widget to react.
    /// Reporting `unchanged` for it would tell the widget that a press it must show *did nothing*,
    /// and the user would watch an eighth of a second of no feedback after pressing the hotkey. It
    /// is also simply false: the key has been claimed and a microphone has been asked for.
    case opening

    /// The hotkey was pressed and the microphone did not open, so no session began. Distinct from
    /// ``unchanged`` because the widget has something to say about it and the user needs to hear
    /// it: the alternative is a press that appears to do nothing at all.
    case captureUnavailable

    /// A session ended. **This is the only value in this module that carries a
    /// ``SessionOutcome``**, and the only place one is produced is
    /// `SessionMachine.endSession(reason:)`.
    ///
    /// A caller that drops it drops a transcript, which is why the machine's methods are not
    /// `@discardableResult` and why that annotation is lint-forbidden across `VoccaCore`.
    case ended(SessionOutcome<Audio>)
}

extension SessionEffect: Equatable where Audio: Equatable {}

/// What the machine did about one key event, **and** whether the focused application sees it.
///
/// Two independent facts, exactly as in ``Decision`` and for the same reason: a hotkey press that
/// starts a session must not also type a space into the user's document, and an event Vocca has no
/// interest in must not be eaten on its way to the app that does.
///
/// Only `SessionMachine.observe(_ event: RawKeyEvent)` returns one. Ticks, system triggers, polls and
/// cancellation have no event to propagate, so they return a bare ``SessionEffect`` — a propagation
/// field on those would be a value the caller has to invent an answer for.
public struct SessionResponse<Audio: CapturedAudio>: Sendable {
    public let effect: SessionEffect<Audio>
    public let eventPropagation: EventPropagation

    public init(effect: SessionEffect<Audio>, eventPropagation: EventPropagation) {
        self.effect = effect
        self.eventPropagation = eventPropagation
    }
}

extension SessionResponse: Equatable where Audio: Equatable {}
