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

// MARK: - Why the tap stopped delivering

/// Which of the two out-of-band disablements the operating system reported.
///
/// **They are different facts and a log that conflates them costs a debugging session.** Both arrive
/// out of band — not through the event mask, so not as a `RawKeyEvent` — and both are recovered from
/// identically, which is exactly why the distinction has to be carried deliberately: the recovery
/// gives no reason to keep them apart, and the diagnosis gives every reason.
public enum TapDisableReason: Sendable, Hashable, CaseIterable {
    /// `kCGEventTapDisabledByTimeout`. **Vocca's own defect**: the callback took too long, so the
    /// window server stopped trusting it. `HotkeyEventSink/receive(_:)` records a known route to
    /// exactly this — the shipped sink is synchronous down to an audio-engine start — so this is a
    /// symptom with a suspect already named, not a mystery.
    case timeout

    /// `kCGEventTapDisabledByUserInput`. **Not Vocca's defect.** The system or the user switched
    /// taps off. Nothing in the callback caused it and nothing in the callback can prevent it.
    case userInput
}

extension TapDisableReason {
    /// Whether this disablement is something Vocca did to itself.
    ///
    /// The one bit that separates "fix the callback" from "there is nothing to fix here", exposed so
    /// that a caller which only wants to know *whose problem it is* does not have to re-derive it
    /// from the case — and so that the derivation is written once, in the module that knows.
    ///
    /// Switched without a `default:`, so a third disablement reason has to state its own answer.
    public var isVoccasOwnDefect: Bool {
        switch self {
        case .timeout: return true
        case .userInput: return false
        }
    }
}

/// Why the tap was destroyed and built again, rather than merely switched back on.
///
/// Three causes, and re-creation is the only recovery for two of them — `CGEventTapEnable` cannot
/// resurrect a tap whose mask was cleared at creation (`spec.md` constraint 3), so "switch it back
/// on" is not an option that was passed over.
public enum TapRecreationCause: Sendable, Hashable, CaseIterable {
    /// Re-enabling a disabled tap in place did not take. `spec.md:57`: *"if re-enable fails, tear
    /// down and re-create"*.
    case reenableFailed

    /// **There was no tap to switch back on.** Something reported the tap dead — a disable
    /// notification, or a health poll — while the policy held no tap at all, which is the ordinary
    /// shape of a first run whose `arm()` found no Accessibility grant.
    ///
    /// It is a distinct cause rather than folded into ``reenableFailed`` because nothing was
    /// attempted and nothing failed: a log reading "re-enable failed" for a call that was never made
    /// sends the next reader after `CGEventTapEnable` instead of after the missing grant.
    case noTapToReEnable

    /// The owner armed a policy that already had a tap, so the old one was replaced.
    ///
    /// Reported as a re-creation rather than as a second ``TapHealthNote/armed`` because the note
    /// channel exists to make *"the tap has been replaced eleven times in a minute"* visible, and a
    /// log reading `[.armed, .armed]` cannot show that anything was replaced at all.
    case rearmed

    /// The machine woke. **Taps die silently across sleep/wake** — no disable event, no error, and
    /// nothing to notice except that the hotkey has stopped working.
    case systemDidWake

    /// The Accessibility grant changed. This is the one that *must* be a re-creation: a tap created
    /// without the grant had its mask cleared at creation, and no amount of enabling brings it back.
    case accessibilityGrantChanged
}

// MARK: - Where the tap stands

/// Where the tap stands after the policy has acted.
///
/// Three cases, switched exhaustively and without a `default:`, and the third exists because the
/// other two would otherwise have to lie for it. "The owner has not asked for a tap" is not
/// "permission is missing" — one is a state the user chose and the other is a permission dialog the
/// user has to be shown — and a policy that reported the second for the first would send Vocca's
/// onboarding after a grant it already has.
public enum TapHealth: Sendable, Hashable, CaseIterable {
    /// Key events are reaching the sink.
    case delivering

    /// The tap could not be created. `CGEvent.tapCreate` returning `nil` **is** the permission check
    /// (`spec.md` constraint 3), so this is the honest report of a missing Accessibility grant — and
    /// acceptance H5 is that it is reported at all rather than becoming a silent no-op.
    case permissionMissing

    /// No tap has been asked for: ``TapHealthPolicy/arm()`` has not been called, or
    /// ``TapHealthPolicy/disarm()`` has. Vocca is deaf on purpose.
    case notArmed

    /// **A tap exists and is not delivering**, and the recovery for it is rate-limited rather than
    /// due on this turn — see ``TapHealthPolicy/pollTapHealth()``.
    ///
    /// A fourth case because the other three would each have to lie for it, which is the same
    /// argument ``notArmed`` was added on. `delivering` is plainly false. `notArmed` is false: the
    /// owner asked for a tap and got one. And `permissionMissing` is the expensive lie — permission
    /// is not the problem here, so a widget acting on it would send a user to System Settings to
    /// grant something they granted already, which is the failure ``notArmed`` exists to prevent in
    /// the other direction.
    ///
    /// **Vocca is deaf while this is the answer, and the microphone is not open** — the session, if
    /// there was one, was ended before this was returned.
    case notDelivering
}

