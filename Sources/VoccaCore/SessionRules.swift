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
/// **A tap that dies outside `.recording` is `.ignore`, and that is not the whole story.** There is
/// no session to stop, so there is nothing for this function to say — but the tap is still dead,
/// and ``Decision`` deliberately has no vocabulary for "re-arm the tap", because re-creating a
/// `CGEvent` tap is a system call and this module makes none. A caller that routes tap-disabled
/// notifications through here and acts *only* on the returned action goes permanently deaf, in
/// silence, and that is a sibling of the stuck-microphone bug rather than a lesser cousin.
/// Re-enabling the tap belongs to `hotkey-source`, unconditionally and independently of whatever
/// this function returns.
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
/// A `.keyDown` on the configured key whose chord is *gone* passes through, because without the
/// chord it is not Vocca's hotkey — it is the user typing a space, and they should get one, along
/// with the stop that a lost chord always means.
///
/// **That last rule is a known trade with two costs, and neither is fixable here.** Both begin the
/// instant a rule-(b) stop fires while the key is still physically held:
///
/// 1. **Characters reach the field being dictated into.** The OS was already autorepeating the key
///    throughout the session, and those repeats were swallowed. The moment the modifier comes up
///    the chord is gone, so every subsequent repeat passes through — plain characters at the system
///    repeat rate, landing in the field the transcript is about to be injected into, unless the
///    user releases within one repeat interval (~30–60 ms).
/// 2. **The key-up is claimed asymmetrically.** Swallowing below requires the chord for a
///    `.keyDown` but *not* for a `.keyUp`, because a key-up is the release of a press this module
///    swallowed whatever modifiers survive to report it. So a passed-through key-down can be
///    followed by a swallowed key-up, leaving the focused app an **unpaired key-down** — a key it
///    believes is still held. The reverse case, in `.idle`, leaves an unpaired key-up, which is
///    inert by comparison.
///
/// A pure function cannot do better: knowing that a physically-held key is the tail of a press
/// Vocca swallowed is a fact about the *session*, not about the event. The session must carry it —
/// "the hotkey has not yet come back up" — and keep swallowing that key code until it does,
/// regardless of chord. That is the state machine's, and it is written down as Phase 4 of this
/// aspect's plan. Both behaviours are pinned by the truth table in `SessionDecisionTests`, so they
/// change on purpose rather than by accident.
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
