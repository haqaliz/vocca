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

/// How long a session may last before the watchdog ends it.
public enum SessionCeiling {
    /// 120 s, per `ARCHITECTURE.md:336` and `spec.md`.
    ///
    /// The number is not free: `spec.md` open question 1 records that this ceiling *sets* the ring
    /// buffer's capacity in `audio-capture` — roughly 23 MB at 48 kHz Float32 mono — so lowering it
    /// is the lever if that allocation is too much. It is named here rather than defaulted into
    /// ``SessionMachine/init(configuration:ceiling:clock:audioSource:)`` because a caller that
    /// wants the shipped value should have to say so, and `HotkeyConfiguration` argues that case at
    /// length for `activation`.
    public static let `default`: Duration = .seconds(120)
}

/// The session, from key-down to custody: `idle → recording → ending → idle`.
///
/// Two invariants stop being types here and start being behaviour.
///
/// 1. **A transcript is never lost.** Every terminal transition goes through
///    ``endSession(reason:)``, which closes the microphone and hands what it captured to
///    ``SessionOutcome/make(reason:audio:)``. There is no other route: `make` is called in exactly
///    one place in this module, and `CoreBoundaryTests` fails the build if a second appears.
/// 2. **A capture session never outlives the user's intent.** Six stop rules reach the same funnel,
///    and the microphone closes on all of them — including cancellation, where the *audio* is
///    discarded but the microphone most certainly is not left open.
///
/// ## Why this is a class, and why it is not an actor
///
/// `ARCHITECTURE.md:294` sketches a `SessionActor`, and this is not one. A `CGEvent` tap callback is
/// a synchronous C function that must return *this event's* disposition — swallow or pass through —
/// before it returns. `await` cannot appear on that path: by the time an actor hop resolved, the
/// event would already have gone to the focused application. So the machine is synchronous and
/// **not** `Sendable`; isolation belongs to whoever owns the tap, and everything the machine hands
/// back (``SessionEffect``, ``SessionOutcome``) is `Sendable` so it can cross to the actor that does
/// the transcribing.
///
/// A `struct` was the other candidate and is worse: it holds a reference to its audio source, so two
/// copies would share one microphone while disagreeing about whether a session is running — value
/// semantics that are a lie. Copying a class does not lose that argument, because there is nothing
/// to copy.
///
/// ## What it does not own
///
/// **When to tick.** The machine has no timer; it checks the ceiling when ``tick()`` is called and
/// at no other moment. **When to poll**, likewise. Both are ``SessionWatchdog``'s policy; what is
/// here is the mechanism it drives, and the seam is deliberately this thin so that the policy cannot
/// quietly acquire an opinion about speech boundaries — the moment it does it is VAD, which
/// `ROADMAP.md:45` defers to P3.
///
/// **Which key events mean what.** That is ``decide(_:state:config:)``, which is pure and stays
/// pure. The machine routes every key event through it and adds exactly one thing the rules cannot
/// know: whether a physically-held key is the tail of a press Vocca swallowed — see
/// ``claimedKeyCode``.
public final class SessionMachine<Audio: CapturedAudio> {
    /// The configured hotkey.
    ///
    /// Readable from outside so that ``SessionWatchdog`` can poll **the key this machine is
    /// watching** rather than one it was told about separately. Two copies of a configuration can
    /// disagree, and the disagreement that matters is silent: a poll of the wrong key code reports
    /// a release that means nothing, or misses one that means everything.
    public let configuration: HotkeyConfiguration

    /// How long this session may run before the ceiling ends it.
    ///
    /// Public for the same reason as ``configuration``, and one more: the widget's
    /// ceiling-approaching warning is derived from it (``SessionWatchdog/warningThreshold``), so a
    /// second copy would leave a configured ceiling with the default's warning stapled to it.
    public let ceiling: Duration

    private let clock: any MonotonicClock
    private let source: any SessionAudioSource<Audio>

    private var sessionState: SessionState = .idle

