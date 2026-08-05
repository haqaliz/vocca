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

/// The physical state of a key, read at the seam.
///
/// The read itself is `CGEventSourceKeyState`, which is a system call, so it belongs to
/// `hotkey-source` — `spec.md:94` puts it there by name. What lives on this side of the seam is the
/// decision to *ask* and what the answer means; see ``SessionWatchdog/wake()``.
///
/// ## Why it is class-bound
///
/// The same reason ``SessionAudioSource`` is, and it is worth repeating because the production
/// conformance will be stateless and the constraint therefore looks free to drop. It is not:
/// `project-skeleton`'s final review earned the rule *assert the effect, never the reference*, and
/// the effect a test needs to observe here is **how many times the watchdog asked**. A struct
/// conformance would be copied into the watchdog, its read counter would be incremented on the copy,
/// and "the poll ran a hundred times and ended nothing" would become unmeasurable — which is
/// precisely the assertion that separates a watchdog that polls from one that has quietly stopped.
public protocol PhysicalKeyStateReader: AnyObject {
    /// Whether the key with this virtual key code is physically held down **at this instant**.
    ///
    /// A reading of the hardware, not a replay of events: it is the answer for the key-up that
    /// never generated an event at all, so an implementation that derives it from observed events
    /// answers the wrong question and can only ever repeat what the tap already said.
    func isKeyDown(_ keyCode: UInt16) -> Bool
}

/// The watchdog's numbers, and the one derivation the widget reads.
///
/// A caseless enum, like ``SessionCeiling``: a namespace for values that are policy decisions rather
/// than configuration the user sets.
public enum WatchdogPolicy {
    /// How often the owner wakes the watchdog while a session is recording: **150 ms**.
    ///
    /// `spec.md` open question 2 researched 100–250 ms and asked for the tradeoff to be written
    /// where the number is, so here it is.
    ///
    /// **Slower widens the worst-case hot mic.** A key-up that generates no event at all — the
    /// hotkey stolen, the tap stalled, focus lost mid-press — is invisible to every other stop rule,
    /// and this poll is the only thing that ever sees it. The microphone therefore stays open for up
    /// to one interval after the user has stopped asking for it, and that interval *is* this number.
    ///
    /// **In toggle mode it is not that number**, because there is no poll there — see
    /// ``SessionWatchdog/wake()``. A toggle session whose stopping press is lost stays open until the
    /// ceiling, and quoting this interval as *the* worst-case hot mic would be quoting hold-to-talk's
    /// figure for a mode that does not have it.
    ///
    /// **Faster costs battery,** and it costs it during exactly the moments the user is talking: one
    /// `CGEventSourceKeyState` call plus one timer wake per interval, for the whole session — the
    /// system call being hold-to-talk's alone. 150 ms is 800 wakes across a full 120 s session.
    ///
    /// It is also the ceiling's resolution, because one timer drives both — see
    /// ``SessionWatchdog/wake()``. A 120 s ceiling measured to 150 ms is not a compromise anybody
    /// can perceive; a hot mic 150 ms longer than necessary is likewise below notice, and 400 ms
    /// would not be.
    public static let pollInterval: Duration = .milliseconds(150)

    /// How much warning the user gets before the ceiling ends their session: **10 s**.
    ///
    /// A fixed lead rather than a fraction of the ceiling, because the warning exists to give the
    /// user time to finish their sentence, and that is an amount of time rather than a proportion.
    /// At the shipped 120 s ceiling the two agree; at a configured 30 s ceiling a proportional rule
    /// would give under three seconds of notice, which is not notice.
    public static let warningLeadTime: Duration = .seconds(10)

