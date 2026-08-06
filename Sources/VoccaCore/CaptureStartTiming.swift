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
/// `Scripts/measure-engine-start.sh`, on an **M4 Max running macOS 26.5.2**, against the built-in
/// input at 48 kHz mono, with the graph built once and only `start()`/`stop()` per press — the shape
/// `prd.md` M23 mandates — over **120 verified sessions** with a 1 s gap between them:
///
/// | | median | p90 | p99 | worst | best |
/// |---|---|---|---|---|---|
/// | `AVAudioEngine.start()` | **114.0 ms** | 116.5 | 119.1 | 126.8 | 100.5 |
/// | `AVAudioEngine.stop()` | 7.7 ms | 11.0 | 12.5 | 12.9 | 1.5 |
///
/// Two aspects were written on top of the estimate "milliseconds" — it is in this module's own doc
/// comments and in its test doubles. The real figure is **two orders of magnitude larger**, on the
/// fastest Mac Apple sells, and it is *tight*: the distribution is narrow, so this is not a tail
/// risk that a lucky machine escapes. It is what every press costs.
///
/// ## Why that settles it
///
/// A tap callback that blocks for 114 ms is indefensible on three separate grounds, and only the
/// first is the one the aspects were worried about:
///
/// 1. **`kCGEventTapDisabledByTimeout`.** The OS deadline is `prd.md` C1-G, still **[UNVERIFIED]** —
///    but a decision does not need the deadline's value when the candidate is 114 ms. The failure it
///    buys is the tap disabled *mid-session*, which is the hot mic `hotkey-source` spent four review
///    rounds bounding.
/// 2. **The window server holds the keystroke until the callback returns.** That is not a risk, it is
///    arithmetic: on the press that starts a session, every application on the machine waits 114 ms
///    for its key event. On the `.passThrough` paths it is the user's own typing, delivered late.
/// 3. **Everything else on the main run loop stops**, including the 150 ms watchdog poll and the ~1 s
///    tap-health poll — the two timers every "bounded" claim in this product rests on.
///
/// So: ``whenTheOwnerAsks`` is what ships. ``immediately`` remains, because it is the honest name for
/// what the machine did before this decision, and because a machine driven by a test that has no run
/// loop should not have to grow one.
///
/// ## What the hop does *not* buy, stated so nobody claims it later
///
/// **It does not make the microphone open any sooner.** Audio begins ~114 ms after the press either
/// way, and the first realtime callback arrives a further ~7.6 ms after `start()` returns (median,
/// same run). **The first ~122 ms of every utterance does not exist** — a user who begins speaking on
/// the press loses the first syllable. That is C7's problem and it is the number C7 should optimise
/// against, exactly as `prd.md:280` intended. What the hop buys is that the cost is paid somewhere
/// that only delays Vocca, instead of somewhere that stalls the keyboard and can kill the tap.
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