    /// Forward time accumulated since this session started, as of the last ``tick()``.
    ///
    /// Accumulated rather than compared against an absolute deadline so that a clock which steps
    /// backwards extends the session by at most one tick interval instead of by the whole jump —
    /// see ``tick()``.
    ///
    /// Readable, and settable only here, because the widget has to be able to say how long the user
    /// has been talking and how close the ceiling is, and this is the number the ceiling itself is
    /// measured against. A second accumulator kept alongside it — in the watchdog, in the widget —
    /// is the [Handy #840](https://github.com/cjpais/Handy/issues/840) shape: two totals of the same
    /// thing, one of which is eventually wrong.
    public private(set) var elapsed: Duration = .zero

    /// The reading ``elapsed`` was last measured against.
    private var lastReading: Duration = .zero

    /// **The key Vocca swallowed the press of, and has not yet seen come back up.**
    ///
    /// The one fact ``decide(_:state:config:)`` cannot hold and this machine must. It is not "a
    /// session is running": it outlives the session deliberately, because the defect it fixes
    /// *begins* when the session ends with the key still down.
    ///
    /// After a rule-(b) stop — Option released before Space — the chord is gone, so every autorepeat
    /// of the still-held Space is, to a stateless rule, an ordinary keystroke. It passes through:
    /// plain characters at the system repeat rate, landing in the field the transcript is about to
    /// be injected into, unless the user lets go within one repeat interval. Carrying the press here
    /// and swallowing that key code until it comes up — *regardless of chord* — is the fix, and the
    /// only place it can live.
    ///
    /// It is released three ways, and all three are needed. A key-up on the claimed key is the
    /// ordinary one. A **fresh, unrepeated key-down** on it is the safety valve: the key must have
    /// come up while nobody was looking, so a claim still standing is stale, and holding it would
    /// leave the user with a dead Space bar and no way out but a restart. A poll reporting the key
    /// up is the third, for the same reason.
    ///
    /// A tap that dies does *not* release it: while the tap is down no events arrive at all, and
    /// when it is re-armed the user's finger may well still be on the key — where swallowing is
    /// exactly right. The fresh-press valve is what makes keeping it safe.
    private var claimedKeyCode: UInt16?

    /// Whether the focused application received a key-down for the configured key that Vocca has not
    /// balanced with a key-up.
    ///
    /// Swallowing is asymmetric in the rules — a `.keyDown` is claimed only while the chord is held,
    /// a `.keyUp` whatever modifiers survive to report it — so without this, a passed-through
    /// key-down followed by a swallowed key-up leaves the app holding a key it believes is down.
    /// That is the worse of the two unpaired states: it changes the meaning of every keystroke after
    /// it, while an unpaired key-up is inert.
    ///
    /// So the claim never swallows a key-up the application is waiting for. This is a model of what
    /// *Vocca forwarded*, not an accumulated reading of the hardware — it cannot desynchronise the
    /// way [Handy #840](https://github.com/cjpais/Handy/issues/840)'s modifier total did, because
    /// every event that changes it is one this machine itself decided to pass through.
    private var applicationHoldsTheHotkeyKey = false

    /// Set only while the machine is inside `beginCapture()`.
    ///
    /// Opening a microphone is real work on a real run loop — `AVAudioEngine.start()` takes
    /// milliseconds — and a queued `CGEvent` delivered underneath it re-enters this machine at a
    /// moment `sessionState` describes wrongly: still `.idle`, so the rules would happily start a
    /// *second* session inside the first one's opening. There is no `.starting` state to say
    /// otherwise, and inventing one would add a fourth case to every exhaustive switch in the module
    /// for an instant that is never observable from outside.
    ///
    /// So a *start* is **refused**: `project-skeleton`'s carry-forward rule is that a component
    /// which cannot classify its own state must fail closed.
    ///
    /// **The other transition needs no flag, and deliberately does not have one.** `.ending` already
    /// describes the handoff exactly, every rule and every method already refuses to act in it, and
    /// a flag shadowing that would make the state's own guard unreachable — untestable code
    /// pretending to be defence in depth.
    private var isOpeningTheMicrophone = false

