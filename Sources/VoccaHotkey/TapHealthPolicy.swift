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
    /// Switch delivery back on for a tap the system disabled, **without creating a new one**.
    ///
    /// The cheap recovery, and the one that keeps the tap's existing registration — which is why it
    /// is tried before re-creation rather than instead of it.
    ///
    /// **A conformance must read the result back rather than report success from having asked.**
    /// `CGEventTapEnable` returns `Void`: it cannot fail loudly, so an adapter that returned
    /// ``TapResume/resumed`` because it made the call would report a dead tap as healthy, and the
    /// re-creation that acceptance H4 requires would never happen. The answer comes from asking the
    /// tap whether it is enabled, afterwards.
    func resumeDelivery() -> TapResume
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
/// CI can never execute (`spec.md:19`). What is left here is the half worth testing: five entry
/// points, and what each of them does about the microphone.
///
/// ## The one rule the whole class is arranged around
///
/// **Every entry point ends any in-flight session, first, unconditionally.**
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
        isArmed = true

        switch source.start(delivering: sink) {
        case .started:
            note(.armed)
            return .delivering
        case .unavailable:
            note(.permissionMissing)
            return .permissionMissing
        }
    }

    /// The operating system disabled the tap, out of band.
    ///
    /// Acceptances **H3** and **H4**, in that order and for that reason.
    ///
    /// The session ends first and unconditionally, because the key-up that would have ended it is
    /// never coming: a disabled tap receives nothing at all, so every stop rule phrased in terms of a
    /// key event is now unreachable for this session.
    ///
    /// Then the cheap recovery is tried — the tap still exists, and switching it back on keeps its
    /// registration — and **only if that does not take** is the tap torn down and re-created. Both
    /// halves are needed: without the re-enable, every timeout would cost a new tap; without the
    /// re-creation, a tap that refuses to come back stays dead in silence.
    public func tapWasDisabled(_ reason: TapDisableReason) -> TapHealth {
        endAnyInFlightSession()
        note(.disabled(reason))
        guard isArmed else { return .notArmed }

        switch source.resumeDelivery() {
        case .resumed:
            note(.reenabled)
            return .delivering
        case .failed:
            return recreate(because: .reenableFailed)
        }
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
        source.stop()
        note(.disarmed)
    }

    // MARK: Doing it

    /// Tear the tap down and build a new one.
    ///
    /// The teardown is ``HotkeyEventSource/start(delivering:)``'s own obligation — that protocol
    /// documents a start on an already-started source as a `stop()` followed by a `start`, because a
    /// conformance that merely overwrote its state would leak a run-loop source and leave a second
    /// tap whose callback still points at the previous context. So this calls `start` once and does
    /// not call `stop` first: doing both would be this class second-guessing a contract the seam
    /// already makes, and the failure mode of getting *that* wrong is a use-after-free.
    private func recreate(because cause: TapRecreationCause) -> TapHealth {
        switch source.start(delivering: sink) {
        case .started:
            note(.recreated(cause))
            return .delivering
        case .unavailable:
            note(.recreationFailed(cause))
            return .permissionMissing
        }
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
