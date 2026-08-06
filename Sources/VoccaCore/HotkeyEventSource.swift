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
/// rules (b) and (c) outright.
///
/// **What that costs is worth stating exactly, because the obvious summary of it is wrong and was
/// written here first.** It is not "a session running to the ceiling every time the user releases
/// Option before Space": stop rule (a) is `.keyUp` on the configured key code, and `SessionRules`
/// reaches it via `matchesKey` **without consulting modifiers at all**, so a key-code filter that
/// still passes the hotkey's own events ends the session at key-up as usual. What is lost is every
/// end that does *not* come from the hotkey's key — the chord broken while the key is still held, and
/// any future modifier-only binding — and, on a filter strict enough to drop `flagsChanged` for the
/// bound key too, the *immediacy* of rules (b) and (c): the session then ends at the next autorepeat
/// or at key-up rather than the instant the chord breaks.
///
/// The correction matters more than the sentence it replaces. A justification that overstates its
/// case is discounted the first time someone checks it, and this one is guarding the seam's single
/// most damaging conformance mistake — see the paragraph below.
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
    /// earns one is disabled by the OS **mid-session** — which is the hot-mic case, arrived at by
    /// the one route the session machine cannot see coming.
    ///
    /// ## The capture start does not happen here — decided, on a measurement
    ///
    /// **Three constraints, not two, and the third is what made this hard:**
    ///
    /// 1. The callback must return fast, or the OS disables the tap mid-session.
    /// 2. `AVAudioEngine.start()` is slow.
    /// 3. **The engine cannot be pre-warmed to make (2) go away.** `AVAudioEngine.h:465-466`: *"if
    ///    the engine has at any point previously had its inputNode enabled and permission to record
    ///    was granted, then any time the engine is running, the mic-in-use indicator will appear."*
    ///    A warm engine therefore lights macOS's orange microphone dot **permanently, whether or not
    ///    Vocca is recording** — which `ARCHITECTURE.md` §6 and `prd.md` M23 both call the single
    ///    most damaging signal this product could emit. Pre-warming does not remove the problem; it
    ///    trades a tap timeout for a lit mic indicator.
    ///
    /// Two aspects left this open because (2) had never been measured, and both wrote down the
    /// estimate they were working from: *"milliseconds"*. `prd.md:280` had required the number since
    /// C1 was planned. `audio-capture` took it, with `Scripts/measure-engine-start.sh`:
    ///
    /// > **`AVAudioEngine.start()` — median 114.0 ms, p99 119.1 ms, worst 126.8 ms** on the **analog
    /// > headphone-jack input** (`BuiltInHeadphoneInputDevice`), this machine's system default;
    /// > **median 42.0 ms, p99 52.6 ms** on the **built-in microphone array**
    /// > (`BuiltInMicrophoneDevice`), which is the default on any Mac with an empty jack. 120 and 60
    /// > sessions respectively, every one verified to have actually started and actually delivered
    /// > audio. M4 Max, macOS 26.5.2, 48 kHz mono.
    ///
    /// Not milliseconds — 42 ms at best and an eighth of a second at worst, on the fastest Mac Apple
    /// sells, with *narrow* distributions rather than fat tails. Both rows are given because the
    /// device is 2.7× of the answer; see ``CaptureStartTiming`` for why quoting one without naming it
    /// is how the figure C7 optimises against goes wrong. So the shape both aspects had sketched as a
    /// candidate is now what ships: **this method decides and returns; the capture start happens off
    /// the callback.**
    ///
    /// It is ``CaptureStartTiming/whenTheOwnerAsks``, and the machinery it rests on was built and
    /// tested in `session-lifecycle` precisely for a slow open — `SessionMachine`'s
    /// `isOpeningTheMicrophone` and its deferred-stop path, which refuse a second start and hold a
    /// stop until there is a session to apply it to. What the hop added is a wider window, not a new
    /// rule: at 114 ms a held hotkey autorepeats one to four times *inside* every opening, so the
    /// path those two mechanisms guard went from rare to universal. `ScheduledWatchdog` owns the
    /// hop, because it is already the sink every session-starting route passes through.
    ///
    /// **What this does not buy, stated so nobody claims it later.** The microphone does not open
    /// any sooner — ~114 ms either way, plus ~7.6 ms before the first realtime callback — so the
    /// opening syllable of an utterance begun on the press is not captured at all. That is C7's
    /// number to improve and `prd.md:280` says so. What the hop buys is that the cost falls on
    /// Vocca's own run loop instead of on the user's keyboard and the tap's life.
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
    /// **The idiom, spelled out, because the obvious form does not compile.** `sink` is a class-bound
    /// *existential*, and `Unmanaged`'s `Instance` requires an actual class type, so
    /// `Unmanaged.passUnretained(sink)` fails with *"generic struct 'Unmanaged' requires that 'any
    /// HotkeyEventSink' be a class type"*. One token fixes it, and the round trip is the identical
    /// object — verified under `-swift-version 6`, both directions:
    ///
    /// ```swift
    /// let context = Unmanaged.passUnretained(sink as AnyObject).toOpaque()   // into the tap
    /// let sink = Unmanaged<AnyObject>.fromOpaque(context)                    // and back, in the
    ///     .takeUnretainedValue() as! any HotkeyEventSink                     //   C callback
    /// ```
    ///
    /// **A `start` on an already-started source is a `stop()` followed by a `start`, and the
    /// conformance must make it so.** This is not a tidiness rule: the tap-health policy's charter is
    /// "if re-enable fails, tear down and re-create", and re-creating *is* calling this method again.
    /// A conformance that merely overwrote its state there would leak a `CFMachPort` and a run-loop
    /// source, and leave a **second tap installed whose callback still points at the previous
    /// context** — the use-after-free the paragraph above warns about, reached by a caller who did
    /// everything this protocol documents. A re-create that then fails leaves nothing attached, which
    /// is the safe direction: deaf rather than double-tapped.
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