    /// A stop that arrived while the microphone was opening, held until there is a session to apply
    /// it to.
    ///
    /// Refusing a *start* inside the opening is right. Refusing a **stop** is not, and the first
    /// version of this file did both — with a comment claiming the cost was bounded by one poll
    /// interval. It was not, and the number mattered because the watchdog is being designed against
    /// it. Three shapes can land in those few milliseconds and only one of them is what that comment
    /// described:
    ///
    /// | Dropped stop | What actually recovered it |
    /// |---|---|
    /// | the user's key-up | the next physical-key poll — one interval, as claimed |
    /// | Escape, or a system trigger while the key is still held | *not* the poll: it reports the key **down**. The key-up, or the 120 s ceiling |
    /// | `.tapDisabled` | *not* the poll, and no key event can ever arrive again. The tap being re-armed, or the **ceiling** — a two-minute hot mic |
    ///
    /// One optional closes the whole class, and it is not a queue: the reason is recorded by
    /// ``stopIfRecording(_:)`` — which every stop path already funnels through — and applied through
    /// that same funnel the instant `sessionState` becomes `.recording`. So the single-funnel
    /// guarantee is untouched, and the session ends with the audio it captured during the opening
    /// rather than running to the ceiling.
    ///
    /// **First one wins.** If a key-up and a tap death both land there, the key-up is the user's own
    /// gesture and the more specific fact — the same precedence the stop rules already use, for the
    /// same reason: the log is the only evidence anyone gets.
    private var stopDeferredByTheOpening: EndReason?

    /// Where the session is: `idle` while nothing is captured, `recording` while the microphone is
    /// open, `ending` only from inside the handoff itself.
    public var state: SessionState { sessionState }

    public init(
        configuration: HotkeyConfiguration,
        ceiling: Duration,
        clock: any MonotonicClock,
        audioSource: any SessionAudioSource<Audio>
    ) {
        self.configuration = configuration
        self.ceiling = ceiling
        self.clock = clock
        self.source = audioSource
    }

    // MARK: - Inputs

    /// One observed keyboard event: what it does to the session, and whether the focused
    /// application sees it.
    ///
    /// The rules decide both, and this adds exactly one thing they cannot know — see
    /// ``claimedKeyCode``. The **action** is carried out as ``decide(_:state:config:)`` gave it,
    /// always; the **propagation** is adjusted in two places and two only, both listed on
    /// ``propagation(_:for:)``: a claimed key press is swallowed even once its chord is gone, and a
    /// key-up the focused application is waiting for is delivered even when the rules would eat it.
    public func observe(_ event: RawKeyEvent) -> SessionResponse<Audio> {
        guard !isOpeningTheMicrophone else {
            // Re-entered from inside the microphone opening. No session may *start* here — that is
            // the second-microphone bug — but a stop must not be dropped, so the event is asked
            // what it would mean to the session that is a few instructions from existing.
            //
            // `decide` never returns `.start` from `.recording`, so asking it that way cannot open
            // anything; the only thing it can produce is the stop that would otherwise be lost.
            let effect: SessionEffect<Audio>
            switch decide(event, state: .recording, config: configuration).action {
            case .stop(let reason):
                effect = stopIfRecording(reason)
            case .start, .ignore:
                effect = .unchanged
            }

            // The press is still Vocca's if it was already claimed — dropping to `.passThrough`
            // here would type the very character the claim exists to swallow. The bookkeeping runs
            // on this path too: a key-up forced through here and not accounted for leaves
            // `applicationHoldsTheHotkeyKey` set, and the app gets one duplicate unpaired key-up on
            // the next release.
            let eventPropagation = propagation(.passThrough, for: event)
            account(for: event, propagatedAs: eventPropagation)
            return SessionResponse(effect: effect, eventPropagation: eventPropagation)
        }

        releaseStaleClaim(before: event)
        let decision = decide(event, state: sessionState, config: configuration)

        let effect: SessionEffect<Audio>
        switch decision.action {
        case .start:
            effect = beginSession(claiming: event.keyCode)
        case .stop(let reason):
            effect = stopIfRecording(reason)
        case .ignore:
            effect = .unchanged
        }

        let eventPropagation = propagation(decision.eventPropagation, for: event)
        account(for: event, propagatedAs: eventPropagation)
        return SessionResponse(effect: effect, eventPropagation: eventPropagation)
    }

