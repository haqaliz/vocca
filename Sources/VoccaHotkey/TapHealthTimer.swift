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

/// **`TapHealthPolicy`, with its clock attached — and the only object an owner needs to hold.**
///
/// ``TapHealthPolicy/pollTapHealth()`` is documented as *"the only thing that catches a tap that is
/// disabled without anyone being told"*, and it is a method: it catches nothing until something calls
/// it once a second. This is that something, and it exists as a *wrapper* rather than as a timer
/// beside the policy for one reason — **so that arming Vocca and starting the poll cannot come apart.**
///
/// The failure that shape prevents is a real one and it is silent. An owner that armed the policy and
/// forgot the clock gets a Vocca that works perfectly: the hotkey fires, sessions start and end, every
/// test passes. What it does not have is the backstop for a tap that dies with no notification —
/// which in toggle mode is a two-minute hot mic bounded only by the ceiling, because
/// `SessionRules.swift:357-359` records that rule (d) is then the only stop a dead tap can still
/// deliver. Nothing observable distinguishes the two builds until a tap actually dies.
///
/// So the policy is private and the four entry points an owner legitimately drives are forwarded.
/// ``TapHealthPolicy/pollTapHealth()`` is deliberately **not** among them: it is what the clock does,
/// and an owner calling it by hand would be re-implementing this class badly.
///
/// ## What each forward is wired to, so that nothing here is a mystery to the caller
///
/// - ``arm()`` and ``disarm()`` are the owner's own lifecycle.
/// - ``systemDidWake()`` is `NSWorkspace.didWakeNotification` — taps die silently across sleep.
/// - ``accessibilityGrantChanged()`` is `com.apple.accessibility.api` on
///   `DistributedNotificationCenter`, and it is the route by which a first run recovers.
///
/// A disablement is **not** here, and that is not an omission: `kCGEventTapDisabledByTimeout` and
/// `…ByUserInput` arrive on the tap's own callback, so they reach the policy through
/// ``CallbackSafeTapDisablement`` — which splits the ending from the recovery across a run-loop turn
/// because the recovery ends in a teardown of the port whose callback is on the stack. Routing that
/// through here would put this object in the middle of a decision it has nothing to add to.
///
/// ## Isolation
///
/// Not `Sendable`, like everything else it touches. See ``TapHealthPolicy``.
public final class TapHealthTimer {

    /// Every decision about a dying tap. Held privately, so that the poll cannot be left unwired.
    private let policy: TapHealthPolicy

    /// The clock. `TapHealthPolling.interval` — one second — and see that constant for what the
    /// number costs and what it bounds.
    private let timer: any RepeatingTimer

    /// Where each poll's answer goes.
    ///
    /// Separate from `TapHealthPolicy`'s own note channel, and it is a different fact: a note says
    /// *what happened*, and this says *where the tap stands* — which is what a widget renders. It is
    /// called on **every** poll, including the ~sixty a minute that answer `.delivering`, because
    /// filtering here would be this class forming an opinion about which answers matter. An owner
    /// that only wants the changes compares against the last one it saw.
    private let reportHealth: (TapHealth) -> Void

    /// **Held for one reason: so that it is not deallocated.** Nothing here ever calls it.
    ///
    /// `CGEventTapSource.disablementObserver` is `weak`, and it has to be — the observer holds the
    /// policy, the policy holds the source, so a strong edge back would close a cycle around the one
    /// object whose deallocation frees a `CFMachPort`. That makes **the observer the root of the
    /// graph**, while the policy is the thing with the API and therefore the thing an owner reaches
    /// for. A composition root that held only the policy would deallocate the observer immediately
    /// and nothing anywhere would report it: the weak property goes `nil`, the callback's optional
    /// chain evaluates to nothing, and every keystroke still works. What is gone is both halves of a
    /// disablement — the ending as well as the recovery — leaving the ~1 s poll to close a
    /// microphone that should have closed at once.
    ///
    /// Phase 4's review carried that as an obligation on whoever wired the graph. Holding it here
    /// discharges it structurally instead, and it belongs here rather than anywhere else because
    /// this class already exists to be *the one object an owner needs to hold*. An owner that holds
    /// this holds the observer whether or not it has read this paragraph.
    ///
    /// Optional because the observer is genuinely optional: a `HotkeyEventSource` that is not a
    /// `CGEvent` tap — the Carbon fallback `spec.md:88` describes — has no out-of-band disablement to
    /// report and no observer to construct.
    private let disablementObserver: (any TapDisablementObserver)?