/// One thing that happened to the tap, in the words that tell it apart from every other thing.
///
/// The policy's **diagnostic** channel, separate from what it returns. The return value answers
/// *where does the tap stand now*, which is what a caller acts on; this answers *what happened*,
/// which is what a caller writes down. Two disablements that recover identically produce the same
/// ``TapHealth`` and different notes, which is the whole reason the channel is separate.
public enum TapHealthNote: Sendable, Hashable {
    /// A tap was created for the first time by ``TapHealthPolicy/arm()``.
    case armed

    /// Creation failed. Accessibility is not granted.
    case permissionMissing

    /// The operating system disabled the tap out of band. **Carries which reason**, because that is
    /// the fact the seam cannot carry: `RawKeyEvent.Kind.tapDisabled` is one kind for both.
    case disabled(TapDisableReason)

    /// **A health poll found the tap not delivering, and nothing had said so.**
    ///
    /// Distinct from ``disabled(_:)`` because the two are different facts about the world: that one
    /// is the OS telling us, this one is the OS *not* telling us and Vocca finding out by asking. A
    /// log that conflated them would hide the case worth knowing about — a tap dying with no
    /// notification of any kind is the only route by which a session outlives its tap.
    case foundDeadByPoll

    /// A disabled tap was switched back on in place. No new tap was needed.
    case reenabled

    /// The tap was destroyed and created again.
    case recreated(TapRecreationCause)

    /// A re-creation was attempted and the new tap could not be created. Vocca is deaf until the
    /// grant arrives.
    case recreationFailed(TapRecreationCause)

    /// The owner asked for the tap to stop.
    case disarmed
}

// MARK: - The seam this policy acts over

/// A ``HotkeyEventSource`` the operating system can switch off underneath, and switch back on.
///
/// **Deliberately not part of ``HotkeyEventSource``.** Being disabled out of band and re-enabled in
/// place is a fact about a `CGEvent` tap, not about hotkey sources in general: the Carbon
/// `RegisterEventHotKey` fallback (`spec.md:88`) has no such state, and a protocol that demanded one
/// of it would make it answer a question it has no answer to. So the refinement lives here, in the
/// adapter module, next to the only policy that has any use for it.
///
/// It is still phrased entirely in this package's own types, and the H7 lint holds over this file
/// exactly as it does over every other: a re-enable that returned a `CFMachPort`, or took one, would
/// have moved the decision below the seam where no CI run can reach it.
public protocol RecoverableHotkeyEventSource: HotkeyEventSource {
    /// Whether the tap is delivering **right now**, asked of the tap rather than remembered.
    ///
    /// The read the ~1 s health poll is made of (`spec.md:57`), and the whole value of it is that it
    /// is a *question put to the system*. A conformance that answered from a cached flag would be
    /// reporting the last thing Vocca was told — which is exactly what the poll exists to bypass,
    /// because the case it is for is a tap that died and told nobody. `CGEventTapIsEnabled` is the
    /// call; the adapter must make it every time.
    ///
    /// `false` when no tap exists, because a tap that is not there is not delivering.
    var isDelivering: Bool { get }

    /// Switch delivery back on for a tap the system disabled, **without creating a new one**.
    ///
    /// The cheap recovery, and the one that keeps the tap's existing registration — which is why it
    /// is tried before re-creation rather than instead of it.
    ///
    /// **A conformance must read the result back rather than report success from having asked.**
    /// `CGEventTapEnable` returns `Void`: it cannot fail loudly, so an adapter that returned
    /// ``TapResume/resumed`` because it made the call would report a dead tap as healthy, and the
    /// re-creation that acceptance H4 requires would never happen. The answer comes from asking the
    /// tap whether it is enabled, afterwards — ``isDelivering`` is that question.
    ///
    /// **And when there is no tap at all, the answer is ``TapResume/failed``.** The read-back rule
    /// above says *how* to answer; this says what to answer when there is nothing to ask. An adapter
    /// holding an optional port has to decide that, and a decision left below the seam is the one
    /// thing this aspect's organising constraint forbids — so it is decided here. ``TapHealthPolicy``
    /// does not rely on it: it tracks tap existence itself and does not call this method without one.
    /// Both are needed, because "healthy while deaf" must not have a second place it can be reached
    /// from.
    func resumeDelivery() -> TapResume
}

/// How often the owner's timer must ask after the tap's health.
///
/// A named constant rather than a number for phase 5 to invent, in the same shape as
/// `WatchdogPolicy.pollInterval`, because the two timers are siblings and will be wired by the same
/// commit.
public enum TapHealthPolling {
    /// The cadence `spec.md:57` asks for, and the bound on how long a silently dead tap can hold a
    /// microphone open with nobody notified.
    ///
    /// The trade is one system call per second against that bound. Shortening it buys a tighter
    /// bound and costs a call; lengthening it is a decision about how long a hot mic may last, which
    /// is why the number is here, next to that sentence, rather than at the timer's call site.
    public static let interval: Duration = .seconds(1)