    /// A system event that makes continuing impossible or wrong. Each one carries its own reason
    /// into the outcome, because a log entry naming the wrong cause is the only evidence anyone
    /// will have of a session that ended surprisingly.
    public func observe(_ trigger: SystemTrigger) -> SessionEffect<Audio> {
        stopIfRecording(.retained(.systemEvent(trigger)))
    }

    /// The watchdog's clock tick: stop rule (e), the ceiling.
    ///
    /// Elapsed time is **accumulated from the deltas between readings**, and a negative delta
    /// contributes nothing. The obvious implementation — remember the start, fire when
    /// `now >= start + ceiling` — extends the session by the *full* size of a backwards jump,
    /// because the absolute deadline moves out of reach.
    ///
    /// This shape loses only what the jump and the tick straddling it have in common:
    /// `min(jump, that tick's interval)` of forward time, so the session runs long by **at most one
    /// tick interval** — ``WatchdogPolicy/pollInterval`` at the watchdog's cadence — **per backward
    /// step.** N of them cost up to N intervals; the bound is per jump, not per session, and
    /// `SessionWatchdogTests` measures both halves of that rather than restating it.
    ///
    /// The machine has no timer of its own. If nobody ticks, the ceiling never fires — which is why
    /// the watchdog that calls this is a separate, tested unit of work rather than an implicit
    /// promise.
    public func tick() -> SessionEffect<Audio> {
        let reading = clock.now
        switch sessionState {
        case .idle, .ending:
            // No session, so nothing accumulates. Time spent idle must not count against the next
            // session's ceiling.
            return .unchanged
        case .recording:
            let delta = reading - lastReading
            lastReading = reading
            if delta > .zero { elapsed += delta }
            guard elapsed >= ceiling else { return .unchanged }
            return .ended(endSession(reason: .retained(.ceilingReached)))
        }
    }

    /// The physical state of the configured key, as read at the seam: stop rule (f).
    ///
    /// `isDown: false` means a key-up was missed — the hotkey was stolen, the tap stalled, the app
    /// lost focus mid-press. The session ends on the poll that observes it, so the worst-case
    /// hot-mic window is one poll interval, and the interval is the watchdog's to choose.
    ///
    /// A report of `isDown: false` also releases the key claim: the key is not held, so there are no
    /// repeats left to swallow, and the key-up event that would have released it may be the very
    /// thing that went missing. The residual is an in-flight key-up arriving just after the read and
    /// passing through unpaired — inert, where the alternative is a key Vocca eats forever.
    public func observePhysicalKey(isDown: Bool) -> SessionEffect<Audio> {
        guard !isDown else { return .unchanged }
        if claimedKeyCode == configuration.keyCode { claimedKeyCode = nil }
        return stopIfRecording(.retained(.pollDetectedRelease))
    }

    /// The user abandoned the session — Escape.
    ///
    /// The only path that discards captured audio, and it still closes the microphone. Those are
    /// different things: the user asked to throw the words away, not to keep listening.
    public func cancel() -> SessionEffect<Audio> {
        stopIfRecording(.userCancelled)
    }

    // MARK: - The key Vocca swallowed the press of