    /// - Parameters:
    ///   - policy: every decision about a dying tap.
    ///   - timer: the clock. See ``RepeatingTimer`` for the two obligations a conformance owes — and
    ///     note that this one carries the sharper half of the first: the poll reads
    ///     `CGEventTapSource.isDelivering`, which asserts main-actor isolation, once a second for as
    ///     long as Vocca runs. Off the main actor that is a 1 Hz crash in a release build.
    ///   - disablementObserver: the object the tap reports a disablement to, **held so that it stays
    ///     alive**. See the property. Pass it even though nothing here calls it; omit it only for a
    ///     source that has no disablement to report.
    ///   - reportHealth: where each poll's answer goes.
    public init(
        policy: TapHealthPolicy,
        timer: any RepeatingTimer,
        retaining disablementObserver: (any TapDisablementObserver)? = nil,
        reportHealth: @escaping (TapHealth) -> Void
    ) {
        self.policy = policy
        self.timer = timer
        self.disablementObserver = disablementObserver
        self.reportHealth = reportHealth
    }

    /// Stops the clock when the graph is torn down. See ``ScheduledWatchdog/deinit`` — same reason.
    deinit {
        timer.stop()
    }

    // MARK: - The owner's lifecycle

    /// Create the tap, and start asking after it.
    ///
    /// **The clock starts first, and unconditionally.** Not an ordering accident: the ordinary first
    /// run has no Accessibility grant, so `arm()` returns ``TapHealth/permissionMissing`` — and the
    /// poll is one of the two things that turns that into a working hotkey later (the other is
    /// ``accessibilityGrantChanged()``, whose notification `DistributedNotificationCenter` can drop).
    /// Starting the clock above the call is what makes it independent of the answer, rather than
    /// something a future `guard` could put a branch in front of.
    @discardableResult
    public func arm() -> TapHealth {
        startPolling()
        return policy.arm()
    }

    /// Stop delivering, deliberately, and stop asking.
    ///
    /// **The order of these two lines is not load-bearing, and the first version of this comment
    /// claimed it was.** It argued that stopping the clock last leaves a poll available as a backstop
    /// if `disarm()` ever stranded a session. That is false: the two statements are synchronous, so
    /// no timer fires between them either way, and once the clock is stopped there is no *next* poll
    /// in either ordering. Measured — swapping them passes the whole suite, and it is an equivalent
    /// mutant rather than an uncovered one.
    ///
    /// What actually makes a disarm safe is in `TapHealthPolicy.disarm()`: it closes its own
    /// microphone, including a session started *inside* the teardown, which is the hazard
    /// `endAnyStrandedSession()` exists for. That was got wrong once — the poll was relied on as the
    /// backstop for a stranded disarm, and it is not one, because an owner that has just disarmed has
    /// no reason to still be polling. Recording that here rather than inventing a second reason for
    /// an ordering that has none.
    public func disarm() {
        policy.disarm()
        timer.stop()
    }

    // MARK: - The two notifications the owner delivers

    /// `NSWorkspace.didWakeNotification`. Re-creates the tap: they die silently across sleep.
    @discardableResult
    public func systemDidWake() -> TapHealth {
        policy.systemDidWake()
    }

    /// `com.apple.accessibility.api`. Re-creates the tap, because a mask cleared at creation cannot
    /// be re-enabled.
    @discardableResult
    public func accessibilityGrantChanged() -> TapHealth {
        policy.accessibilityGrantChanged()
    }

    // MARK: - The clock

    /// Begin polling, replacing any poll already running.
    ///
    /// Separate from ``arm()`` only so that the one line has somewhere to be named. It is private
    /// because an owner that could start the clock without arming would have a poll asking after a
    /// tap nobody asked for — which answers `.notArmed` sixty times a minute and does nothing else.
    private func startPolling() {
        timer.start(every: TapHealthPolling.interval) { [weak self] in self?.poll() }
    }

    /// One turn of the clock.
    ///
    /// **The timer is not settled afterwards, and this is the one driver in the package that does not
    /// settle one.** Its cadence never changes: the poll runs at one second for as long as Vocca is
    /// armed, in every state, because the case it exists for is precisely the one where nothing else
    /// is happening. ``ScheduledWatchdog`` settles its timer because its schedule is derived from a
    /// session that starts and ends; this has no such schedule to derive.
    ///
    /// The *watchdog's* timer does still get settled when a poll ends a session, and by a route that
    /// does not pass through here: the policy ends a session by handing the sink a synthetic
    /// `.tapDisabled`, and the sink is a ``ScheduledWatchdog``, which reconsiders on every event it
    /// receives.
    private func poll() {
        reportHealth(policy.pollTapHealth())
    }
}
