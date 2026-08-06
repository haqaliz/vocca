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

import VoccaCore

/// **The whole body of the tap's callback, minus the tap.**
///
/// The adapter reads five values off a `CGEvent`, calls this, and turns the answer into the C return
/// value. Everything in between is here, and the reason is the organising constraint of the aspect:
/// this function has a `switch` in it, and a `switch` in `CGEventTapSource.swift` is a branch no CI
/// run can ever take.
///
/// It is not quite pure — it calls the sink, which starts and stops a microphone — but it takes
/// every collaborator as a parameter and reads no clock, so a test drives it with doubles and looks
/// at what came out. That is what makes the following measurable rather than asserted in a comment:
///
/// - the `fn` rule is applied to the event's *own* key code, not to some other field;
/// - the disposition the sink returned comes back **unchanged, in both directions** — the mutation
///   that eats the user's whole keyboard is one hard-coded value away, and this is the closest point
///   to the C ABI that any test can reach;
/// - a disablement reaches the observer and reaches the sink *not at all*, because it is not a
///   keystroke;
/// - and every event that is not ours reaches the focused application.
public enum TapEventDispatch {

    /// Route one observed event, and answer whether the focused application still sees it.
    ///
    /// - Parameters:
    ///   - rawEventType: `CGEventType`'s `rawValue`.
    ///   - rawFlags: `CGEventFlags`' `rawValue`.
    ///   - keyCode: the event's virtual key code. Used both for the session rules and for the `fn`
    ///     rule, which is why it is read from the event rather than from the configuration.
    ///   - isAutorepeat: whether macOS generated this key-down by the key being held.
    ///   - now: the timestamp to stamp on the ``RawKeyEvent``. Passed in rather than read, because
    ///     the caller owns the clock and this owns no I/O.
    ///   - sink: where key events go. `nil` when there is no tap, which is not a state a delivering
    ///     tap can be in — but the answer for it is forced rather than chosen: inherited constraint
    ///     4 is that anything Vocca does not claim reaches the application untouched, and a source
    ///     with nothing to ask claims nothing.
    ///   - observer: where a disablement is reported. **A `nil` costs both halves** — the ending as
    ///     well as the recovery, because both are reached through this one optional — leaving the
    ///     session to be closed by the ~1 s health poll instead of on this callback. Bounded, but not
    ///     free; see ``CGEventTapSource/disablementObserver`` for why it is `nil` at all.
    /// - Returns: what the caller must tell the window server. ``EventPropagation/swallow`` is
    ///   `nil` from a tap callback and ``EventPropagation/passThrough`` is the event itself.
    public static func dispatch(
        rawEventType: UInt32,
        rawFlags: UInt64,
        keyCode: UInt16,
        isAutorepeat: Bool,
        at now: Duration,
        to sink: (any HotkeyEventSink)?,
        reportingDisablementTo observer: (any TapDisablementObserver)?
    ) -> EventPropagation {
        switch TapEventTranslation.classify(rawEventType: rawEventType) {
        case .key(let kind):
            guard let sink else { return .passThrough }

            // Returned exactly as it comes back. Not adjusted, not clamped, not decided here —
            // inherited constraint 4, and the one with the blast radius: this path sees nearly every
            // keystroke the user makes, all day, in every application, because stop rule (c) needs
            // events Vocca has no interest in. A hard-coded value here is not an edge case; it is
            // the user's entire keyboard for as long as Vocca runs.
            return sink.receive(
                RawKeyEvent(
                    kind: kind,
                    keyCode: keyCode,
                    // The founder's `fn` rule lands here, on this event's own key code. macOS sets
                    // the `fn` bit on F1–F20, the arrows and the navigation cluster with no user
                    // involvement, and this is the only layer that knows which key it was.
                    modifiers: HotkeyFlagTranslation.modifiers(
                        rawFlags: rawFlags, keyCode: keyCode),
                    isAutorepeat: isAutorepeat,
                    timestamp: now))

        case .disabled(let reason):
            // Not delivered to the sink, and that is the seam's division rather than an oversight:
            // the session end a disablement causes is minted by `TapHealthPolicy`, from its own
            // clock, with the fields stop rule (d) requires. A second synthetic event from here
            // would be a second answer to a question that already has one.
            observer?.tapWasDisabledOnTheCallback(reason)
            // There is no keystroke behind a disablement and no application waiting for it, and the
            // window server ignores what a callback returns for one. Pass-through is the value that
            // means "not ours".
            return .passThrough

        case .notOfInterest:
            // Unreachable under ``TapEventTranslation/eventsOfInterestMask``. If it is ever reached,
            // the event belongs to somebody else and reaches them untouched.
            return .passThrough
        }
    }
}