    /// How many polls pass between **repeated** recovery attempts by the poll.
    ///
    /// **Not the same question as the poll's own cadence, and it must not inherit it.** Asking a live
    /// tap whether it is enabled is one cheap read; recovering is `CGEventTapEnable` and often
    /// `CGEvent.tapCreate` plus a run-loop source. The poll has two ways to find trouble that
    /// persists, and **both of them repeat forever if nothing slows them down**:
    ///
    /// - **No tap.** The state every first run is in, and where a user who declines Accessibility
    ///   stays. Measured ungated: 61 `tapCreate` calls and 121 health-log lines a minute.
    /// - **A tap that exists and never delivers.** Each turn re-enables or re-creates, succeeds, and
    ///   finds it dead again a second later. Measured ungated: *the same 61 and 121* — the first
    ///   version of this constant bounded only the branch above and left this one untouched. Not
    ///   exotic either: `TapDisableReason/timeout` is the window server disabling a tap whose
    ///   callback is too slow, and ``TapHealthPolicy/tapWasDisabled(_:)`` records that the recovery
    ///   path makes that callback slower still.
    ///
    /// Either way the diagnostic channel is destroyed in the state it most needs to be readable,
    /// since eleven real re-creations would be invisible in a hundred and twenty lines of noise.
    ///
    /// **What is throttled is the recovery, and never the ending.** A session stranded over a dead
    /// tap is closed on *every* poll, gated or not: a rate limit exists to save system calls, and a
    /// microphone is not a system call. That distinction is the whole design here, and it was got
    /// wrong once — a gate placed above the ending turned a one-second hot mic into a
    /// thirty-one-second one.
    ///
    /// **And the first discovery is never delayed.** A poll that finds the tap healthy re-arms the
    /// entitlement to recover at once, so a tap that dies five seconds after it was created is
    /// recovered on the very next poll.
    ///
    /// ## What this constant does *not* bound, stated exactly
    ///
    /// **It bounds a run of consecutive trouble, not a minute.** A tap that *flaps* — dies, is
    /// recovered, works for one poll, dies again — is a new discovery every time by the rule above,
    /// so every one of those is acted on. Measured at one death every other poll:
    ///
    /// | | recoveries | health-log lines |
    /// |---|---|---|
    /// | dies every other poll | 30 a minute | 60 a minute |
    /// | dies every third poll | 20 a minute | 40 a minute |
    /// | dies and stays dead | 2 a minute | 4 a minute |
    ///
    /// That is left alone deliberately, and it is a judgement rather than an oversight. Tightening it
    /// means not re-arming on health, which reintroduces the failure the re-arm exists to prevent: a
    /// genuinely new fault waiting out a counter earned by an old one. And the cost here is
    /// proportional to something real — the tap is dying thirty times a minute and Vocca is fixing it
    /// thirty times — so sixty log lines describing thirty successful recoveries is the diagnostic
    /// anyone debugging that would want, not noise to be suppressed. The two states the bound *does*
    /// cover are the ones where nothing changes between attempts and the log says the same thing
    /// forever.
    ///
    /// `TapHealthPolicyTests.testAFlappingTapIsRecoveredEveryTimeAndTheCostIsProportional` pins the
    /// numbers above, so this table cannot drift from the behaviour.
    ///
    /// The retry is kept rather than dropped, because a grant notification that
    /// `DistributedNotificationCenter` drops would otherwise leave Vocca deaf until the next wake.
    /// ``TapHealthPolicy/accessibilityGrantChanged()``, ``TapHealthPolicy/arm()`` and
    /// ``TapHealthPolicy/systemDidWake()`` are unaffected: **only the poll is throttled.**
    public static let pollsBetweenRecoveryAttempts = 30
}

/// Whether a disabled tap started delivering again.
///
/// A two-case enum rather than a `Bool` for the same reason ``HotkeyEventSourceStart`` is one: it is
/// switched exhaustively, so a third answer becomes a compile error at the place that has to decide
/// what it means.
public enum TapResume: Sendable, Hashable, CaseIterable {
    /// The tap is delivering again. No new tap was needed.
    case resumed

    /// It is not. The tap must be torn down and re-created — acceptance H4.
    case failed
}

// MARK: - The policy