    /// When the widget should start warning that the ceiling is approaching.
    ///
    /// `PRODUCT_SPEC.md:79-80` asks for the warning at **110 s** against the shipped 120 s ceiling,
    /// and this is the only place that number exists — as `120 − 10`, computed. Hard-coding 110
    /// somewhere else would leave a configured ceiling with its warning stapled to the default, so
    /// a user who lowered the ceiling to 60 s would be warned ten seconds *after* their session had
    /// already been cut off.
    ///
    /// Clamped at zero, which matters for a ceiling shorter than the lead: such a session is inside
    /// the warning window from the instant it starts, and saying so is truthful rather than
    /// defensive.
    public static func warningThreshold(before ceiling: Duration) -> Duration {
        max(.zero, ceiling - warningLeadTime)
    }
}

/// What the watchdog's owner should be doing with its timer.
///
/// The owner runs the timer, because a timer is a run loop and `VoccaCore` has none. This is the
/// instruction it carries out, and it carries the interval with it so that the cadence and the
/// decision to run at that cadence cannot drift apart in two files.
public enum WatchdogSchedule: Sendable, Hashable {
    /// Wake the watchdog every `interval` until it says otherwise.
    case wake(every: Duration)

    /// Nothing is being captured. Stop the timer: there is no microphone to watch, and a timer
    /// running against an idle machine is battery spent to learn nothing.
    case stopped
}

/// **The hot-mic guarantee**: the policy that decides when to look, what a release means, and how a
/// system event maps onto a stop.
///
/// ``SessionMachine`` deliberately owns none of this. It has no timer; it checks the ceiling when
/// ``SessionMachine/tick()`` is called and considers the physical key when
/// ``SessionMachine/observePhysicalKey(isDown:)`` is called, and at no other moment. This is the
/// thing that calls them, and the seam between the two is kept this thin so that the policy cannot
/// quietly acquire an opinion about *speech* — the moment it looks at audio content it is VAD, which
/// `ROADMAP.md:45` defers to P3.
///
/// ## Why it holds the machine
///
/// It could have been advisory — return "you should poll now" and let `hotkey-source` do it. That
/// shape cannot make the guarantee, for the reason ``SessionAudioSource`` gives about the
/// microphone: "the session ends when the user stops asking for it" would then depend on an owner
/// remembering to route the answer back, and the owner is the layer full of system APIs that this
/// aspect exists to keep the guarantee out of. With the machine here, waking the watchdog *is*
/// applying the policy.
///
/// ## It holds no state of its own, and that is the design
///
/// Every question it answers — is the timer running, is the ceiling near, should the key be read —
/// is computed from the machine it holds. There is no `isArmed` flag, so there is no way for the
/// watchdog and the machine to disagree about whether a session is running. That is the same
/// prohibition `decide(_:state:config:)` is written under and the same defect it names:
/// [Handy #840](https://github.com/cjpais/Handy/issues/840) desynchronised permanently after one
/// missed event, because it accumulated a total instead of deriving one.
///
/// It is what makes the machine's strangest legal behaviour a non-event here. A session can live and
/// die entirely inside one `observe(keyDown)` call — a stop that arrived while the microphone was
/// opening is applied before `beginSession` returns, so the caller sees `.ended` from the key-down
/// and that session's `.started` is never observed by anybody. A watchdog that armed on `.started`
/// and disarmed on `.ended` would have to get that case right on purpose. This one cannot see it:
/// the machine is `.idle`, so the schedule is `.stopped`.
///
/// ## Isolation
///
/// Not `Sendable`, and it cannot be: it holds a ``SessionMachine``, which is deliberately not
/// `Sendable` because a `CGEvent` tap callback is a synchronous C function. So the tap, the machine
/// and this timer all live in one isolation domain — `@MainActor` in `hotkey-source` — and
/// everything this returns is `Sendable` so it can cross to the actor that transcribes.
public final class SessionWatchdog<Audio: CapturedAudio> {
    private let machine: SessionMachine<Audio>
    private let keyState: any PhysicalKeyStateReader

    /// - Parameters:
    ///   - machine: The session to watch. Its ceiling and its configured key are read from it
    ///     rather than passed again here: two copies of either could disagree, and the one that
    ///     matters — which key code the poll asks about — would then poll a key the machine is not
    ///     watching and report a release that means nothing.
    ///   - keyState: The seam the physical read arrives through.
    public init(machine: SessionMachine<Audio>, keyState: any PhysicalKeyStateReader) {
        self.machine = machine
        self.keyState = keyState
    }

