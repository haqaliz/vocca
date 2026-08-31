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
import XCTest

/// The `rewarm-after-idle` phase (a) decision table: after five machine-idle minutes the engine
/// re-warms once, a session start during the window cancels and reschedules it, and a fire is
/// marked **before** the trigger runs so a second tick during the fire cannot double it.
///
/// The class is `@MainActor` because the policy is confined to the main actor by its owner —
/// the composition root's per-second housekeeping turn — and the annotation belongs to whoever
/// drives it, never to the policy itself (the ``EngineReadinessTests`` reasoning). The
/// ``SessionMachine`` shape: a synchronous class, not an actor.
///
/// The clock is a hand-moved ``TestClock``; the trigger is a counting ledger, so "exactly once"
/// is a count, not an assumption. The decision tests never write the five-minute target as a
/// literal — they advance the clock by ``IdleReWarmTargets/idleDuration``'s name, so the
/// single-source scan below is the only place the literal is allowed to live.
@MainActor
final class IdleReWarmPolicyTests: XCTestCase {

    private func waitUntil(_ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition did not hold within 2 seconds")
    }

    // MARK: - The target

    /// The five-minute target itself, pinned. The value is **provisional** (PRD Q5 — the reload
    /// cost is unmeasured): the founder re-baselines it from the real run (`SMOKE_CHECKLIST.md`
    /// steps 120/121), in exactly this one file, recorded not gated.
    func testIdleDurationIsFiveMinutes() {
        let expected: Duration = .seconds(300)
        XCTAssertEqual(IdleReWarmTargets.idleDuration, expected)
    }

    // MARK: - Single-source scan