/// **What to do about a tap that is dying, over a tap that is injected.**
///
/// Every decision in this aspect's recovery path, in one object with no system call in it. The tap
/// itself arrives through ``RecoverableHotkeyEventSource``; `CGEvent.tapCreate`, `CGEventTapEnable`
/// and the `@convention(c)` callback are all on the far side of that, in the half of this capability
/// CI can never execute (`spec.md:19`). What is left here is the half worth testing: six entry
/// points, and what each of them does about the microphone.
///
/// ## The one rule the whole class is arranged around
///
/// **Every entry point ends any in-flight session, first, unconditionally — with one exception,
/// argued at ``pollTapHealth()``.**
///
/// Not "when a tap is re-created", not "when the disablement was a timeout" — every one of them,
/// before anything that could fail or return early. The argument is short: a tap that died may have
/// dropped the key-up, the key-up is the only thing that would have ended the session, and a session
/// that outlives the tap that was feeding it is a microphone that stays open with the widget
/// insisting it is closed. `PRODUCT_SPEC.md:11` exists to defend exactly that sentence.
///
/// Making it unconditional is a decision about *testability*, not only about safety: a conditional
/// end has an ordering, a guard and an early return, and each of those is a place a mutation can
/// skip it. There is no such place here. The session is ended before the policy has looked at
/// whether it is armed, before it has asked the source for anything, and before any branch.
///
/// **And ending first is not sufficient on its own**, which is the correction this class needed
/// three times before it was stated as a rule. A session can *start* during the work — see
/// ``endAnyStrandedSession()`` — so the two operations that can leave the policy without a tap end
/// again afterwards. The rule in full is: *end before, and again after, if what is left cannot end
/// it itself.*
///
/// ## How a session is ended from here
///
/// By delivering one synthetic ``RawKeyEvent`` of kind `.tapDisabled` to the sink — the vocabulary
/// `VoccaCore` already has for this, and the route the rules already handle: rule (d) is checked
/// **before** any other stop rule precisely because such an event's modifier flags mean nothing
/// (`SessionRules.swift:95`). The session therefore ends as `.retained(.tapDisabled)`, which is the
/// true cause, and its audio travels with it because every retaining reason's does.
///
/// Two consequences worth stating, because both are asserted rather than assumed:
///
/// - **The synthetic event never reaches the source, and so never reaches the focused
///   application.** It is not a keystroke; there is no key behind it. It goes straight to the sink.
/// - **Its key code and modifiers are not read by anything**, which is why they are zero and empty.
///   `decide` reaches rule (d) before it compares a key code, and `claimsThisEvent` answers `false`
///   for `.tapDisabled` without consulting either field. A session bound to key code 0 ends exactly
///   as one bound to `Space` does.
///
/// Its **timestamp** is real, from the injected clock. `RawKeyEvent/timestamp` is documented as the
/// caller's to supply — the core reads no clock — and this is the caller.
///
/// ## Why the diagnosis leaves by a different door from the decision
///
/// The methods return a ``TapHealth``: where the tap stands, which is what an owner acts on. The
/// ``TapHealthNote``s go to a closure: what happened, which is what an owner writes down. They are
/// separate because the two disablement reasons **recover identically and diagnose completely
/// differently** — `.timeout` means Vocca's own callback was too slow and `.userInput` means it was
/// not — and a single return value would have had to either flatten that or grow a case for a
/// distinction no caller acts on.
///
/// ## What the owner must do after every entry point
///
/// **Re-read `SessionWatchdog.schedule`.** Ending a session moves it from `.wake(every:)` to
/// `.stopped`, and every entry point here can end one **except a health poll that found the tap
/// working** — which is the one that fires most often — so the owner's timer must be reconsidered
/// after each — exactly as it must after a key event. Getting it wrong costs a timer spinning over
/// an idle machine rather than a hot mic (`tick()` and `wake()` both answer `.unchanged` in `.idle`),
/// but phase 5 is the phase that wires that timer and is therefore the phase that would get it wrong.
///
/// ## Isolation
///
/// Not `Sendable`, and it cannot be: it holds a ``HotkeyEventSink``, which in the shipped
/// composition holds a `SessionWatchdog` and a `SessionMachine`, both deliberately non-`Sendable`
/// because a tap callback is a synchronous C function that cannot `await`. The tap, this policy, the
/// sink, the machine and the timer all live in one isolation domain — `@MainActor` in
/// `hotkey-source` (`spec.md` constraint 5).
public final class TapHealthPolicy {
    private let source: any RecoverableHotkeyEventSource
    private let sink: any HotkeyEventSink
    private let clock: any MonotonicClock
    private let note: (TapHealthNote) -> Void

    /// Whether the owner currently wants a tap.
    ///
    /// **Set by ``arm()`` even when creation fails**, and that is the point rather than an oversight:
    /// the ordinary first run has no Accessibility grant, so the first `arm()` returns
    /// ``TapHealth/permissionMissing`` — and the grant that arrives thirty seconds later must find a
    /// policy that still wants a tap, or the user grants permission and nothing happens.
    private var isArmed = false

    /// Whether a tap exists to be acted on.
    ///
    /// **A second field, because it is a second fact, and conflating the two shipped a defect.** With
    /// one flag, `tapWasDisabled` on a policy that wanted a tap but had none called
    /// `resumeDelivery()` anyway — asking a conformance a question about an object it does not
    /// have — and returned ``TapHealth/delivering`` with a `.reenabled` note over nothing at all.
    /// Both channels wrong in the same call, and every session afterwards starting nothing: the
    /// "healthy while deaf" failure this class's ``systemDidWake()`` documentation names.
    ///
    /// The two differ in exactly the case that matters. *Wanting* a tap survives a failed creation,
    /// on purpose. *Having* one does not. So every branch has to be clear which it is asking about,
    /// and this is written from one place — ``createTap(reportingSuccessAs:failureAs:)`` — so there
    /// is no second path that could set one and forget the other.
    private var aTapExists = false

    /// Polls seen since the health poll last attempted a recovery.
    ///
    /// Bookkeeping for one thing only — how often ``pollTapHealth()`` may act — and read nowhere
    /// else. It is deliberately **not** a third fact about the tap: `isArmed` and ``aTapExists`` are
    /// the two facts, and adding a third that meant something about the tap's *state* is how the
    /// first two came to be confused. This is a counter, written in ``aRecoveryIsDue()`` and in the
    /// healthy branch of the poll, and read in one place.
    ///
    /// **Starts due.** A policy that has never polled has never attempted a recovery, so the first
    /// trouble it meets is handled at once; and a healthy poll puts it back here, so the counter only
    /// ever delays a *repeat*. Both matter, and the second is the one that is easy to get wrong: a
    /// counter reset by a creation instead would leave a tap that dies five seconds after it was
    /// created waiting out the remaining twenty-six.
    private var pollsSinceTheLastRecoveryAttempt = TapHealthPolling.pollsBetweenRecoveryAttempts