    // MARK: - What the owner should be doing

    /// Whether the owner's timer should be running, and how fast.
    ///
    /// Derived from the machine's state on every read. A session that is recording is watched; one
    /// that is not, is not — which is the whole battery argument, since the alternative is a 150 ms
    /// timer running for as long as the application does.
    public var schedule: WatchdogSchedule {
        switch machine.state {
        case .recording:
            return .wake(every: WatchdogPolicy.pollInterval)
        case .idle, .ending:
            // `.ending` is only ever observed from inside the handoff — a queued key event
            // delivered while the audio source is being stopped. The session is over either way,
            // and nothing about it needs watching.
            return .stopped
        }
    }

    /// When, in a session's life, the widget should start warning about the ceiling.
    ///
    /// Derived from *this machine's* ceiling, so a configured ceiling moves its own warning. See
    /// ``WatchdogPolicy/warningThreshold(before:)``.
    public var warningThreshold: Duration {
        WatchdogPolicy.warningThreshold(before: machine.ceiling)
    }

    /// Whether the widget should be showing that warning right now.
    ///
    /// Measured against ``SessionMachine/elapsed``, which advances on ``wake()``, so this becomes
    /// true within one poll interval of the threshold. A warning is not a stop: the session keeps
    /// running, and the only thing that ends it at the ceiling is ``SessionMachine/tick()``.
    public var ceilingIsNear: Bool {
        switch machine.state {
        case .recording:
            return machine.elapsed >= warningThreshold
        case .idle, .ending:
            // No session, no ceiling to approach. A warning left showing over an idle widget is
            // the same lie as a recording indicator over a closed microphone, in the other
            // direction.
            return false
        }
    }

    // MARK: - Inputs

    /// One observed keyboard event, on its way to the machine.
    ///
    /// **This is the path that arms the watchdog, and it is the reason the wrapper exists.** A key
    /// event is the only input that can move the machine into `.recording`, so it is the only one
    /// after which ``schedule`` changes from `.stopped` to `.wake(every:)` and the owner must start
    /// its timer. An owner that routed key events straight to the machine would be holding two
    /// objects with overlapping responsibilities and reading the schedule off the one the session
    /// did *not* start through — which is not a mistake anybody makes on purpose, and is exactly the
    /// kind that gets made.
    ///
    /// Be precise about what this buys, because it is easy to overclaim: it does **not** force the
    /// owner to re-read ``schedule``, and nothing in a module with no run loop could. What it buys
    /// is that every input a session has arrives through this one object, so there is no second
    /// door for one to come in by unseen. Reading is separate — see ``cancel()``.
    ///
    /// **The event's disposition is the machine's, returned unchanged, and the stake in that is the
    /// whole keyboard.** The tap delivers *every* key event here, not only the hotkey's, because
    /// stop rule (c) is "any event whose flags no longer carry the configured modifier"
    /// (`spec.md:47`) and the rules cannot apply it to events they never see. So this method sees
    /// nearly every keystroke the user makes all day, and `decide` passes nearly all of them
    /// straight back. A wrapper that decided propagation for itself would not mishandle an edge
    /// case; a hard-coded `.swallow` here eats the user's entire keyboard, in every application, for
    /// as long as Vocca runs. `SessionWatchdogTests` pins **both** directions across this seam —
    /// the first round pinned only the swallow, and the mutation survived.
    public func observe(_ event: RawKeyEvent) -> SessionResponse<Audio> {
        machine.observe(event)
    }

