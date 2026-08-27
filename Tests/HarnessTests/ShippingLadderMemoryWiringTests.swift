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

import Foundation
import VoccaCore
@testable import VoccaInject
import XCTest

/// **T16 — one instance, three slots** (`memory-order/spec.md`, PRD R6).
///
/// The whole promotion design rests on the memory being a single object in three roles. If
/// ``ShippingLadder/makeWithMemory(memory:handoff:clock:)`` handed the accessibility rung a
/// *different* allowlist from the one the order projects — the seeded list, say — the two would
/// disagree the moment anything was learned: the order would offer the promotion probe and the
/// rung would decline it, silently, before making one accessibility call, and the decline would
/// then be recorded as the rung having failed. Nothing would ever be promoted, and no test of
/// either half alone would notice.
///
/// So this is asserted by object identity rather than by behaviour. A behavioural check would
/// have to make the accessibility rung actually run, and the shipped rung's next step after the
/// gate is a real accessibility call into whatever application happens to be focused on the
/// machine running CI.
final class ShippingLadderMemoryWiringTests: XCTestCase {

    @MainActor
    private func makeMemory() -> MemoryBackedInjectionStrategyOrder {
        MemoryBackedInjectionStrategyOrder(
            seed: SeededInjectionAllowlist(),
            strategies: [],
            store: EphemeralInjectionStrategyStore(),
            now: { 0 })
    }

    /// The order slot, the accessibility rung's gate and the recorder are the same object.
    @MainActor
    func testOrderAndRungShareTheSameAllowlistInstance() throws {
        let memory = makeMemory()
        let ladder = ShippingLadder.makeWithMemory(
            memory: memory, handoff: RecordingFailsafeHandoff(), clock: TestClock())

        XCTAssertTrue(
            ladder.order as AnyObject === memory,
            "The ladder's rung order is not the memory — nothing learned would reach the order.")
        XCTAssertTrue(
            ladder.recorder as AnyObject? === memory,
            "The ladder records into something other than the memory it reads from.")

        let rung = try XCTUnwrap(
            ladder.strategies[.accessibility] as? AccessibilityRungStrategy,
            "The shipped ladder no longer carries an accessibility rung strategy.")
        XCTAssertTrue(
            rung.allowlist as AnyObject === memory,
            """
            The accessibility rung's gate is a different object from the order's. The two answer \
            the same question — may this application be typed into through accessibility — and \
            when they disagree the promotion probe the order schedules is declined by the rung \
            before any accessibility call, then recorded as the rung failing.
            """)
    }

    /// The C4 factory is untouched: `make` still wires the seeded allowlist into both slots and
    /// still builds an injector that records nothing. Every caller that predates the memory keeps
    /// its exact behaviour.
    @MainActor
    func testTheC4FactoryStillBuildsALadderThatLearnsNothing() {
        let ladder = ShippingLadder.make(
            allowlist: SeededInjectionAllowlist(),
            handoff: RecordingFailsafeHandoff(),
            clock: TestClock())

        XCTAssertNil(
            ladder.recorder,
            "The pre-C8 factory now builds a learning ladder — its callers did not ask for one.")
        XCTAssertTrue(ladder.order is DefaultInjectionStrategyOrder)
    }

    /// The end-to-end promotion flow over a factory-built ladder: the memory is the only thing
    /// the ladder consults, so a promotion recorded through the injector is visible to the gate
    /// the rung would ask next.
    ///
    /// Driven over fake rung strategies rather than the shipped ones — the shipped accessibility
    /// rung's next step after the gate is a real accessibility call.
    @MainActor
    func testAPromotionRecordedThroughTheLadderReachesTheGate() async {
        let clock = TestEpochClock(0)
        let memory = MemoryBackedInjectionStrategyOrder(
            seed: FakeInjectionAllowlist(allowed: []),
            strategies: [],
            hostileBundleIDs: [],
            store: EphemeralInjectionStrategyStore(),
            now: clock.read)
        let ladder = LadderInjector(
            strategies: [
                .clipboardPaste: FakeInjectionStrategy(
                    rung: .clipboardPaste, outcome: .succeeded(verified: false))
            ],
            order: memory,
            handoff: RecordingFailsafeHandoff(),
            clock: TestClock(),
            recorder: memory)
        let target = TargetContext(
            bundleID: "com.example.Editor", windowTitle: nil, isSecureInput: false)

        _ = await ladder.inject("hello", into: target)
        XCTAssertFalse(
            memory.contains(bundleID: "com.example.Editor"),
            "A clipboard delivery opened the accessibility gate immediately.")

        clock.advance(by: StrategyMemoryTargets.reprobeWindowSeconds)
        XCTAssertTrue(
            memory.contains(bundleID: "com.example.Editor"),
            """
            One dictation through the real ladder, one window later, and the gate is still shut. \
            The candidate the delivery created never became a probe.
            """)
    }
}