    /// - Parameters:
    ///   - source: The tap, injected. Everything this class does to it, it does through this seam.
    ///   - sink: Where key events go, and the only route this class has to the session. Held here as
    ///     well as handed to the source because the synthetic end is *this object's* event, not one
    ///     the source observed.
    ///   - clock: The only way time enters. Used for the synthetic event's timestamp.
    ///   - note: Where the diagnosis goes. Called for every state change, including the ones that
    ///     recovered cleanly — a health log that only records failures cannot show that a tap has
    ///     been re-created eleven times in a minute, which is the shape of the defect this channel
    ///     exists to make visible.
    public init(
        source: any RecoverableHotkeyEventSource,
        sink: any HotkeyEventSink,
        clock: any MonotonicClock,
        note: @escaping (TapHealthNote) -> Void
    ) {
        self.source = source
        self.sink = sink
        self.clock = clock
        self.note = note
    }

    // MARK: Entry points

    /// Create the tap and begin delivering.
    ///
    /// Acceptance **H5** lives here: a `nil` from `CGEvent.tapCreate` arrives as
    /// ``HotkeyEventSourceStart/unavailable`` and leaves as ``TapHealth/permissionMissing`` plus a
    /// note — never as a crash, and never as a silent no-op that leaves an owner believing the hotkey
    /// is live.
    public func arm() -> TapHealth {
        endAnyInFlightSession()
        // Wanting a tap survives a creation that fails. Having one does not — see ``aTapExists``.
        isArmed = true

        guard aTapExists else {
            return createTap(reportingSuccessAs: .armed, failureAs: .permissionMissing)
        }
        // Arming a policy that already has a tap replaces it, because `start(delivering:)` is
        // documented as a `stop()` followed by a `start`. Reported as a re-creation so the log can
        // show that something was replaced.
        return createTap(
            reportingSuccessAs: .recreated(.rearmed), failureAs: .recreationFailed(.rearmed))
    }

    /// The operating system disabled the tap, out of band.
    ///
    /// Acceptances **H3** and **H4**, in that order and for that reason.
    ///
    /// The session ends first and unconditionally, because the key-up that would have ended it is
    /// never coming: a disabled tap receives nothing at all, so every stop rule phrased in terms of a
    /// key event is now unreachable for this session.
    ///
    /// Then the cheap recovery is tried — if the tap still exists, switching it back on keeps its
    /// registration — and **only if that does not take** is the tap torn down and re-created. Both
    /// halves are needed: without the re-enable, every timeout would cost a new tap; without the
    /// re-creation, a tap that refuses to come back stays dead in silence.
    ///
    /// ## Phase 4: this whole method runs inside the tap's own callback, and that is a decision
    ///
    /// Stated here rather than left to be discovered in the half CI cannot execute, in the same
    /// voice as ``HotkeyEventSink/receive(_:)``'s three-constraint tension, because this compounds
    /// it. `kCGEventTapDisabledByTimeout` and `…ByUserInput` are delivered **to the callback**, as
    /// event types, so the adapter's only route to this method is from inside a synchronous C
    /// function that must return a disposition. What that callback then executes is:
    ///
    /// ```
    /// tapWasDisabled(.timeout)
    ///   ├─ endAnyInFlightSession() → sink → watchdog → machine → endSession
    ///   │                                                └─ SessionAudioSource.endCapture()
    ///   │                                                     = AVAudioEngine.stop()   ← slow I/O
    ///   ├─ source.resumeDelivery()  = CGEventTapEnable + read-back
    ///   └─ recreate() → source.start() = stop() + tapCreate + CFRunLoopAddSource
    ///                    └─ stop() invalidates the port whose callback is on the stack right now
    /// ```
    ///
    /// Three things followed, and phase 4 decided them. ``CallbackSafeTapDisablement`` is where the
    /// decision lives; this is what it was decided against:
    ///
    /// 1. **Inherited constraint 7** — *"do nothing in the tap callback"* — is violated by the
    ///    recovery path as much as by the start path. It reads **worse on the `.timeout` route**,
    ///    because that timeout was earned by the callback being slow — but only reads that way: a
    ///    tap that has been disabled delivers nothing until it is enabled again, so no work done on
    ///    *this* callback can earn a second timeout. What slow work here actually costs is main-thread
    ///    latency and a later recovery, not a further disablement.
    /// 2. **Tearing a tap down from inside its own callback** is the concrete hazard, and it is not
    ///    softened by (1) at all: `stop()` invalidates the `CFMachPort` this callback belongs to and
    ///    removes the run-loop source that is currently dispatching it. That — not the timeout — is
    ///    what the split is for. Resolved as the plan predicted: **end the session synchronously,
    ///    because immediacy is the entire point of it, and defer only the recovery.**
    /// 3. **Only this entry point has that shape.** ``systemDidWake()``,
    ///    ``accessibilityGrantChanged()`` and ``pollTapHealth()`` arrive on notifications and timers,
    ///    not on the callback, so deferring all six entry points would be paying the cost five
    ///    times over for one entry point's problem. They call this method as it stands.
    public func tapWasDisabled(_ reason: TapDisableReason) -> TapHealth {
        endAnyInFlightSession()
        note(.disabled(reason))
        guard isArmed else { return .notArmed }
        return restoreDelivery()
    }

