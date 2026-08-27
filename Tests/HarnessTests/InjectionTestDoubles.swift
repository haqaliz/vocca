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

import Synchronization
import VoccaCore
import VoccaInject

// The doubles the injection ladder's fault-injection suite is driven through, shared by every
// test in `InjectionLadderTests.swift`.
//
// Shared rather than copied, for the reason `SessionTestDoubles.swift` gives at its top: the
// ladder's whole contract — the decision table, the zero-loss acceptance, the order seam — is
// measured against these objects, and a second copy that drifted from this one would let one test
// pass against a ladder that behaves differently from the one the others measure.

// MARK: - A clock with a cost

/// A clock that **charges every read**: each `now` advances the reading by a fixed step.
///
/// The ladder's decision reads the injected clock once at its start and once after every rung
/// turn, so a stepping clock turns "time passes while a rung runs" into "every boundary crossing
/// costs `step`" — the shape of the real ladder, where each rung attempt is an asynchronous
/// system call that takes real milliseconds (`ARCHITECTURE.md:271` budgets the whole ladder at
/// ≤100 ms). The test asserts the accumulated elapsed against the arithmetic of the steps, and
/// the negative-step variant is what exercises the decision's negative-delta rule (the
/// `SessionMachine.tick()` rule): a clock that steps *backwards* produces deltas that must
/// contribute nothing.
///
/// A plain hand-moved `TestClock` (from `SessionTestDoubles.swift`) is used for the refusal rows,
/// where the decision never advances past its first reading.
final class StepAdvancingClock: MonotonicClock {
    /// How much one read advances the reading. Negative means "time runs backwards".
    let step: Duration
    private var value: Duration = .zero

    init(step: Duration) {
        self.step = step
    }

    var now: Duration {
        value += step
        return value
    }
}

// MARK: - The rung strategies

/// **A rung, minus the system call** — the one thing CI can execute, because the three real rungs
/// (AX insertion, clipboard paste, keystroke synthesis) are all system calls the adapters aspect
/// will ship, and every decision about what a rung's answer *means* is the decision function's,
/// not this double's.
///
/// An **actor**, not a class: ``InjectionRungStrategy`` is a `Sendable` protocol, and the double
/// must cross the decision's awaits honestly — the `StubEngine` precedent
/// (`ASRTestDoubles.swift:36-38`) puts the honest actor on the boundary instead of an `@unchecked
/// Sendable` annotation.
///
/// Its outcome is fixed at construction — the decision calls each rung at most once per ladder
/// run, so a mutable queue would be a knob nothing turns. It records what it was asked, so a test
/// can tell whether the ladder consulted it at all and with whose text.
actor FakeInjectionStrategy: InjectionRungStrategy {
    let rung: InjectionRung
    /// The answer every call returns. `.succeeded(verified: false)` on the accessibility rung is
    /// the **silent lie** the decision must treat as failure (`ARCHITECTURE.md:400`).
    private let outcome: RungAttempt

    private(set) var callCount = 0
    private(set) var receivedText: String?
    private(set) var receivedTarget: TargetContext?

    init(rung: InjectionRung, outcome: RungAttempt) {
        self.rung = rung
        self.outcome = outcome
    }

    func tryInject(_ text: String, into target: TargetContext) async -> RungAttempt {
        callCount += 1
        receivedText = text
        receivedTarget = target
        return outcome
    }
}

// MARK: - The order

/// An order the test dictates, for the "custom injected order changes the sequence with no
/// decision-code change" claim: the decision takes the resolved list, so this double is the
/// stand-in for C8's per-app strategy memory.
struct FakeInjectionStrategyOrder: InjectionStrategyOrder {
    let rungs: [InjectionRung]

    func orderedRungs(for bundleID: String?) -> [InjectionRung] {
        rungs
    }
}

// MARK: - The allowlist

/// An allowlist the test dictates, for pinning the default order's two shapes: accessibility
/// first for a listed bundle, never for anything else.
struct FakeInjectionAllowlist: InjectionAllowlist {
    let allowed: Set<String>

    func contains(bundleID: String) -> Bool {
        allowed.contains(bundleID)
    }
}

// MARK: - The failsafe handoff

/// The failsafe floor, as a ledger: every transcript the ladder hands over, in order.
///
/// The zero-loss acceptance (`CAPABILITY_ROADMAP.md:106`) is asserted against exactly this — the
/// handoff must have received the transcript in *every* combination that exhausts the ladder, and
/// must have received nothing when a rung delivered. "The session ended" is not "the microphone
/// was released", and "the ladder ran" is not "the transcript was held": only this ledger tells
/// the two apart, which is why every fault-injection assertion is made against what it recorded
/// rather than against a call the decision is believed to have made.
///
/// An actor, for the same reason ``FakeInjectionStrategy`` is: ``FailsafeHandoff`` is a `Sendable`
/// protocol.
actor RecordingFailsafeHandoff: FailsafeHandoff {
    /// Every transcript held, in order. Empty means the ladder never fell through.
    private(set) var held: [HeldTranscript] = []

    /// Whether the next ``hold(_:)`` refuses custody — a journal failure the test injects, so the
    /// decision's surfacing of the error (plan §8) has somewhere to run.
    private var refusesNextHold = false

    init() {}

    /// Refuses the next hold, once.
    func refuseNextHold() {
        refusesNextHold = true
    }

    func hold(_ transcript: HeldTranscript) async throws {
        if refusesNextHold {
            refusesNextHold = false
            throw TestHandoffError.refusedCustody
        }
        held.append(transcript)
    }
}

/// What a refused hand-off is, for the throw test. The value is that `hold` throws — the specific
/// error is the journal's business.
enum TestHandoffError: Error {
    case refusedCustody
}

// MARK: - The strategy memory's clock

/// **Epoch seconds the test moves by hand** — the strategy memory's second clock.
///
/// The ladder's own ``MonotonicClock`` measures a single run's `elapsed` in `Duration`; the
/// strategy memory measures the *re-probe window* in integer epoch seconds
/// (``StrategyMemoryTargets/reprobeWindowSeconds``, 604 800 s), and the two never mix — a
/// monotonic reading is meaningless across launches, and a wall-clock second is meaningless
/// inside one ladder run. This double is the second of the two, so a test can step a week
/// forward without waiting one.
///
/// A `Mutex` rather than a plain `var`: the memory's `now` supplier is `@Sendable` and is read
/// from whatever isolation asks the projection a question — the main actor for the order, the
/// accessibility rung's actor for the allowlist gate.
final class TestEpochClock: Sendable {
    private let value: Mutex<UInt64>

    init(_ start: UInt64 = 0) {
        self.value = Mutex(start)
    }

    /// The supplier handed to the memory. Reads the current second; never advances by itself.
    /// Captures `self`, not the lock: a `Mutex` is non-copyable and cannot be captured at all.
    var read: @Sendable () -> UInt64 {
        { [self] in self.now }
    }

    /// The second the clock currently reads.
    var now: UInt64 {
        value.withLock { $0 }
    }

    /// Moves the clock forward by `seconds`.
    func advance(by seconds: UInt64) {
        value.withLock { $0 += seconds }
    }

    /// Sets the clock to `second` outright.
    func set(to second: UInt64) {
        value.withLock { $0 = second }
    }
}
