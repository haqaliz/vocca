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
/// domain here is a fact about how the object is *used*. What enforces it is
/// ``MainActor/assumeIsolated(_:file:line:)`` in the callback — the tap is attached to the main run
/// loop, so the callback arrives on the main thread, and an edit that attached it anywhere else
/// would trap there rather than race the session machine silently.
public final class CGEventTapSource: RecoverableHotkeyEventSource {

    /// Where a disablement is reported. **Weak, and the asymmetry is deliberate.**
    ///
    /// The shipped observer holds a ``TapHealthPolicy``, which holds this source — so a strong edge
    /// back would close a retain cycle around the one object whose deallocation frees a
    /// `CFMachPort`, and the leak would be a live tap nobody can reach. The owner therefore holds the
    /// observer; a `nil` here is an owner that did not, and it costs the recovery, not the ending —
    /// the ~1 s health poll still finds the dead tap.
    ///
    /// Settable rather than an initialiser parameter because the graph is circular by construction:
    /// the policy needs the source, and the observer needs the policy.
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

    // MARK: - HotkeyEventSource

    public func start(delivering sink: any HotkeyEventSink) -> HotkeyEventSourceStart {
        // A start on an already-started source is a stop followed by a start, which the protocol
        // documents as an obligation rather than a courtesy: overwriting the fields below would leak
        // a run-loop source and leave a second tap installed whose callback still points here.
        stop()

        // `tapCreate` returning nil **is** the permission check (inherited constraint 3). Reported,
        // never swallowed — what to *do* about it is `TapHealthPolicy.arm()`'s, and acceptance H5 is
        // that it reaches there at all rather than becoming a silent no-op.
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
        guard let tap else { return false }
        // Asked of the tap every time, never remembered. The whole value of the health poll is that
        // it is a question put to the system: the case it exists for is a tap that died and told
        // nobody, and a cached flag would answer with the last thing Vocca was told.
        return CGEvent.tapIsEnabled(tap: tap)
    }

    public func resumeDelivery() -> TapResume {
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