    /// **Close the microphone, and do nothing else.** The half of ``tapWasDisabled(_:)`` that has to
    /// happen while the tap's own callback is still on the stack.
    ///
    /// Added by phase 4, which resolved the tension ``tapWasDisabled(_:)`` records above: the two
    /// disablements are delivered *to the callback*, and the recovery that method performs ends in a
    /// `stop()` that invalidates the `CFMachPort` whose callback is on the stack right now. So the
    /// call is split across a run-loop turn, and this is the near half of the split — the half whose
    /// whole value is that it is not deferred. ``CallbackSafeTapDisablement`` is the only caller and
    /// the split lives there, where a test can drive both halves; this method exists so that the
    /// synthetic `.tapDisabled` event stays minted in one place (see *How a session is ended from
    /// here*) rather than being reconstructed by whoever needs the near half.
    ///
    /// **It is not an entry point, and a caller that stops here has left the tap dead.** Every
    /// method above answers *where does the tap stand now*; this answers nothing, because nothing has
    /// been done about the tap. The obligation it leaves behind is the whole of
    /// ``tapWasDisabled(_:)``, called afterwards — which ends the session again, and must: the rule
    /// this class is arranged around is unconditional for a reason, and a second ending on a machine
    /// that is already idle costs one switch and changes nothing.
    ///
    /// Deliberately not named for the disablement it serves. What it does is close a microphone, and
    /// the two other places that might one day need exactly that — a teardown from a signal handler,
    /// an emergency stop from the widget — would be lying if they had to call something called
    /// `tapWasDisabled`.
    public func endAnyInFlightSessionWithoutRecovering() {
        endAnyInFlightSession()
    }

    /// One turn of the ~1 s health poll (`spec.md:57`), and **the only thing that catches a tap that
    /// is *disabled* without anyone being told.**
    ///
    /// Every other entry point is driven by a notification. This one is driven by a question, and it
    /// exists because there is a failure with no notification at all: a tap can stop delivering
    /// silently, and then nothing that would end a session can ever arrive. Measured before it was
    /// built — armed, delivering, session in flight, tap dies with no notification — the microphone
    /// stays open and the machine stays `.recording`, in **both** activation modes.
    ///
    /// The remaining backstops do not cover it. The physical-key poll is hold-to-talk only and rests
    /// on phase 5's timer; in toggle mode it does not exist at all, and `SessionRules.swift:357-359`
    /// says why in as many words — with the poll gone, rule (d) is *"the only stop that a dead tap
    /// can still deliver"*. So in toggle a silently dead tap is a two-minute hot mic bounded only by
    /// the ceiling. This is what turns that silence into a rule-(d) delivery.
    ///
    /// ## What it cannot see, stated because the sentence above invites the wrong conclusion
    ///
    /// **"Died without telling anyone" has two shapes and this catches one of them.** The detection
    /// is a single read — `CGEventTapIsEnabled` — so it sees a tap that was *disabled* silently. It
    /// cannot see a tap that is **enabled and deaf**: created successfully, reporting itself enabled,
    /// delivering nothing.
    ///
    /// That state is not hypothetical and this package asserts elsewhere that it exists. Inherited
    /// constraint 3 says a tap created before the Accessibility grant has its event mask **cleared at
    /// creation** — which is the whole reason ``accessibilityGrantChanged()`` must re-create rather
    /// than re-enable — and Secure Input (phase 6) is the second instance. In toggle mode that shape
    /// is still a 120 s hot mic with nothing but the ceiling under it, exactly as before this method
    /// existed. `TapHealthPolicyTests.testThePollCannotSeeATapThatIsEnabledAndDeaf` measures it:
    /// 120 polls, a hot mic in both modes, and a health log with nothing to say.
    ///
    /// Closing it needs a read this layer does not have — evidence that events are *arriving*, or
    /// phase 6's `IsSecureEventInputEnabled` for the one instance that has an API. Recorded rather
    /// than fixed, because an overclaim here would stop anyone looking for it.
    ///
    /// ## The one entry point that does *not* end the session unconditionally
    ///
    /// The exception is the reason the rule is worth having, so it is stated rather than hidden: this
    /// method is called every second for as long as Vocca runs, and the overwhelming majority of its
    /// answers are *nothing happened*. A poll that ended the session unconditionally would end every
    /// session within one second of its start — the rule applied without thinking, producing the
    /// exact failure it exists to prevent, in the other direction.
    ///
    /// So the shape is inverted here and only here: **ask first, and end on every answer but one.**
    ///
    /// **That one answer is "the tap is delivering", and it is the only early return in this class
    /// that skips an ending.** It is safe for a reason that has nothing to do with what a session is
    /// doing: a delivering tap can still carry the key-up, so the session has its ordinary way out.
    /// Every other answer — no tap, a dead tap, a disarmed policy — describes a session that no key
    /// event can reach, so every one of them ends first.
    ///
    /// The arming check is **below** the ending, and that placement is the finding this method was
    /// corrected on. `disarm()` clears `isArmed` and then tears the tap down, and the teardown is
    /// where a queued key-down is delivered — so an unarmed policy really can hold a running session,
    /// and it is the state with the fewest ways out of all of them: no tap, no key-up, and no reason
    /// for an owner that has just disarmed to still be polling. `disarm()` closes that at the source
    /// (see ``endAnyStrandedSession()``); this is the backstop, and it must not be the thing that
    /// depends on a claim about what cannot be in flight.
    ///
    /// - Returns: where the tap stands. ``TapHealth/delivering`` is the ordinary answer and means the
    ///   poll found nothing wrong.
    public func pollTapHealth() -> TapHealth {
        if aTapExists && source.isDelivering {
            // A healthy poll re-arms the entitlement to recover at once, so the *next* trouble is
            // treated as the new discovery it is rather than as a repeat of something already being
            // handled. Without this the rate limit would delay the ordinary case — a tap that dies a
            // few seconds after it was created — which is a hotkey dead for half a minute in
            // exchange for nothing at all.
            pollsSinceTheLastRecoveryAttempt = TapHealthPolling.pollsBetweenRecoveryAttempts
            return .delivering
        }

        endAnyInFlightSession()

        guard isArmed else { return .notArmed }

        // **Two situations, and only one of them is a discovery.** With no tap, nothing died
        // silently: `arm()` already said so and logged `.permissionMissing` doing it. Reporting
        // `.foundDeadByPoll` here would fire the one note that marks the case worth knowing about
        // sixty times a minute for the most ordinary case there is.
        guard aTapExists else {
            guard aRecoveryIsDue() else { return .permissionMissing }
            return recreate(because: .noTapToReEnable)
        }

        guard aRecoveryIsDue() else { return .notDelivering }

        note(.foundDeadByPoll)
        return resumeInPlace() ?? recreate(because: .reenableFailed)
    }

