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

/// A system-level event that must end an in-flight session.
///
/// Delivering these is not this module's job — it decides only that each one is a stop.
public enum SystemTrigger: Sendable, Hashable, CaseIterable {
    /// The machine is about to sleep. Whatever was being said is over.
    case willSleep

    /// The displays slept. Treated as a stop because the user has walked away, and a session
    /// nobody is present for is a hot microphone.
    case screensDidSleep

    /// Fast user switching moved this login session to the background.
    case sessionDidResignActive

    /// The audio route changed underneath the capture — a device unplugged, a default output
    /// switched. The captured stream is no longer the one the session started with.
    case audioConfigurationChanged

    /// macOS secure input is on (a password field has focus). Keystrokes are not observable, so
    /// the key-up that would end this session may never be seen.
    case secureInputEnabled
}

/// A reason a session ended **with audio that must be handed downstream**.
///
/// The six stop rules of hold-to-talk, plus toggle mode's. Every one of them ends a session the
/// user did not ask to abandon, so every one of them owes its captured audio to whatever comes
/// next: the invariant is that a transcript is never lost, and an unexpectedly-ended session yields
/// its audio to custody rather than discarding it.
///
/// That obligation is enforced by the type, not by discipline. This enum is the only thing
/// ``SessionOutcome/Content/completed(reason:audio:)`` carries, and the only route to it is
/// ``SessionOutcome/make(reason:audio:)``, which is total over ``EndReason`` — so a new stop rule
/// added here is handed its audio automatically and cannot reach the discard path. See
/// ``SessionOutcome`` for why an enum alone was not enough.
public enum RetainedEndReason: Sendable, Hashable {
    /// (a) Key-up on the configured key.
    case keyUp

    /// (b)/(c) The configured modifier is no longer carried by the event's flags. Covers
    /// "released Option before Space", the single likeliest cause of a stuck recording.
    case modifierReleased

    /// (d) The OS disabled the event tap. The key-up is never coming.
    case tapDisabled

    /// (e) The session hit its maximum duration.
    case ceilingReached

    /// (f) A poll of the physical state found the binding no longer held, so an event was missed.
    ///
    /// **Both halves of the binding, under one reason.** The poll reads the key *and* the chord —
    /// ``SessionWatchdog/theBindingIsStillHeld`` — so this covers a key-up that generated no event
    /// and a modifier release whose `.flagsChanged` never arrived. They are not distinguished, and
    /// that is a decision argued where the read is: a second reason would name which half, and this
    /// one is already true of both.
    ///
    /// It stays distinct from ``keyUp`` and ``modifierReleased``, which is the distinction that
    /// earns its keep: those two mean *Vocca was told*, and this one means *Vocca had to ask*. A log
    /// that conflated them would hide the only evidence that events are being dropped.
    case pollDetectedRelease

    /// Toggle mode: the next matching key-*down* arrived while recording.
    ///
    /// Not `.keyUp`. In toggle mode stop rules (a)/(b)/(c) are replaced by "next matching
    /// key-down", and labelling that `.keyUp` would be false about the event that caused it —
    /// exactly the mislabelling the split-enum design exists to prevent. Named here rather than
    /// when toggle mode is implemented, because adding it later means paying the compile-error
    /// cascade in a commit that is about something else.
    case toggledOff

    /// A system event made continuing impossible or wrong.
    case systemEvent(SystemTrigger)
}

extension RetainedEndReason: CaseIterable {
    /// Every retaining reason, with each system trigger enumerated.
    ///
    /// Hand-written because the `systemEvent` payload rules out synthesis — and therefore able to
    /// go stale, which is exactly what `SessionVocabularyTests.testEveryEndReasonAppearsInAllCases`
    /// exists to prevent: it switches over this enum exhaustively, so a new case fails to compile
    /// there until it is added here too.
    public static var allCases: [RetainedEndReason] {
        [
            .keyUp, .modifierReleased, .tapDisabled, .ceilingReached, .pollDetectedRelease,
            .toggledOff,
        ] + SystemTrigger.allCases.map(RetainedEndReason.systemEvent)
    }
}

/// Every reason a session can end.
///
/// Two cases, and the split is the point. `.userCancelled` is the only reason permitted to discard
/// captured audio — the user pressed Escape and explicitly asked for it — and it is separated here
/// from the reasons that are not, so that "which reasons may discard?" is a question the type
/// answers rather than a rule someone has to remember while editing a switch.
///
/// A future stop rule is added to ``RetainedEndReason``, where it lands inside `.retained` and
/// inherits the obligation to hand its audio downstream. This split is necessary but not
/// sufficient on its own: what actually enforces it is that ``SessionOutcome/make(reason:audio:)``
/// is the only constructor of an outcome and switches over this enum exhaustively, in one file.
public enum EndReason: Sendable, Hashable {
    /// One of the six stop rules. The captured audio travels with it.
    case retained(RetainedEndReason)

    /// The user abandoned the session (Escape). The only path on which audio is discarded, and
    /// discarding is the instruction rather than the accident.
    case userCancelled
}

extension EndReason: CaseIterable {
    public static var allCases: [EndReason] {
        RetainedEndReason.allCases.map(EndReason.retained) + [.userCancelled]
    }
}
