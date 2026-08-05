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

import CoreFoundation
import CoreGraphics
import VoccaCore

/// **The real event tap. The one file in this package CI can never execute a line of.**
///
/// `CGEvent.tapCreate` returns `nil` without an Accessibility grant, and there is no programmatic
/// route to TCC short of disabling SIP — so a hosted runner cannot reach the first branch below, let
/// alone the callback. This file is therefore the one place in the aspect where a defect can hide
/// behind a green suite indefinitely, and it is written to that constraint: **it contains no
/// decisions.** It translates, forwards, and returns.
///
/// Everything with a branch worth testing was moved out and is tested:
///
/// | The question | Where it is answered |
/// |---|---|
/// | Which events do we ask for? | ``TapEventTranslation/eventsOfInterestMask`` |
/// | What does this event type mean? | ``TapEventTranslation/classify(rawEventType:)`` |
/// | Which modifiers is the user holding? | ``HotkeyFlagTranslation/modifiers(rawFlags:keyCode:)`` |
/// | Where does this event go, and what comes back? | ``TapEventDispatch`` |
/// | Start a session? Stop one? Swallow this key? | ``SessionMachine``, via the sink |
/// | What do we do about a dying tap? | ``TapHealthPolicy`` |
/// | *When* do we do it, given we are on the callback? | ``CallbackSafeTapDisablement`` |
///
/// What is left here is four system calls and a switch that turns an ``EventPropagation`` into a C
/// return value. If this file grows an `if` that decides something, the `if` is in the wrong half.
/// `HotkeySeamBoundaryTests` names this file as the only one in `Sources/` permitted to speak
/// CoreGraphics, and holds it to the stricter form of every other rule in that lint precisely because
/// a second permitted file is how the untestable half grows without anyone deciding that it should.
///
/// ## The three tap parameters, and why each is the only option
///
/// Inherited constraint 1, restated where the call is: `.cgSessionEventTap` because a HID-level tap
/// is root-only (`CGEvent.h:269-271`); `.headInsertEventTap` so Vocca sees the keystroke before the
/// applications that would otherwise consume it; `.defaultTap` because only an *active* tap may
/// swallow, and swallowing is not optional — an unswallowed `⌥Space` types U+00A0 NO-BREAK SPACE into
/// the field the user is dictating into.
///
/// ## Lifetime, and the pointer that makes it load-bearing
///
/// **This object is the callback's context, passed unretained, so it must be held strongly for as
/// long as the tap exists.** An owner that creates a source, calls ``start(delivering:)`` and lets it
/// go out of scope has a run-loop source calling a C function whose context pointer refers to freed
/// memory — on the user's next keystroke, in every application. That is why there is no convenience
/// initialiser that arms itself, and why ``TapHealthPolicy`` — which is the intended owner — holds
/// its source for its own lifetime.
///
/// `self` is the context rather than the sink alone, which is a deliberate deviation from the idiom
/// ``HotkeyEventSource/start(delivering:)`` spells out. The callback needs the sink, the clock and
/// the disablement observer, and this object holds all three; threading them through separately
/// would mean a second unretained pointer to keep alive, and a force-cast back out of `AnyObject`
/// that this way does not exist.
///
/// ## Isolation
///
/// Not `Sendable`, like everything else it touches, and not annotated `@MainActor` for the same
/// reason ``TapHealthPolicy`` is not: the seam it implements is a plain protocol, and one isolation
/// domain here is a fact about how the object is *used*.
///
/// **It is asserted at all five entrances, and it took a review to notice that four of them had no
/// assertion at all.** `MainActor.assumeIsolated` in the callback proves the callback is on the main
/// actor and nothing else; ``start(delivering:)``, ``stop()``, ``isDelivering`` and
/// ``resumeDelivery()`` read and write the same three fields, so an owner arming from a background
/// thread would race the callback with the file's one runtime check positioned to pass while it
/// happened. Each now opens with `MainActor.preconditionIsolated` — see ``mustBeOnTheMainActor``.
/// ``deinit`` is the one exception, and deliberately: it runs wherever the last release happens,
/// which is not this object's choice.
public final class CGEventTapSource: RecoverableHotkeyEventSource {

