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

/// The one named table of the idle re-warm aspect's provisional target
/// (`rewarm-after-idle/plan_20260831.md` phase (a); the ``WarmStartTargets`` single-source
/// precedent).
///
/// The duration is **provisional by design** (PRD Q5 — the reload cost is unmeasured): it is
/// re-baselined from the founder's real run (`SMOKE_CHECKLIST.md` steps 120/121), recorded not
/// gated. It lives in exactly this file — the single-source scan in ``IdleReWarmPolicyTests``
/// pins the literal to this file and its pinning test — and a re-baseline from the founder's
/// observation lands here, in exactly one place.
public enum IdleReWarmTargets {
    /// The machine-idle threshold after which the engine re-warms. Inclusive: exactly this much
    /// idle is enough.
    public static let idleDuration: Duration = .seconds(300)
}

/// The idle re-warm decision: after five machine-idle minutes the engine is re-warmed once, and
/// a session start cancels and reschedules the window.
///
/// The ``SessionMachine`` shape: a synchronous class in the main-actor domain, **not** an actor
/// and not `@MainActor`-annotated — the annotation belongs to the owner that drives it (the
/// composition root's per-second housekeeping turn), never to the policy itself, and the
/// `CoreBoundaryTests` mutable-global-state lint forbids the annotation in this module outright.
/// That ban is also why `tick()` is synchronous: an async method on a non-Sendable class would
/// need main-actor isolation to be callable from the root, so the tick decides and the fire is
/// dispatched by the policy as an unstructured task over the injected trigger. The trigger is
/// non-throwing (it is `@Sendable` only so the dispatch task may capture it) — the wiring catches
/// and logs the resolver's error, because a failed re-warm must never take the policy down.
/// The clock is injected (``MonotonicClock``, monotonic only, never a wall clock).
///
/// The window is effect-driven: it opens at construction (launch-idle counts, so a failed launch
/// prepare gains a bounded five-minute auto-retry through the resolver), closes on a session
/// start, and reopens on a session end. One fire per window, marked **before** the trigger runs —
/// a second tick during the fire cannot double it.
public final class IdleReWarmPolicy {

    private let clock: any MonotonicClock
    private let trigger: @Sendable () async -> Void
    /// `nil` while a session is active — the window is closed.
    private var windowOpenedAt: Duration?
    private var triggeredThisWindow = false

    public init(clock: any MonotonicClock, trigger: @escaping @Sendable () async -> Void) {
        self.clock = clock
        self.trigger = trigger
        self.windowOpenedAt = clock.now
    }

    /// Closes the window. A session start during a window cancels it — the accumulated idle no
    /// longer counts, and the next ``noteSessionEnded()`` opens a fresh window.
    public func noteSessionStarted() {
        windowOpenedAt = nil
        triggeredThisWindow = false
    }

    /// Opens a fresh window at `clock.now`. A window that already fired is spent, so the fresh
    /// one must be fireable — the reset is the one-fire-per-window rule applied per window.
    public func noteSessionEnded() {
        windowOpenedAt = clock.now
        triggeredThisWindow = false
    }

    /// The one decision point, called on the owner's per-second housekeeping turn.
    ///
    /// - Returns: `true` when this tick fired the re-warm trigger — the caller must consume the
    ///   answer (no `@discardableResult` in this module by the `CoreBoundaryTests` rule).
    public func tick() -> Bool {
        guard let windowOpenedAt else { return false }
        guard !triggeredThisWindow else { return false }
        guard clock.now - windowOpenedAt >= IdleReWarmTargets.idleDuration else { return false }
        triggeredThisWindow = true
        let fire = trigger
        Task { await fire() }
        return true
    }
}