    /// One turn of the owner's timer: **look at the key, then look at the clock** — in hold-to-talk.
    /// In toggle mode there is no key to look at, and the branch below says why at length.
    ///
    /// Exactly one effect comes out, because at most one session can end per wake — once the first
    /// of the two ends it there is nothing left for the second to end.
    ///
    /// **The order is load-bearing, in the one case where both are true.** That case is a key-up
    /// lost in the final interval before the ceiling, and its honest cause is the release: the user
    /// let go, and Vocca had to find that out by asking rather than by being told. Ending it as
    /// `.ceilingReached` would file a report of "the user talked for two minutes" over what is
    /// really a missed key-up, and the log is the only evidence anyone gets — the same precedence
    /// argument ``SessionMachine`` makes for its deferred stop, for the same reason.
    ///
    /// **Nothing is read while idle.** Not merely an optimisation: a stray timer fire after the
    /// session has ended must not cost a system call, and a poll answered for a session that no
    /// longer exists is an answer about somebody else's press.
    ///
    /// The clock is only ever the machine's. This method advances nothing and remembers nothing, so
    /// **the ceiling rests on two things outside this module, and fails silently if either gives
    /// way**: the owner's timer must keep firing, and the injected ``MonotonicClock`` must keep
    /// advancing. They fail differently and both are worth naming here, because in each case
    /// everything else goes on looking healthy. A timer that stops means nothing runs at all. A
    /// clock that stalls means every wake still happens and the poll still answers correctly — see
    /// ``MonotonicClock`` — while `elapsed` never moves and the ceiling is simply never reached.
    public func wake() -> SessionEffect<Audio> {
        switch machine.state {
        case .idle, .ending:
            return .unchanged
        case .recording:
            break
        }

        switch machine.configuration.activation {
        case .holdToTalk:
            // Hold-to-talk's defining fact: the user's finger is the endpointer, so a key that is
            // not held is a session that should not be running. The machine decides what to do
            // about the answer — including that `isDown: true` is a no-op — so the poll reports
            // what it read rather than deciding on its way in.
            let polled = machine.observePhysicalKey(
                isDown: keyState.isKeyDown(machine.configuration.keyCode))

            switch polled {
            case .ended:
                return polled
            case .unchanged, .started, .captureUnavailable:
                // A poll cannot open a microphone, so the last two are unreachable — and are
                // grouped with `.unchanged` rather than trapped, because the safe reading of an
                // answer this method did not expect is "a session may still be running", and the
                // ceiling is the thing that bounds that. Skipping the tick would be the one choice
                // that leaves the microphone open.
                return machine.tick()
            }

        case .toggle:
            // **Rule (f) is not applied, and nothing replaces it.** A toggle session runs with the
            // key released for its whole life, so `isKeyDown` answers `false` on the first wake,
            // 150 ms after the user started talking. Stop rule (f) would not be a weaker guarantee
            // in this mode; it would be a session that cannot happen at all.
            //
            // **Nothing replaces it at this seam** — a narrower claim than "nothing replaces it",
            // and the narrowing is the point; see the end of this comment. Rule (f) works in
            // hold-to-talk because the condition the session continues under — "the key is held" —
            // is a state of the world, and `CGEventSourceKeyState` reads that state without going
            // through the tap. A toggle session continues under "the user has not pressed again",
            // which is not a state of anything: it is the absence of a future event, and no poll
            // can read an absence.
            //
            // Detecting the *press* instead was considered and rejected, on one decisive ground and
            // one cost:
            //
            // - **Decisive:** it needs an edge and this seam offers a level, so an edge has to be
            //   reconstructed from samples — and at 150 ms an ordinary 60 ms tap falls between two
            //   of them and is missed outright. A mechanism that fires late and only sometimes is
            //   worse than none, because the hot-mic bound would then be quoted from it.
            // - **A cost, not an impossibility:** `isKeyDown(_:)` takes one key code, so the chord
            //   would have to be read modifier by modifier — the modifier keys have virtual key
            //   codes of their own, left and right, readable through the same primitive. That is
            //   several more calls per wake plus a `ModifierSet`-to-key-codes map, and the map is a
            //   fact about the system, so it belongs to `hotkey-source` and would mean widening
            //   this seam. Worth stating accurately rather than as a wall: a reader who checks this
            //   and finds it overstated has cause to discount the decisive reason too.
            //
            // So what bounds a toggle session *today* is: this ceiling, `.tapDisabled`, the five
            // system triggers, cancellation, and the user's own next press. The ceiling is the only
            // *unconditional* one, which makes it load-bearing here rather than a backstop —
            // `SessionWatchdogTests` measures the difference (one poll interval against the full
            // ceiling) side by side rather than restating it, and the widget's
            // ``ceilingIsNear`` warning is the user-facing half of the same fact.
            //
            // **What would actually close the gap is not at this seam at all: a device-independent
            // retained stop.** A widget click, a menu-bar item, a VoiceOver-reachable control — any
            // input that does not travel through the `CGEvent` tap is immune to the failures that
            // make the second press vanish (a higher-priority tap consuming it, a stalled tap, a
            // focus race). Note that ``cancel()`` is *not* it: cancellation discards, so a toggle
            // user whose stopping press is lost has exactly one way to stop inside that window and
            // it throws their words away — which is the invariant this whole aspect exists to
            // protect, failing in the mode that exists for accessibility.
            //
            // In this module that is one public method routed through the same stop funnel plus one
            // ``RetainedEndReason``. It is deliberately **not built here**: the control it needs
            // does not exist in `PRODUCT_SPEC.md` yet (§2's widget has no stop affordance and §11's
            // menu bar lists only state, mode toggle, last transcript, Settings and Quit), so it is
            // a product question first and `hotkey-source`'s to deliver second.
            //
            // The cadence is unchanged and deliberately so, even though this branch makes no system
            // call: ``SessionMachine/elapsed`` only advances when someone ticks, and the widget
            // renders both the elapsed time and the warning from it. A slower toggle timer would
            // buy battery the poll was already paying for and spend it on a stuttering clock in
            // front of the user.
            return machine.tick()
        }
    }