    /// Where a disablement is reported. **Weak, and the asymmetry is deliberate.**
    ///
    /// The shipped observer holds a ``TapHealthPolicy``, which holds this source — so a strong edge
    /// back would close a retain cycle around the one object whose deallocation frees a
    /// `CFMachPort`, and the leak would be a live tap nobody can reach.
    ///
    /// Settable rather than an initialiser parameter because the graph is circular by construction:
    /// the policy needs the source, and the observer needs the policy.
    ///
    /// ## **The composition root must hold the observer, and it is the least obvious object to hold**
    ///
    /// The graph is `observer ─strong→ policy ─strong→ source ─weak→ observer`, so **the observer is
    /// the root of it** — while the policy is the thing with the API, and therefore the thing an owner
    /// instinctively reaches for. A root that holds only the policy deallocates the observer
    /// immediately, and nothing anywhere reports that: this property goes `nil`, the callback's
    /// optional chain evaluates to nothing, and every keystroke still works.
    ///
    /// **What a `nil` costs is both halves of a disablement, not only the recovery**, which is the
    /// correction a review made to the sentence that used to be here. The near half —
    /// ``TapHealthPolicy/endAnyInFlightSessionWithoutRecovering()`` — is reached through this same
    /// optional, so the *ending* does not happen either. It is not lost: `pollTapHealth()` ends any
    /// in-flight session on the very next turn, so the residual is bounded by
    /// ``TapHealthPolicy/pollTapHealth()``'s ~1 s cadence rather than by nothing. But it is up to a
    /// second of open microphone instead of none, and "it costs the recovery, not the ending" would
    /// have made leaving this un-wired look reasonable.
    ///
    /// Nothing in CI can see the difference, because nothing in CI can create a tap. The gesture that
    /// can is in the report and belongs in `SMOKE_CHECKLIST.md`: provoke a `.timeout` and **time the
    /// microphone indicator going out.** Immediate is wired; about a second is the poll saving it.
    public weak var disablementObserver: (any TapDisablementObserver)?

    /// The only way time enters this file. Used for ``RawKeyEvent/timestamp``, and for nothing else.
    ///
    /// **The event's own timestamp is not used, and that is a choice.** `CGEvent` carries one, in
    /// mach absolute-time units, which would need a `mach_timebase_info` conversion to become the
    /// `Duration` the core speaks — arithmetic, in the file that is allowed no arithmetic worth
    /// testing. What the clock costs instead is the delay between the event being posted and this
    /// callback reading it, which is microseconds against a 150 ms poll and a 120 s ceiling. Reading
    /// the injected clock also keeps every timestamp in the system minted the same way: it is the
    /// same clock ``TapHealthPolicy`` stamps its synthetic end with.
    private let clock: any MonotonicClock

    /// Where key events go, held for exactly as long as the tap exists.
    ///
    /// `nil` is "there is no tap", which is the state a stopped or never-started source is in.
    private var sink: (any HotkeyEventSink)?

    /// The tap itself. `nil` when there is none — which is the honest answer to every question
    /// ``RecoverableHotkeyEventSource`` asks, and the reason both of its members check it.
    private var tap: CFMachPort?

    /// The tap's attachment to the run loop. Held so that ``stop()`` can remove exactly the source it
    /// added; re-deriving it from the port at teardown yields a *different* object that the run loop
    /// has never heard of, and the removal silently does nothing.
    private var runLoopSource: CFRunLoopSource?

    /// - Parameter clock: the clock every ``RawKeyEvent`` this source mints is stamped with.
    public init(clock: any MonotonicClock) {
        self.clock = clock
    }

