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

/// **Whether ``SessionMachine`` opens the microphone inside ``SessionMachine/observe(_:)-(RawKeyEvent)``
/// or leaves it for its owner to open afterwards.**
///
/// This is the resolution of the three-constraint tension that
/// ``HotkeyEventSink/receive(_:)`` has carried, unresolved, across two aspects. Read that doc
/// comment for the constraints; read this one for the number that decided it.
///
/// ## The measurement
///
/// `Scripts/measure-engine-start.sh`, on an **M4 Max running macOS 26.5.2**, with the graph built
/// once and only `start()`/`stop()` per press — the shape `prd.md` M23 mandates — and a 1 s gap
/// between sessions. **`AVAudioEngine.start()`, in milliseconds:**
///
/// | input device | n | median | p90 | p99 | worst |
/// |---|---|---|---|---|---|
/// | **analog headphone-jack input** (`BuiltInHeadphoneInputDevice`) — this machine's system default | 120 | **114.0** | 116.5 | 119.1 | 126.8 |
/// | **built-in microphone array** (`BuiltInMicrophoneDevice`) — the default on any Mac with an empty jack | 60 | **42.0** | 44.0 | 52.6 | 52.6 |
///
/// **Name the device or the number means nothing.** The two above differ by **2.7×** on one machine,
/// and the slower is the one this Mac boots with only because something is plugged into the jack.
/// The first version of this comment said "the built-in input", which reads as the second row and
/// quotes the first — so a future engineer re-taking it on a Mac with an empty jack would get 42 ms
/// and conclude the record was broken. `prd.md:280` asked for this measurement *specifically* so C7
/// would optimise against the right figure; C7 must therefore know which figure it has.
///
/// `stop()` is 7.7 ms median on the jack, 7.4 ms on the array. The first realtime callback arrives
/// **7.6 ms** after `start()` returns.
///
/// Two aspects were written on top of the estimate "milliseconds" — it is in this module's own doc
/// comments and in its test doubles. Both rows are **one to two orders of magnitude larger**, on the
/// fastest Mac Apple sells, and both distributions are *tight*: this is not a tail risk that a lucky
/// machine escapes. It is what every press costs.
///
/// ## Why that settles it
///
/// Three grounds. **The decision rests on the second and third; the first is a real risk that cannot
/// be quantified, and is not load-bearing.**
///
/// 1. **`kCGEventTapDisabledByTimeout` — a risk, not arithmetic.** The OS deadline is `prd.md` C1-G
///    and is still **[UNVERIFIED]**, so it cannot be shown that 114 ms exceeds it; the figure usually
///    quoted is on the order of a second, itself unverified. What can be said is the honest form:
///    *the budget is unknown, 114 ms is a large and unquantified fraction of any plausible value, and
///    what it buys on failure is the tap disabled **mid-session** — the hot mic `hotkey-source` spent
///    four review rounds bounding.* A risk not worth carrying. It is stated this way because C1-G is
///    still open and someone will eventually try to close it against this text.
/// 2. **The tap is a single serialization point in front of the whole keyboard.** `.defaultTap` is an
///    active filter (`CGEventTapSource.swift`), so nothing is delivered anywhere until the callback
///    returns. Note what this is *not*: the session-starting press is **swallowed**, so no
///    application is waiting for that particular event. The true cost is larger — for 114 ms after
///    every hotkey press, **whatever the user types next is held**, in whatever application they are
///    typing into. That is real input lag on every press, forever, and it needs no unknown constant.
/// 3. **Everything else on the main run loop stops.** The tap's run-loop source and both of this
///    package's timers are on `CFRunLoopGetMain()` in common modes, so a 114 ms callback overshoots
///    the 150 ms watchdog poll by 76% — and that poll is what bounds the hot-mic window in
///    hold-to-talk. Also unknown-constant-free.
///
/// So: ``whenTheOwnerAsks`` is what ships. ``immediately`` remains, because it is the honest name for
/// what the machine did before this decision, and because a machine driven by a test that has no run
/// loop should not have to grow one.
///
/// ## What the hop does *not* buy, stated so nobody claims it later
///
/// **It does not make the microphone open any sooner.** Audio begins ~114 ms after the press either
/// way, and the first realtime callback arrives a further ~7.6 ms after `start()` returns. **The
/// first ~122 ms of every utterance does not exist on the jack input, and ~51 ms on the built-in
/// array** — a user who begins speaking on the press loses the first syllable. That is C7's problem
/// and it is the number C7 should optimise against, exactly as `prd.md:280` intended, which is why
/// both rows are given. What the hop buys is that the cost is paid somewhere that only delays Vocca,
/// instead of somewhere that stalls the keyboard and can kill the tap.
public enum CaptureStartTiming: Sendable, Hashable, CaseIterable {
    /// Open the microphone inside the `observe` call that decided to.
    ///
    /// What ``SessionMachine`` did before the measurement above, kept because it is what a headless
    /// test wants: no run loop, no owner, one call and the session exists. Every acceptance test in
    /// `session-lifecycle` runs this way and still does, which is what makes the change below
    /// provably additive rather than a rewrite of a tested machine.
    ///
    /// **Not for shipping over a `CGEvent` tap.** See the type's own documentation.
    case immediately

    /// Decide now, open later: the machine records that a start is owed and returns
    /// ``SessionEffect/opening``, and the owner performs the open off the callback by calling
    /// ``SessionMachine/completePendingOpening()``.
    ///
    /// **The obligation this puts on the owner is real, and unmet it is a silently dead hotkey.** A
    /// machine left with a pending opening refuses every subsequent start — that is
    /// ``SessionMachine/isOpeningTheMicrophone``'s fail-closed rule, working exactly as designed —
    /// so an owner that never asks turns the hotkey off for the life of the process, with the
    /// machine `.idle`, the watchdog `.stopped`, and nothing anywhere looking again.
    ///
    /// It is discharged structurally rather than remembered: `ScheduledWatchdog` is the
    /// ``HotkeyEventSink``, so every route that can start a session already passes through it, and it
    /// schedules the pending opening on the spot. That is the same argument, and the same object,
    /// that already keeps the watchdog's timer in step with the session.
    case whenTheOwnerAsks
}