    /// A system event that makes continuing impossible or wrong, on its way to the machine.
    ///
    /// Delivery is the owner's — `NSWorkspace.willSleepNotification` and its four siblings are
    /// AppKit, which this module cannot see — and the mapping from trigger to reason is
    /// ``SessionMachine/observe(_:)``'s. What routing them through here buys is that the owner
    /// holds one object for the whole lifecycle: a trigger ends the session *and* settles the
    /// timer, because ``schedule`` is read off the same machine this just stopped.
    ///
    /// A trigger arriving with no session is a no-op, and has to be: these are broadcasts, they
    /// arrive whether or not Vocca is recording, and the machine sleeping is not an event that owes
    /// anybody an outcome.
    public func observe(_ trigger: SystemTrigger) -> SessionEffect<Audio> {
        machine.observe(trigger)
    }

    /// The user abandoned the session — Escape — on its way to the machine.
    ///
    /// Here for completeness, and completeness is the whole argument: wrapping the key-event path
    /// and not this one would leave "every input arrives through one object" *nearly* true, which is
    /// the state in which someone reasonably concludes they may keep a reference to the machine for
    /// the one input the watchdog does not take, and then uses it for the ones it does.
    ///
    /// With this, the four inputs a session owner has — a key event, a system trigger, a
    /// cancellation, a timer wake — are all here, and the machine's remaining public inputs
    /// (`tick()`, `observePhysicalKey(isDown:)`) are the mechanism ``wake()`` drives on the owner's
    /// behalf. An owner never has a reason to call those.
    ///
    /// **That is a claim about inputs and nothing else.** Reading is a different matter and the
    /// widget is the reason: it renders from ``SessionMachine/state`` and ``SessionMachine/elapsed``,
    /// so something will hold the machine to read it. What the wrapping buys is that nothing *drives*
    /// a session by a route the schedule is not read after — not that the machine is unreachable.
    ///
    /// Cancelling still closes the microphone: discarding a transcript and holding the microphone
    /// are different things, and only the first was ever asked for.
    public func cancel() -> SessionEffect<Audio> {
        machine.cancel()
    }
}