    /// The message on the four preconditions below.
    ///
    /// **The seam's four members assert their isolation, and the callback is not enough on its own.**
    /// `MainActor.assumeIsolated` in the tap callback proves one direction — that the *callback* is on
    /// the main actor — and proves nothing about the other four entry points, which read and write
    /// ``tap``, ``runLoopSource`` and ``sink`` with no check at all. An owner that armed from a
    /// background thread would race the callback, and the one runtime check in the file is positioned
    /// to pass happily while it happened.
    ///
    /// `preconditionIsolated()` rather than `assumeIsolated { … }`, which is what this wanted to be:
    /// wrapping a body in the latter captures `self` — non-`Sendable`, from a nonisolated method —
    /// into a main-actor closure, and Swift 6 rejects it as a `sending` diagnostic. The precondition
    /// takes no closure, captures nothing, and is exactly the assertion rather than an isolation
    /// change. ``deinit`` deliberately makes no such assertion; see ``tearDown()``'s caller.
    private let mustBeOnTheMainActor = """
        A CGEventTapSource was used off the main actor. The tap is attached to the main run loop, so \
        its callback arrives there, and every other object it touches — the sink, the watchdog, the \
        session machine — is deliberately non-Sendable and lives in that one domain.
        """

    // MARK: - HotkeyEventSource

    public func start(delivering sink: any HotkeyEventSink) -> HotkeyEventSourceStart {
        MainActor.preconditionIsolated(mustBeOnTheMainActor)

        // A start on an already-started source is a stop followed by a start, which the protocol
        // documents as an obligation rather than a courtesy: overwriting the fields below would leak
        // a run-loop source and leave a second tap installed whose callback still points here.
        stop()

        // `tapCreate` returning nil **is** the permission check (inherited constraint 3). Reported,
        // never swallowed — what to *do* about it is `TapHealthPolicy.arm()`'s, and acceptance H5 is
        // that it reaches there at all rather than becoming a silent no-op.
        //
        // **It is the permission check only because the mask is keyboard types and nothing else.**
        // `CGEvent.h:274-280`: without the grant the keyboard bits are cleared at creation, and NULL
        // is returned only if that empties the mask. One non-keyboard bit in
        // `eventsOfInterestMask` and this guard silently stops being H5 — see its doc comment.
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(TapEventTranslation.eventsOfInterestMask),
                callback: voccaHotkeyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return .unavailable }

