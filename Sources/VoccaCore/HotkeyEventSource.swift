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

/// Whether the source began delivering events.
///
/// A two-case enum rather than `Void` or a `Bool`, for the same reason ``CaptureStart`` is one: it is
/// switched exhaustively and without a `default:`, so a third answer — "started, but Secure Input is
/// swallowing everything", say — is a compile error at the place that has to decide what it means,
/// rather than something that quietly inherits an existing branch.
///
/// **The failure is the ordinary case, not the exceptional one.** A keyboard tap needs an
/// Accessibility grant, `CGEvent.tapCreate` returning `nil` *is* the permission check
/// (`ARCHITECTURE.md` §13), and a first run has no grant. A `start` that could not report that would
/// leave the only honest signal Vocca gets about its own permissions with nowhere to go.
///
/// What to *do* about ``unavailable`` — surface it as "permission missing" rather than as silence, and
/// re-create the tap after a grant, because `CGEventTapEnable` cannot resurrect a mask that was
/// cleared at creation — is the tap-health policy's, and is deliberately not decided here. This type
/// is the vocabulary that policy is written in.
public enum HotkeyEventSourceStart: Sendable, Hashable, CaseIterable {
    /// Key events are being delivered to the sink from here until ``HotkeyEventSource/stop()``.
    case started

    /// Nothing is being delivered. The tap was not created, and the hotkey is deaf until something
    /// starts it again.
    case unavailable
}

/// Where a ``HotkeyEventSource`` delivers each observed key event, and what it gets back.
///
/// One method, returning one value, synchronously. Every part of that is forced by the thing on the
/// other side: a `CGEvent` tap callback is a C function that must return *this event's* disposition —
/// swallow or pass through — before it returns, because by the time an `await` resolved the event
/// would already have reached the focused application. So there is no `async` here, no throwing, and
/// nothing that can be answered later.
///
/// ## Class-bound, and it is not for tidiness
///
/// The same reason ``SessionAudioSource`` and ``PhysicalKeyStateReader`` are. A value-typed
/// conformance would be copied into the source, and every session it started would be started on the
/// copy — so "the microphone opened" would be unobservable from the object the caller still holds,
/// which is the one thing the seam exists to make observable. It is also what the tap adapter needs
/// in practice: the callback reaches its context through `Unmanaged.passUnretained`, which wants a
/// reference.
///
/// ## The sink sees the whole keyboard, and must
///
/// Not only the hotkey's events. Stop rule (c) is "any event whose modifiers no longer carry the
/// configured set", and the rules cannot apply it to events they never see — so a source that
/// filtered by key code before delivering, which looks like an obvious optimisation, deletes stop
/// rules (b) and (c) and leaves a session running to the ceiling every time the user releases Option
/// before Space.
///
/// The consequence is worth stating plainly, because it sets the stakes for every conformance:
/// **this method sees nearly every keystroke the user makes, all day, in every application.** A
/// conformance that returns a constant, or that decides propagation for itself rather than reporting
/// what the session decided, does not mishandle an edge case — it eats the user's entire keyboard for
/// as long as Vocca runs. That mutation survived an entire green suite once already, in
/// `session-lifecycle`, because the assertions covered the swallow direction only.
public protocol HotkeyEventSink: AnyObject {
    /// One observed keyboard event. Returns whether the focused application still sees it.
    ///
    /// Must not block: a slow return is what `kCGEventTapDisabledByTimeout` means, and the tap that
    /// earns one is disabled by the OS mid-session.
    func receive(_ event: RawKeyEvent) -> EventPropagation
}

/// **The boundary between the half of this capability CI can reach and the half it cannot.**
///
/// Below it: `CGEvent.tapCreate`, a `@convention(c)` callback, `CFMachPort`. That code cannot run in
/// a hosted test — `tapCreate` returns `nil` without an Accessibility grant, and there is no
/// programmatic route to TCC short of disabling SIP — so anything phrased in terms of those types is
/// untestable *forever* rather than untested for now. Above it: everything with a branch in it.
///
/// The seam is therefore drawn so that the untestable half has **no decisions left in it**. It
/// translates a `CGEvent` into a ``RawKeyEvent``, hands it to the sink, and turns the answer back
/// into a return value. If it grows an `if`, the `if` is in the wrong half.
///
/// ## Why this protocol lives in `VoccaCore`
///
/// Because `VoccaCore` imports nothing — not Foundation, not a system framework — and
/// `CoreBoundaryTests` fails the build if that ever stops being true. A seam declared here therefore
/// **cannot** be phrased in `CGEventFlags` or `CFMachPort`: there is no way to name them. That makes
/// the first half of acceptance H7 a property of the compiler rather than of a text lint, and leaves
/// the lint (`HotkeySeamBoundaryTests`) to police the one place the types are legitimately named —
/// the adapter's own file.
///
/// It is also what lets a second implementation exist without a rewrite. The Carbon
/// `RegisterEventHotKey` fallback (`prd.md` S1) needs no TCC grant, so it can give a working hotkey
/// during onboarding *before* Accessibility is granted; it cannot see `flagsChanged`, so it can never
/// be the primary. Two conformances of this protocol, chosen by the owner. Stated as the plan it is:
/// at C1 the tap is the only shipping conformance, and `prd.md` G5 records that deviation rather than
/// letting a reader assume otherwise.
public protocol HotkeyEventSource: AnyObject {
    /// Begin delivering key events to `sink`.
    ///
    /// The sink is held for as long as the source is delivering, and released by ``stop()``. That is
    /// a real obligation rather than a hint: the tap adapter's callback reaches its context through
    /// an unretained pointer, so a context that is not strongly held for the tap's lifetime is a
    /// use-after-free on the next keystroke.
    ///
    /// Not `@discardableResult`, and it must never become one: an ignored ``unavailable`` is a Vocca
    /// that is silently deaf, which is the failure this whole aspect is arranged to make impossible
    /// to reach by accident.
    func start(delivering sink: any HotkeyEventSink) -> HotkeyEventSourceStart

    /// Stop delivering, and release the sink.
    ///
    /// **Idempotent, and it does not end anything.** A source knows about keystrokes and nothing
    /// else; whether an in-flight session survives its tap being torn down is a policy question with
    /// a real answer — it must not, because a tap that died may have dropped the key-up — and that
    /// answer belongs to the owner, above this seam, where it can be tested.
    func stop()
}