    /// Whether the poll may attempt a recovery on this turn, counting the turn if not.
    ///
    /// The whole of the rate limit, in one place, read from the two branches of
    /// ``pollTapHealth()`` and nowhere else. See ``TapHealthPolling/pollsBetweenRecoveryAttempts``
    /// for what it costs and what it must never be allowed to delay.
    private func aRecoveryIsDue() -> Bool {
        guard pollsSinceTheLastRecoveryAttempt >= TapHealthPolling.pollsBetweenRecoveryAttempts
        else {
            pollsSinceTheLastRecoveryAttempt += 1
            return false
        }
        pollsSinceTheLastRecoveryAttempt = 0
        return true
    }

    /// The machine woke from sleep.
    ///
    /// **Re-create, without trying to re-enable first.** A tap that died across sleep did so
    /// silently — there was no disable event, so there is no reason to believe there is anything
    /// left to enable — and a `CGEventTapEnable` on a dead tap succeeds at doing nothing, which is
    /// the failure mode that would leave Vocca deaf while reporting itself healthy.
    public func systemDidWake() -> TapHealth {
        endAnyInFlightSession()
        guard isArmed else { return .notArmed }
        return recreate(because: .systemDidWake)
    }

    /// The Accessibility grant changed.
    ///
    /// **The one case where re-creation is not a preference but the only thing that works.** A tap
    /// created without the grant had its event mask cleared at creation, and `CGEventTapEnable`
    /// cannot resurrect a mask that is not there (`spec.md` constraint 3). This is also the route by
    /// which a first run recovers: `arm()` reported ``TapHealth/permissionMissing``, the user granted
    /// Accessibility, and this is what turns that into a working hotkey.
    ///
    /// The notification does not say which way the grant went, and this does not guess. It
    /// re-creates and reports what happened — so a **revoked** grant arrives here too, and leaves as
    /// ``TapHealth/permissionMissing``, which is the truth.
    public func accessibilityGrantChanged() -> TapHealth {
        endAnyInFlightSession()
        guard isArmed else { return .notArmed }
        return recreate(because: .accessibilityGrantChanged)
    }

    /// Stop delivering, deliberately.
    ///
    /// **Ends the in-flight session, and that is this object's decision to make.**
    /// ``HotkeyEventSource/stop()`` documents that it does not end anything and that the answer
    /// belongs to the owner, above the seam, where it can be tested. This is that owner and this is
    /// that answer: a teardown that left a session running would leave the microphone open with
    /// nothing left that could ever close it, because the thing that delivered key events is gone.
    public func disarm() {
        endAnyInFlightSession()
        isArmed = false
        aTapExists = false
        source.stop()
        endAnyStrandedSession()
        note(.disarmed)
    }

    // MARK: Doing it

    /// Get the tap delivering again, from whatever state it is in. Used by the disable notification,
    /// which acts at once because it is told once.
    private func restoreDelivery() -> TapHealth {
        // **A tap that does not exist cannot be switched back on.** Asking anyway is asking a
        // conformance a question about an object it does not have, and believing the answer is how
        // this class came to return `.delivering` with a `.reenabled` note over nothing at all.
        guard aTapExists else { return recreate(because: .noTapToReEnable) }

        return resumeInPlace() ?? recreate(because: .reenableFailed)
    }