    /// Whether the focused application sees this event, given what the rules decided.
    ///
    /// Narrowing only, with one deliberate exception. `.passThrough → .swallow` is the fix: a key
    /// code Vocca claimed stays Vocca's until it comes back up, chord or no chord. The exception is
    /// a key-up the application is *waiting for* — it is forced through even when the rules would
    /// swallow it, because an application left holding a key changes the meaning of every keystroke
    /// after it, and a key-up types nothing.
    private func propagation(
        _ decided: EventPropagation, for event: RawKeyEvent
    ) -> EventPropagation {
        switch event.kind {
        case .keyDown:
            return claimedKeyCode == event.keyCode ? .swallow : decided
        case .keyUp:
            if applicationHoldsTheHotkeyKey && event.keyCode == configuration.keyCode {
                return .passThrough
            }
            return claimedKeyCode == event.keyCode ? .swallow : decided
        case .flagsChanged, .tapDisabled:
            // Never claimed, in either direction. A swallowed modifier event would strand the
            // focused application's idea of which modifiers are down, and a tap-disabled
            // notification is not a keystroke at all.
            return decided
        }
    }

    /// The safety valve, applied before ``propagation(_:for:)`` reads the claim.
    ///
    /// *Not* "before `decide`", which is how this used to read: `decide` is pure in
    /// `(event, state, config)` and cannot see the claim at all, so moving this call past it changes
    /// nothing. What must not happen is a stale claim still standing when propagation is chosen.
    ///
    /// A key-down that macOS did not mark as an autorepeat cannot be part of a press that is still
    /// held: the key must have come back up while nobody was looking — a disabled tap, a lost focus,
    /// a stolen hotkey. A claim still standing at that point is stale, and a stale claim means Vocca
    /// silently eating a key the user is typing.
    private func releaseStaleClaim(before event: RawKeyEvent) {
        switch event.kind {
        case .keyDown where !event.isAutorepeat && claimedKeyCode == event.keyCode:
            claimedKeyCode = nil
        case .keyDown, .keyUp, .flagsChanged, .tapDisabled:
            break
        }
    }

    /// Records what this event did to the two things the machine has to remember about the keyboard:
    /// which key Vocca owes a key-up for, and which key the focused application believes is down.
    ///
    /// Both are derived from decisions this machine has just made about events it has just seen —
    /// never from a running total of hardware state, which is the
    /// [Handy #840](https://github.com/cjpais/Handy/issues/840) defect and is prohibited module-wide.
    private func account(for event: RawKeyEvent, propagatedAs propagation: EventPropagation) {
        switch (event.kind, propagation) {
        case (.keyDown, .swallow):
            // Vocca ate this press, so it owes the key-up that ends it too.
            claimedKeyCode = event.keyCode
        case (.keyDown, .passThrough):
            if event.keyCode == configuration.keyCode { applicationHoldsTheHotkeyKey = true }
        case (.keyUp, .swallow):
            if claimedKeyCode == event.keyCode { claimedKeyCode = nil }
        case (.keyUp, .passThrough):
            if event.keyCode == configuration.keyCode { applicationHoldsTheHotkeyKey = false }
            if claimedKeyCode == event.keyCode { claimedKeyCode = nil }
        case (.flagsChanged, _), (.tapDisabled, _):
            break
        }
    }

    // MARK: - Transitions