        // A port with no run-loop source delivers nothing, so it is not a tap — and it is invalidated
        // rather than dropped, because it holds this object's address as its callback context. The
        // two failures are reported identically because they are the same fact to every caller:
        // nothing is attached. That is the direction `start`'s documentation calls safe — deaf rather
        // than double-tapped.
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return .unavailable
        }

        self.tap = tap
        self.runLoopSource = runLoopSource
        self.sink = sink

        // `.commonModes` and not `.defaultMode`: a source in the default mode alone stops being
        // serviced while a menu is tracking or a window is being dragged, which is `spec.md`'s H10
        // hazard and would make the hotkey deaf during exactly the gestures a user makes while
        // dictating. It is free here and is measured, on real hardware, in phase 5.
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Not read back, and that is the seam's division rather than an omission. `start` answers
        // "was a tap created", which is the permission question; "is it delivering" is a different
        // question with an owner — `isDelivering`, asked once a second by the health poll, which
        // exists for a tap that is present and mute.
        return .started
    }

    public func stop() {
        MainActor.preconditionIsolated(mustBeOnTheMainActor)
        tearDown()
    }

    /// **The last line of defence for the unretained context pointer.**
    ///
    /// `CGEvent.h:282` — *"Releasing the `CFMachPortRef` will release the tap"* — is the whole
    /// problem in one sentence read backwards: the run loop holds the source, the source holds the
    /// port, and **nothing holds this object**, because its address went in through
    /// `Unmanaged.passUnretained`. So an owner that drops the source without calling ``stop()``
    /// leaves a live tap whose callback dereferences freed memory on every keystroke, in every
    /// application, for as long as the process runs. That failure has no upper bound, and until this
    /// existed the only thing standing against it was a paragraph of documentation.
    ///
    /// **Not a substitute for ``stop()``** — the owner still owes that, and a teardown that happens
    /// whenever ARC gets round to it is not a teardown anybody can reason about. It is the net under
    /// the case where the owner did not.
    ///
    /// It calls ``tearDown()`` rather than ``stop()`` and therefore skips the main-actor assertion the
    /// other four members make. That is deliberate: a `deinit` runs wherever the last release
    /// happens, which is not this object's choice, and trapping there would turn "an owner released
    /// me on the wrong thread" into a crash at exit. **The thread question is a clean no**: the two
    /// calls are thread-safe, and both name `CFRunLoopGetMain()` absolutely rather than
    /// `CFRunLoopGetCurrent()`, so the add and the remove are symmetric whichever thread each runs on.
    ///
    /// ## What this is *not* safe from, and the rule an owner has to keep
    ///
    /// **A `deinit` is not a race. It is re-entrancy, and this one can land inside the tap's own
    /// callback.** The callback recovers its context with `takeUnretainedValue()`, which is `+1` — so
    /// for the duration of ``receive(rawEventType:rawFlags:keyCode:isAutorepeat:)`` the callback's own
    /// frame is a strong owner of this object. If anything reached from inside that call drops the
    /// last *other* strong reference, the callback's release is the final one, `deinit` runs on the
    /// callback's stack, and ``tearDown()`` invalidates the `CFMachPort` whose callback is executing.
    /// That is precisely the hazard ``CallbackSafeTapDisablement`` exists to keep off this stack,
    /// arrived at by a different road — and the deferral does not cover it, because the deferral
    /// guards the *deliberate* teardown and this one is ARC's.
    ///
    /// So the rule, and it belongs to the owner rather than to this class: **nothing reachable from
    /// the sink may release the source.** Today nothing is — the sink path bottoms out in the session
    /// machine, which has never heard of a `HotkeyEventSource` — and the composition root that wires
    /// these together (phase 5) is where that could stop being true. A `disarm()` that also dropped
    /// the policy, driven by a widget action delivered on a keystroke, is the shape to watch for.
    deinit {
        tearDown()
    }

    /// The teardown itself, with no isolation assertion on it, so that ``deinit`` can reach it.
    private func tearDown() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            // Invalidation is what guarantees no further callback: it detaches the port from every
            // run loop and disables it. Ordering matters only in that both must happen before the
            // context this callback reads — `self` — can be released by the owner.
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
        sink = nil
    }

    // MARK: - RecoverableHotkeyEventSource

    public var isDelivering: Bool {
        MainActor.preconditionIsolated(mustBeOnTheMainActor)
        guard let tap else { return false }
        // Asked of the tap every time, never remembered. The whole value of the health poll is that
        // it is a question put to the system: the case it exists for is a tap that died and told
        // nobody, and a cached flag would answer with the last thing Vocca was told.
        return CGEvent.tapIsEnabled(tap: tap)
    }

    public func resumeDelivery() -> TapResume {
        MainActor.preconditionIsolated(mustBeOnTheMainActor)

        // No tap is `.failed`, decided at the protocol rather than here.
        guard let tap else { return .failed }

        // `CGEventTapEnable` returns Void — it cannot fail loudly — so the answer comes from asking
        // the tap afterwards, which is the read-back the protocol requires. Reporting `.resumed`
        // from having made the call would report a dead tap as healthy and the re-creation
        // acceptance H4 requires would never happen.
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap) ? .resumed : .failed
    }

    // MARK: - The callback's other half

    /// One event, already reduced to integers, on the main actor.
    ///
    /// The state this object holds — the sink, the clock, the observer — handed to the function that
    /// does the work. ``TapEventDispatch/dispatch(rawEventType:rawFlags:keyCode:isAutorepeat:at:to:reportingDisablementTo:)``
    /// is above the seam and takes every collaborator as a parameter, which is what lets the `fn`
    /// rule, the disablement route and **both directions of the disposition** be measured. Left here
    /// as a `switch`, they would be branches no CI run can take.
    fileprivate func receive(
        rawEventType: UInt32, rawFlags: UInt64, keyCode: UInt16, isAutorepeat: Bool
    ) -> EventPropagation {
        TapEventDispatch.dispatch(
            rawEventType: rawEventType,
            rawFlags: rawFlags,
            keyCode: keyCode,
            isAutorepeat: isAutorepeat,
            at: clock.now,
            to: sink,
            reportingDisablementTo: disablementObserver)
    }

    // MARK: - The deferral the disablement split needs

    /// Runs `work` on a later turn of the main run loop.
    ///
    /// The shipped ``RunLoopDeferral``, and it lives here rather than beside the type that uses it
    /// for one reason: `CFRunLoopPerformBlock` is a seam identifier, and this is the only file
    /// permitted to name one. It is four lines with no decision in them, which is the price of that
    /// rule and a cheap one.
    ///
    /// `CFRunLoopPerformBlock` enqueues rather than calls, so a block scheduled from inside a tap
    /// callback runs after that callback has returned and the port it belongs to is safe to
    /// invalidate — which is the entire point. The wake-up is needed because the run loop may be
    /// asleep by the time the block is enqueued, and a recovery that waits for the user's next
    /// keystroke is a recovery that never happens: the tap is disabled, so there is no next
    /// keystroke.
    /// A function rather than a stored closure, because a `static let` of function type is global
    /// mutable state as far as Swift 6 is concerned and will not compile without an actor
    /// annotation this file has no use for. Referenced as
    /// `CGEventTapSource.deferToALaterMainRunLoopTurn`, which is a ``RunLoopDeferral``.
    public static func deferToALaterMainRunLoopTurn(_ work: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

/// The tap's callback: a non-capturing C function, as `CGEvent.tapCreate` requires.
///
/// Every line is a translation:
///
/// 1. Recover the context. Unretained, so the source must outlive the tap — see the type's
///    documentation for what it costs when it does not.
/// 2. `MainActor.assumeIsolated`, which is inherited constraint 5 made enforceable. The tap is
///    attached to the main run loop so this callback arrives on the main thread; if an edit ever
///    attaches it elsewhere, this traps rather than racing the session machine in silence.
/// 3. Read four values off the event. This is the only place a `CGEvent` is ever read, and nothing
///    below the seam sees one.
/// 4. Turn the answer into the C return value: `nil` swallows, the event passes through. Driven
///    entirely by what the machine said — inverting these two arms, or hard-coding either, is the
///    mutation that eats the user's whole keyboard for as long as Vocca runs, and it is the one
///    mutation in this aspect no test can catch, which is why the answer is computed elsewhere and
///    only spelled here.
private func voccaHotkeyTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // No context is a tap this package did not install, or one whose owner is gone. Either way the
    // event is not ours and reaches the application untouched.
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    // `nonisolated(unsafe)` because an `UnsafeMutableRawPointer` is not `Sendable` — nothing that
    // can be dereferenced is — so the compiler cannot know that this one is a context installed by
    // `tapCreate` and read only on the thread the tap is attached to. It is the narrowest possible
    // form of the assertion that `MainActor.assumeIsolated` below makes checkable at run time.
    nonisolated(unsafe) let context = userInfo

    // Read out here, and the pointer round-trip performed *inside* the closure, because both the
    // event and the source are non-`Sendable` class types and capturing either in a main-actor
    // closure from this nonisolated C function is a `sending` diagnostic under Swift 6. What crosses
    // is four POD values and a raw pointer, which is the same boundary `RawKeyEvent` draws one layer
    // up — so the compiler is asking for exactly the shape the seam already wanted.
    let rawEventType = type.rawValue
    let rawFlags = event.flags.rawValue
    // Truncating rather than trapping: macOS virtual key codes occupy the low byte, so a value that
    // did not fit would be a field this code has misread — and a keystroke is not a thing to crash a
    // user's session over. A truncated code matches no configured hotkey, which is the same outcome
    // as any other key Vocca has no interest in.
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    let propagation = MainActor.assumeIsolated {
        Unmanaged<CGEventTapSource>.fromOpaque(context).takeUnretainedValue()
            .receive(
                rawEventType: rawEventType, rawFlags: rawFlags, keyCode: keyCode,
                isAutorepeat: isAutorepeat)
    }

    switch propagation {
    case .swallow: return nil
    case .passThrough: return Unmanaged.passUnretained(event)
    }
}