    /// The cheap recovery, tried on a tap that exists. `nil` when it did not take and a re-creation
    /// is the caller's next move.
    ///
    /// Optional rather than a shared `restoreDelivery` because **the two callers differ in exactly
    /// what to do next**: a disable notification re-creates immediately, and a poll re-creates on a
    /// rate limit. Folding that difference behind a flag would put the one decision this method is
    /// next to on the wrong side of a boolean.
    private func resumeInPlace() -> TapHealth? {
        switch source.resumeDelivery() {
        case .resumed:
            note(.reenabled)
            return .delivering
        case .failed:
            return nil
        }
    }

    /// Tear the tap down and build a new one.
    ///
    /// The teardown is ``HotkeyEventSource/start(delivering:)``'s own obligation — that protocol
    /// documents a start on an already-started source as a `stop()` followed by a `start`, because a
    /// conformance that merely overwrote its state would leak a run-loop source and leave a second
    /// tap whose callback still points at the previous context. So this calls `start` once and does
    /// not call `stop` first: doing both would be this class second-guessing a contract the seam
    /// already makes, and the failure mode of getting *that* wrong is a use-after-free.
    private func recreate(because cause: TapRecreationCause) -> TapHealth {
        createTap(
            reportingSuccessAs: .recreated(cause), failureAs: .recreationFailed(cause))
    }

    /// **The only call to ``HotkeyEventSource/start(delivering:)`` in this class**, so that
    /// ``aTapExists`` is written from one place and cannot be set on one path and forgotten on
    /// another. That is not tidiness: the defect this class shipped was two facts sharing one field,
    /// and two fields sharing four update sites would be the same defect with more places to hide.
    private func createTap(
        reportingSuccessAs succeeded: TapHealthNote, failureAs failed: TapHealthNote
    ) -> TapHealth {
        let outcome = source.start(delivering: sink)

        // A failed creation has already destroyed whatever was there — `start` is documented as a
        // `stop()` followed by a `start`, and a re-create that then fails leaves nothing attached.
        // Deaf rather than double-tapped, and this field has to say so or the next recovery will try
        // to re-enable a tap that was torn down on this line.
        aTapExists = outcome == .started

        // **One call, on both outcomes, so the condition inside it is what decides.** The teardown
        // `start` performs can deliver a queued key-down and begin a session; that session is fine
        // when this call succeeded — there is a tap now, and it will carry the key-up — and stranded
        // when it did not. Putting the difference in the check rather than in two call sites is what
        // stops it becoming a line that can be deleted with the suite green. It runs before the note
        // because the note is the owner's closure and the microphone is not its business.
        endAnyStrandedSession()

        switch outcome {
        case .started:
            note(succeeded)
            return .delivering
        case .unavailable:
            note(failed)
            return .permissionMissing
        }
    }

    /// **The post-condition every operation shares: if there is no tap, there is no session.**
    ///
    /// Ending *before* the work is not enough, and that is the class of mistake this file has now
    /// made three times. A session can **start during** the work: `stop()` removes a run-loop source
    /// and invalidates a port, which pumps the run loop, so a key-**down** queued behind the teardown
    /// is delivered while the sink is still attached — after the entry point's ending and before the
    /// tap is gone. If the work then leaves no tap, nothing can ever end that session. There is no
    /// key-up, because there is no tap to carry one; in toggle mode there is no physical-key poll
    /// either; and after a ``disarm()`` there is no reason for the owner to still be polling.
    ///
    /// Called from the two operations that *can* leave the policy without a tap — every creation,
    /// whatever its outcome, and a deliberate teardown — rather than from every entry point, because
    /// those two are the only ones after which the answer to *"can anything still end this?"* may be
    /// no. **Whether it actually is, is the condition below and not the call site**: a creation that
    /// succeeded leaves a tap that will carry the key-up, and this returns having done nothing. Costs
    /// one call into an idle state machine, which answers `.ignore`, on the paths where nothing was
    /// stranded.
    private func endAnyStrandedSession() {
        guard !aTapExists else { return }
        endAnyInFlightSession()
    }

    /// End whatever session is in flight, by handing the sink the one event that says the tap died.
    ///
    /// Called first by every entry point, before any guard and before anything that can fail. See
    /// the type's documentation for why that is a decision about testability as much as about
    /// safety.
    ///
    /// The disposition is discarded, and it is the one place in this aspect where that is right:
    /// there is no keystroke behind this event. It was minted here, it never travelled through the
    /// source, and there is no focused application waiting to be told whether it may have it. Every
    /// event that *did* come from the keyboard has its disposition returned unchanged, which is
    /// inherited constraint 4 and is pinned in both directions at the far end of the seam.
    ///
    /// When there is no session, the rules answer `.ignore` for a `.tapDisabled` event in both
    /// activation modes, so this costs one switch and changes nothing.
    private func endAnyInFlightSession() {
        _ = sink.receive(
            RawKeyEvent(
                kind: .tapDisabled,
                // Never read. `decide` reaches stop rule (d) before it compares a key code, and
                // `claimsThisEvent` answers `false` for `.tapDisabled` without consulting either
                // field — which is itself why rule (d) is checked first: such an event's modifier
                // flags mean nothing. A session bound to key code 0 ends exactly as one bound to
                // Space does, and `TapHealthPolicyTests` runs both to prove it rather than assert it.
                keyCode: 0,
                modifiers: [],
                isAutorepeat: false,
                timestamp: clock.now))
    }
}