    private func beginSession(claiming keyCode: UInt16) -> SessionEffect<Audio> {
        // Claimed before the microphone is asked to open, not after: opening one is milliseconds of
        // real work, and an autorepeat delivered underneath it must already be Vocca's.
        claimedKeyCode = keyCode

        // `decide` returns `.start` only from `.idle`, which is what makes the double-start bug
        // unreachable rather than merely unlikely — but the microphone still has to agree.
        isOpeningTheMicrophone = true
        let opening = source.beginCapture()
        isOpeningTheMicrophone = false

        // **Taken**, not read, and this is the only line that clears it — so the field is non-nil
        // only ever *inside* an opening. A deferred stop that outlived its own would end somebody
        // else's session while the user's finger is still on the key, and the `.unavailable` path
        // below has no session for it to end at all. Clearing it here rather than also before
        // `beginCapture()`: two clears made each individually removable with the suite green, which
        // is the shape flagged against `elapsed` and fixed in the same round.
        let deferred = stopDeferredByTheOpening
        stopDeferredByTheOpening = nil

        switch opening {
        case .unavailable:
            // No session, and deliberately still claimed: the user pressed Vocca's hotkey, so the
            // repeats and the key-up are Vocca's to eat whether or not the microphone cooperated.
            return .captureUnavailable
        case .opened:
            sessionState = .recording
            // Reset here and **only** here. `endSession` used to clear it too, and neither copy
            // could then be removed on its own without the suite staying green — two mutants that
            // were equivalent only because the other line existed. One reset, in the transition
            // that owns the meaning: a session's clock starts when its microphone opens.
            elapsed = .zero
            lastReading = clock.now
            guard let deferred else { return .started }
            // A stop arrived while the microphone was opening. Apply it now, through the same
            // funnel every other stop uses, rather than leaving a session nobody asked for running
            // until the ceiling. The buffer is whatever those few milliseconds captured — which
            // `SessionAudioSource.endCapture()` already states is a legitimate answer.
            return stopIfRecording(deferred)
        }
    }

    /// Every stop input lands here, and only a recording session has anything to stop.
    ///
    /// A stop arriving in `.idle` is the ordinary tail of rule (b) — the key-up after a session that
    /// already ended when the modifier came up — and a stop arriving in `.ending` is an event that
    /// reached the machine from inside its own handoff. Both are no-ops, both are B9, and neither
    /// may produce an outcome: there is no session, so there is no audio, and an outcome without
    /// audio is the shape this aspect exists to make unrepresentable.
    private func stopIfRecording(_ reason: EndReason) -> SessionEffect<Audio> {
        guard !isOpeningTheMicrophone else {
            // There is no session yet, but there is about to be, and this is a stop for it. Hold the
            // first one; ``beginSession(claiming:)`` applies it through this same funnel the moment
            // the session exists. See ``stopDeferredByTheOpening``.
            if stopDeferredByTheOpening == nil { stopDeferredByTheOpening = reason }
            return .unchanged
        }

        switch sessionState {
        case .recording:
            return .ended(endSession(reason: reason))
        case .idle, .ending:
            return .unchanged
        }
    }

    /// **The funnel.** The single place a ``SessionOutcome`` is produced in this module.
    ///
    /// Private, and that is the stronger form of the guarantee `spec.md` asks for: not merely that
    /// every terminal path *goes* through here, but that there is no other method anyone could call
    /// to produce an outcome — including a future one, since ``stopIfRecording(_:)`` is the only
    /// caller and it refuses everything but `.recording`.
    ///
    /// Three lines, in an order that is load-bearing:
    ///
    /// 1. **`.ending` first.** The audio source's `endCapture()` is real work — stopping an engine
    ///    can pump a run loop and deliver a queued key event straight back into this machine. It
    ///    must find a state that starts nothing and ends nothing.
    /// 2. **Close the microphone unconditionally, and bind the buffer.** Not inside `make`'s
    ///    argument: `audio` there is an `@autoclosure` that cancellation deliberately never
    ///    evaluates, so a funnel that closed the microphone in that expression would leave it open
    ///    on exactly the path where the user pressed Escape and the widget says nothing is
    ///    happening. Discarding a transcript and holding the microphone are different things.
    /// 3. **Hand `make` the reason it was given and the buffer this session captured** — not a
    ///    re-derived reason and not a fresh buffer. `make` is total over ``EndReason``, so a stop
    ///    rule added later is handed its audio automatically and cannot reach the discard path.
    private func endSession(reason: EndReason) -> SessionOutcome<Audio> {
        sessionState = .ending
        let captured = source.endCapture()
        let outcome = SessionOutcome.make(reason: reason, audio: captured)
        sessionState = .idle
        return outcome
    }
}
