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

/// What one observed keyboard event means for the session.
///
/// This is the function the stuck-recording bug lives in, so it is written to be the function that
/// bug cannot survive: a free function of three values, with nothing to remember between calls.
///
/// ## Pure, and structurally so
///
/// Same inputs give the same output, always. There is no clock to read — `VoccaCore` imports
/// nothing, so `Foundation`, `Dispatch` and `Darwin` are all out of reach, and `CoreBoundaryTests`
/// asserts that rather than trusting it. There is no I/O, and there is no mutable global: this is a
/// free function, so it has no storage of its own, and a `static var` or `nonisolated(unsafe)`
/// anywhere in the module is a lint failure.
///
/// The state it needs is a parameter. That is the entire design — a session's state is task 4's to
/// own and advance, and passing it in is what keeps this side of the seam testable with no tap, no
/// permission and no keyboard.
///
/// ## The prohibition
///
/// **Modifier state is derived from `event.modifiers`, every time. It is never accumulated.**
///
/// One line below does it — `event.modifiers.isSuperset(of: config.modifiers)` — and there is
/// deliberately nowhere else it could come from. This is not a style preference:
/// [Handy #840](https://github.com/cjpais/Handy/issues/840) is this defect shipping in a comparable
/// tool. v0.1.4 derived modifier state from each event's flags and worked; v0.2.0 kept a running
/// total updated on `flagsChanged` and desynchronised **permanently** after a single missed event,
/// leaving the microphone open. macOS disables event taps under load without warning, so events are
/// dropped in normal use — a running total is not a risk, it is a scheduled failure.
///
/// A derived read cannot desynchronise, because there is nothing to synchronise: every keyboard
/// event already carries the complete current modifier state. That is also what makes stop rule (c)
/// free.
///
/// ## The rules
///
/// **Start** — `.keyDown` on the configured key, carrying at least the configured modifiers, not an
/// autorepeat, in `.idle`. All five, and each one is load-bearing.
///
/// **Stop**, in the order they are applied. The order is a decision, not an accident: when two fire
/// on the same event the reported reason is the one that best describes what happened, and log
/// entries are the only evidence anyone will have of a session that ended surprisingly.
///
/// | # | Trigger | Reason |
/// |---|---|---|
/// | d | `.tapDisabled` | `.tapDisabled` — checked first, because such an event's modifier flags mean nothing, and testing them earlier would end the session for the right cause under the wrong name |
/// | a | `.keyUp` on the configured key | `.keyUp` — the user's own gesture, and the more specific fact when the key-up also happens to report no modifiers |
/// | b/c | any event no longer carrying the configured modifiers | `.modifierReleased` |
///
/// Rules (e) ceiling and (f) poll are absent here on purpose. Neither has a `RawKeyEvent` to be
/// decided from — one is a clock reading and the other a physical-key read, both of which live
/// behind seams this module cannot reach — so task 4 fires them and routes them through the same
/// stop funnel. ``Decision`` carries every ``EndReason``, so nothing is lost by their not
/// originating here; `SessionDecisionTests` pins the vocabulary this function does produce, so a
/// later edit cannot invent a key event that claims to be a ceiling expiry.
///
/// ## What gets swallowed
///
/// Independent of the action, and narrow. Vocca swallows the key-down that starts a session, and
/// thereafter the key events for **its own key** while a session is in flight — the focused app
/// never saw that key-down, so it must not see the autorepeats or the key-up either. Everything
/// else passes through, including every `.flagsChanged`: a tool that eats keystrokes it did not
/// claim makes the whole machine feel broken, and a swallowed modifier event would strand the
/// focused app's idea of which modifiers are down.
///
/// The one case that reads as an exception is not: a `.keyDown` on the configured key whose chord
/// is *gone* passes through, because without the chord it is not Vocca's hotkey — it is the user
/// typing a space, and they should get one, along with the stop that a lost chord always means.
///
/// - Parameters:
///   - event: The event as observed, with the modifiers **it** carried.
///   - state: Where the session is now. Owned and advanced by the caller.
///   - config: The configured hotkey.
/// - Returns: What the caller must do, and whether the focused application still sees the event.
public func decide(
    _ event: RawKeyEvent, state: SessionState, config: HotkeyConfiguration
) -> Decision {
    switch config.activation {
    case .holdToTalk:
        return holdToTalkDecision(event, state: state, config: config)
    }
}

/// Hold-to-talk, which is every mode there is today.
///
/// Split from ``decide(_:state:config:)`` so that the mode switch above stays a single, obvious
/// line: when toggle mode arrives it fails to compile there, next to the one other implementation,
/// rather than somewhere in the middle of a rule table.
private func holdToTalkDecision(
    _ event: RawKeyEvent, state: SessionState, config: HotkeyConfiguration
) -> Decision {
    let matchesKey = event.keyCode == config.keyCode

    // The prohibition, in one line. Read from the event in hand — never from anything remembered.
    let carriesChord = event.modifiers.isSuperset(of: config.modifiers)

    let action: Decision.Action
    switch state {
    case .idle:
        // Nothing is in flight, so no event can stop anything: a stop without a start is a no-op,
        // and a key-up arriving after the session already ended is the ordinary tail of stop rule
        // (b), not a second stop.
        switch event.kind {
        case .keyDown:
            action = matchesKey && carriesChord && !event.isAutorepeat ? .start : .ignore
        case .keyUp, .flagsChanged, .tapDisabled:
            action = .ignore
        }

    case .recording:
        switch event.kind {
        case .tapDisabled:
            action = .stop(.retained(.tapDisabled))

        case .keyUp:
            if matchesKey {
                action = .stop(.retained(.keyUp))
            } else if carriesChord {
                action = .ignore
            } else {
                action = .stop(.retained(.modifierReleased))
            }

        case .keyDown, .flagsChanged:
            // `.flagsChanged` is rule (b) and every other kind is rule (c). One test serves both,
            // which is precisely why (c) costs nothing to have.
            //
            // A `.keyDown` on the configured key that still carries the chord lands on `.ignore`
            // here, and that covers two things deliberately: an autorepeat, which must neither
            // restart nor end the session, and a genuinely fresh press while one is already
            // running. Hold-to-talk has six stop rules and a re-press is not among them — a
            // key-up that went missing is what the ceiling and the poll exist for, and restarting
            // would be the double-start bug. Toggle mode is where this event becomes
            // `.toggledOff`.
            action = carriesChord ? .ignore : .stop(.retained(.modifierReleased))
        }

    case .ending:
        // The previous session's audio is still on its way downstream. Nothing may start a session
        // from here — that is what makes `.ending` a state rather than a boolean — and nothing may
        // end one that has already ended.
        action = .ignore
    }

    let sessionInFlight: Bool
    switch state {
    case .idle: sessionInFlight = false
    case .recording, .ending: sessionInFlight = true
    }

    let claimsThisEvent: Bool
    switch event.kind {
    case .keyUp:
        // The release of a press Vocca swallowed, whatever modifiers survive to report it.
        claimsThisEvent = sessionInFlight && matchesKey
    case .keyDown:
        claimsThisEvent = sessionInFlight && matchesKey && carriesChord
    case .flagsChanged, .tapDisabled:
        claimsThisEvent = false
    }

    let startsASession: Bool
    switch action {
    case .start: startsASession = true
    case .stop, .ignore: startsASession = false
    }

    return Decision(
        action: action,
        eventPropagation: startsASession || claimsThisEvent ? .swallow : .passThrough)
}
