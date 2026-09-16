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

/// The dictate-vs-converse state machine (C11, P3): `idle | active(mode)`, with the closed
/// transition table and the epoch-minted ``ModeSession`` handoff.
///
/// ## The committed transition table — the whole of the behaviour
///
/// | State | Input | Effect |
/// |---|---|---|
/// | idle | `.start(m)` | `.started(m, epoch+1)` — mints the record |
/// | active(m) | `.start(m)` | `.sessionControl(m)` — the session's own chord |
/// | active(m) | `.start(other)` | `.refused` — never a switch; nothing changes, not even the epoch |
/// | active(m) | `.stop` | `.stopped(m, epoch, record)` — hands out and clears |
/// | idle | `.stop` | `.unchanged` |
/// | active(m) | `.system(_)` | `.stopped(m, epoch, record)` — every trigger |
/// | idle | `.system(_)` | `.unchanged` |
///
/// There is no `active(m) → active(other)` row: **mid-session switching is impossible**. Only
/// `.idle` can produce `.started`: **one active capture at a time**. No input can change the
/// mode except a start from idle: **no implicit switching**. The `.system` row covers every
/// ``SystemTrigger`` case (the tests sweep it with `CaseIterable`): **no session outlives a
/// system trigger**.
///
/// ## Why this is a class, and why it is not an actor
///
/// The `SessionMachine.swift:41-55` argument verbatim: a `CGEvent` tap callback is a synchronous
/// C function that must return *this event's* disposition before it returns, and `await` cannot
/// appear on that path. The mode decision arrives from the same tap path, so this machine is
/// synchronous and **not** `Sendable`; isolation belongs to whoever owns the tap, and everything
/// the machine hands back — ``SessionModeEffect``, ``ModeSession`` — is `Sendable` so it can
/// cross to the actor that transcribes.
///
/// The owner never keeps a second copy of the mode: it reads ``currentMode`` to route, the
/// `SessionMachine.configuration` precedent (`SessionMachine.swift:71-76`).
///
/// ## The epoch
///
/// `UInt64` with `&+`/`&+=`: an overflow is a mint collision at 2⁶⁴ activations — out of scope,
/// never special-cased. Refusals and session-control presses do not mint: a `.refused` press
/// leaves the epoch untouched, so the no-op is *total*, not merely "no visible effect" (R1).
///
/// There is no `.ending` state: the mode machine's stop is synchronous bookkeeping (mint → hand
/// out → clear); the async-ish handoff window is the drivers' (`SessionMachine`'s `.ending`
/// exists for the audio source's `endCapture`, `SessionMachine.swift:656-662`). The mode machine
/// has no resource to close; a second `.stop` lands in `.idle` and is `.unchanged` (the B9
/// no-op posture, `SessionMachine.swift:631-633`).
public final class SessionModeMachine<Audio: CapturedAudio> {
    /// The active mode; `nil` = idle.
    ///
    /// Readable from outside, settable only here, so the owner routes against the machine's one
    /// fact rather than a copy of it — two copies of a mode can disagree, and the disagreement
    /// that matters is silent (the `SessionMachine.configuration` argument).
    public private(set) var currentMode: SessionMode?

    /// The activation counter: incremented exactly when `.started` mints, never by a refusal or
    /// a session-control press.
    public private(set) var epoch: UInt64 = 0

    /// The in-flight record, minted at every `.started` and cleared at every `.stopped`.
    ///
    /// Exactly one `session` field, replaced at every start: carryover is unrepresentable.
    public private(set) var session: ModeSession<Audio>?

    public init() {}

    /// The one funnel: every input travels one path through the same switch — a second entry
    /// point is how a state machine acquires an unguarded row (the `SessionMachine.observe`
    /// argument, `SessionMachine.swift:308`).
    ///
    /// The switch has no `default:`: the closed-enum discipline means a new input or a new
    /// effect has to be given a meaning at this table before it can exist anywhere else.
    public func observe(_ intent: SessionModeIntent) -> SessionModeEffect<Audio> {
        switch (currentMode, intent) {
        case (nil, .start(let mode)):
            epoch &+= 1
            session = ModeSession(mode: mode, epoch: epoch)
            currentMode = mode
            return .started(mode, epoch: epoch)

        case (let active?, .start(let mode)) where mode == active:
            return .sessionControl(mode)

        case (.some, .start):
            return .refused

        case (let active?, .stop), (let active?, .system):
            guard let finished = session else {
                preconditionFailure("an active mode always carries its epoch-minted session")
            }
            session = nil
            currentMode = nil
            return .stopped(active, epoch: epoch, session: finished)

        case (nil, .stop), (nil, .system):
            return .unchanged
        }
    }

    /// Fills the in-flight record's buffer slot.
    ///
    /// Precondition: a session is active (`currentMode != nil`) — filling outside an activation
    /// is a programmer error. The owner calls this when the driver produces the value (dictate:
    /// the outcome's buffer at the terminal; converse: the committed utterance). A precondition
    /// cannot be caught in-process; the seam tests pin the guarded facts instead (a fresh or
    /// stopped machine has no session to address, and a refused press mints nothing).
    public func fill(buffer: Audio) {
        precondition(
            currentMode != nil,
            "fill(buffer:) requires an active session — the owner filled outside an activation")
        session?.buffer = buffer
    }

    /// Fills the in-flight record's transcript slot.
    ///
    /// Precondition: a session is active — see ``fill(buffer:)``. Called when the driver
    /// produces the text (dictate: the pipeline's text; converse: the cleaned text).
    public func fill(transcript: String) {
        precondition(
            currentMode != nil,
            "fill(transcript:) requires an active session — the owner filled outside an activation")
        session?.transcript = transcript
    }

    /// Fills the in-flight record's target slot.
    ///
    /// Precondition: a session is active — see ``fill(buffer:)``. **Dictate cycles only**: a
    /// converse driver never calls this — never a target in converse (`PRODUCT_SPEC.md:200`) —
    /// and the reset test asserts the stopped converse record's `target == nil` as a machine
    /// fact.
    public func fill(target: TargetContext) {
        precondition(
            currentMode != nil,
            "fill(target:) requires an active session — the owner filled outside an activation")
        session?.target = target
    }
}