    /// The `.seconds(300)` literal appears in exactly the named policy and this pinning test —
    /// nowhere else in `Sources/` or `Tests/` — so the five-minute target cannot drift into a
    /// second home. The scan matches the literal's **assigned** form (`= .seconds(300)`), because
    /// `WidgetStateReducerTests` folds `.seconds(300)` clock values that are unrelated widget
    /// inputs, not this target. The scan strips comments first (a doc comment naming the literal
    /// is not a hard-coded target) — the ``WarmStartRatioTests`` shape — and the vacuity guard
    /// runs in both directions.
    func testTheFiveMinuteLiteralAppearsNowhereOutsideTheNamedFiles() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let namedPolicy = "IdleReWarmPolicy.swift"
        let pinningTest = "IdleReWarmPolicyTests.swift"
        let allowedSightings: Set<String> = [namedPolicy, pinningTest]
        let pattern = #"= \.seconds\(300\)"#

        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let content = try String(contentsOf: file, encoding: .utf8)
                let stripped = SwiftSourceScanner.stripComments(from: content)
                if stripped.range(of: pattern, options: .regularExpression) != nil {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), allowedSightings,
            "the five-minute target must live in exactly the named policy and its pinning test, got: \(sightings)")
        XCTAssertEqual(
            sightings[namedPolicy], 1,
            "the named policy's own sighting must exist — the vacuity guard's second direction")
    }

    // MARK: - The decision table

    /// Idle under five minutes is not idle long enough: the tick answers no and nothing fires.
    func testIdleUnderFiveMinutesDoesNotFire() async {
        let clock = TestClock()
        let ledger = TriggerLedger()
        let policy = IdleReWarmPolicy(clock: clock, trigger: { await ledger.fire() })

        clock.now += IdleReWarmTargets.idleDuration - .seconds(1)

        let fired = policy.tick()
        XCTAssertFalse(fired)
        let fires = await ledger.fires
        XCTAssertEqual(fires, 0)
    }

    /// Idle at least five minutes fires **exactly once** — a second tick in the same window is
    /// spent.
    func testFiveMinutesIdleFiresExactlyOnce() async {
        let clock = TestClock()
        let ledger = TriggerLedger()
        let policy = IdleReWarmPolicy(clock: clock, trigger: { await ledger.fire() })

        clock.now += IdleReWarmTargets.idleDuration

        let fired = policy.tick()
        XCTAssertTrue(fired)
        await waitUntil { await ledger.fires == 1 }
        let again = policy.tick()
        XCTAssertFalse(again, "one fire per window — a second tick must not double it")
        let fires = await ledger.fires
        XCTAssertEqual(fires, 1)
    }

    /// A session start during the window cancels it: the window closes and the accumulated idle
    /// no longer counts — a tick well past the threshold answers no.
    func testASessionStartDuringTheWindowCancelsIt() async {
        let clock = TestClock()
        let ledger = TriggerLedger()
        let policy = IdleReWarmPolicy(clock: clock, trigger: { await ledger.fire() })

        clock.now += IdleReWarmTargets.idleDuration * 3 / 5
        policy.noteSessionStarted()
        clock.now += IdleReWarmTargets.idleDuration * 3 / 5

        let fired = policy.tick()
        XCTAssertFalse(fired, "a session start cancels the window — the pre-session idle must not count")
        let fires = await ledger.fires
        XCTAssertEqual(fires, 0)
    }

    /// A session end opens a fresh window at that moment: five idle minutes measured from the
    /// end fire once, and a second tick is spent.
    func testASessionEndReschedulesTheWindow() async {
        let clock = TestClock()
        let ledger = TriggerLedger()
        let policy = IdleReWarmPolicy(clock: clock, trigger: { await ledger.fire() })

        clock.now += IdleReWarmTargets.idleDuration * 2 / 5
        policy.noteSessionEnded()
        clock.now += IdleReWarmTargets.idleDuration

        let fired = policy.tick()
        XCTAssertTrue(fired, "the fresh window opens at the end — five idle minutes after it must fire")
        await waitUntil { await ledger.fires == 1 }
        let again = policy.tick()
        XCTAssertFalse(again)
        let fires = await ledger.fires
        XCTAssertEqual(fires, 1)
    }

    /// Two windows, two fires: a spent window followed by a session cycle opens a fresh, fireable
    /// one.
    func testTwoWindowsFireTwice() async {
        let clock = TestClock()
        let ledger = TriggerLedger()
        let policy = IdleReWarmPolicy(clock: clock, trigger: { await ledger.fire() })

        clock.now += IdleReWarmTargets.idleDuration
        let first = policy.tick()
        XCTAssertTrue(first)
        await waitUntil { await ledger.fires == 1 }

        policy.noteSessionStarted()
        policy.noteSessionEnded()
        clock.now += IdleReWarmTargets.idleDuration

        let second = policy.tick()
        XCTAssertTrue(second)
        await waitUntil { await ledger.fires == 2 }
        let fires = await ledger.fires
        XCTAssertEqual(fires, 2)
    }

    /// The first window opens at construction: launch-idle counts, so a failed launch prepare
    /// gains a bounded five-minute auto-retry through the resolver (phase (c), edge cases).
    func testTheFirstWindowOpensAtConstruction() async {
        let clock = TestClock()
        let ledger = TriggerLedger()
        let policy = IdleReWarmPolicy(clock: clock, trigger: { await ledger.fire() })

        clock.now += IdleReWarmTargets.idleDuration

        let fired = policy.tick()
        XCTAssertTrue(fired, "launch-idle counts — no session ever started and the window still fires")
        await waitUntil { await ledger.fires == 1 }
        let fires = await ledger.fires
        XCTAssertEqual(fires, 1)
    }

    /// Mark-before-fire: the fire is marked spent **before** the trigger runs, so while a re-warm
    /// is parked (a slow reload) a second tick answers no and the fire cannot double.
    func testMarkBeforeFirePreventsASecondTickWhileTheTriggerIsParked() async {
        let clock = TestClock()
        let trigger = ParkedTrigger()
        let policy = IdleReWarmPolicy(clock: clock, trigger: { await trigger.park() })

        clock.now += IdleReWarmTargets.idleDuration

        let fired = policy.tick()
        XCTAssertTrue(fired)
        await waitUntil { await trigger.fires == 1 }

        let second = policy.tick()
        XCTAssertFalse(second, "the fire is marked before the trigger runs — a parked trigger cannot double it")

        await trigger.openGate()
        let fires = await trigger.fires
        XCTAssertEqual(fires, 1)
    }
}

/// The trigger, as a counting ledger — every fire recorded, so "exactly once" is a count.
/// An actor, because the trigger crosses from the policy into the test's observation.
private actor TriggerLedger {
    private(set) var fires = 0

    func fire() {
        fires += 1
    }
}

/// The trigger, parked until the test opens the gate — the mark-before-fire proof's suspension
/// point (a slow reload in flight).
private actor ParkedTrigger {
    private var parked: CheckedContinuation<Void, Never>?
    private(set) var fires = 0

    func park() async {
        fires += 1
        await withCheckedContinuation { parked = $0 }
    }

    func openGate() {
        parked?.resume()
        parked = nil
    }
}