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

import Dispatch
import Foundation
import VoccaCore
import VoccaInject

// The probe's half of the zero-network invariant for `VoccaInject`.
//
// While `VoccaInject` held a placeholder, naming `VoccaInjectPlaceholder` in the probe's module
// list was all the invariant could say about it. It now holds the injection ladder — a decision
// function, rung strategies, a strategy order and a failsafe handoff — and a metatype reference
// says nothing about any of them: the coverage guard in `ZeroNetworkTests` is at module granularity
// by construction, so it cannot tell a module that was *reached* from a module whose work was
// *run*.
//
// So this file runs the work. `VoccaNetworkProbe.exerciseInjectionLifecycle()` drives two complete
// ladder runs through the real `LadderInjector` — one delivery and one fall-through to the
// failsafe — with probe-supplied fakes standing in for the rung adapters and the handoff journal,
// and reports what it observed afterwards. The suite asserts that observation, not the call.
// Deleting the call takes the report with it and `ZeroNetworkTests` fails by name; that is the
// property the session drive demonstrated.
//
// **Nothing here needs a permission.** No AX element is resolved (the strategy fakes sit where the
// AXRung will), no pasteboard is read or written, no `CGEvent` is synthesized, and no real clock
// is consulted. The probe runs on a runner that grants it nothing.

// MARK: - The seams the ladder needs

/// A clock the probe charges by the read: every `now` advances the reading by a fixed ``step``.
///
/// Deterministic on purpose — the whole observation below is asserted as one exact line, and a
/// reading taken from a real clock would make `elapsed` a number no test could state. Charging by
/// read rather than by hand is the decision function's shape, not a choice this drive makes: the
/// ladder reads the injected clock once at its start and once after every rung turn
/// (`InjectionLadderDecision.swift`), so "time passes while a rung runs" becomes "each boundary
/// crossing costs `step`" — the same arithmetic `StepAdvancingClock` in `InjectionTestDoubles`
/// uses, spelled a second time because a test target's types are not visible to an executable.
final class ProbeInjectionClock: MonotonicClock {
    /// How much one read advances the reading. Fixed per drive so the reported `elapsed` is exact.
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

/// A rung, minus the system call — the same double the fault-injection suite drives, in probe form.
///
/// ``InjectionRungStrategy`` is `Sendable`, so this is an actor rather than a class with an
/// `@unchecked Sendable` annotation: the honest conformance (`ASRTestDoubles.swift:36-38`
/// precedent). Its outcome is fixed at construction — the decision calls each rung at most once per
/// ladder run — and it records how often it was consulted so a drive can tell a rung that ran from
/// one that was skipped.
actor ProbeInjectionStrategy: InjectionRungStrategy {
    let rung: InjectionRung
    /// The answer every call returns. `.succeeded(verified: false)` is the unread-back truth the
    /// clipboard and keystroke rungs speak; the *decision* interprets it.
    private let outcome: RungAttempt

    private(set) var callCount = 0

    init(rung: InjectionRung, outcome: RungAttempt) {
        self.rung = rung
        self.outcome = outcome
    }

    func tryInject(_ text: String, into target: TargetContext) async -> RungAttempt {
        callCount += 1
        return outcome
    }
}

/// The failsafe floor, as a ledger: every transcript the ladder hands over, in order.
///
/// One handoff serves both runs, so `held.count` is the zero-loss answer in a single read: the
/// run that delivered must have held nothing and the run that exhausted must have held exactly one.
/// It is the in-memory conformance `FailsafeHandoff.swift` names as the probe's until the journal
/// (the `failsafe-surface` aspect) lands.
actor ProbeInjectionHandoff: FailsafeHandoff {
    private(set) var held: [HeldTranscript] = []

    func hold(_ transcript: HeldTranscript) async throws {
        held.append(transcript)
    }
}

// MARK: - The drive

extension VoccaNetworkProbe {

    /// Two ladder runs driven through the real injector, and the post-condition the suite asserts.
    struct InjectionDrive {
        /// The observation, as one line of `key=value` fields. Asserted whole — see
        /// `ZeroNetworkTests.expectedInjectionLifecycle`.
        let report: String

        /// A type minted **by this drive**, from which `VoccaInject`'s name is derived for the
        /// coverage list.
        ///
        /// This is why the module entry is not a metatype literal any more. `VoccaInjectPlaceholder`
        /// sitting in that list satisfied the coverage guard whether or not a single line of
        /// `VoccaInject` ever ran; a witness that only exists because the injector was built and
        /// driven cannot be kept while the call is deleted.
        let moduleWitness: Any.Type
    }

    /// How much one clock read costs, per run.
    ///
    /// Any value would do — nothing here is testing the ladder's budget, which
    /// `InjectionLadderTests` owns at ≤100 ms. 10 ms is a plausible per-rung cost and makes the
    /// reported elapsed a round number: one boundary crossing on the delivered run, two on the run
    /// that falls through.
    static let injectionClockStep: Duration = .milliseconds(10)

    /// The transcript both ladder runs carry. One constant so the report cannot drift between the
    /// two runs in the edit that breaks them.
    static let injectionTranscript = "to be or not to be, full stop"

    /// **Drives two complete ladder runs through the real `LadderInjector`, and reports what
    /// happened.**
    ///
    /// Run 1 ("success") targets an ordinary focused application and lets the clipboard rung
    /// deliver, exercising the ladder's shipped default path: the empty allowlist keeps the
    /// accessibility rung off the list, so the order is exactly what most users run
    /// (`clipboard → keystroke`), and the decision stops at the first success with the prefix
    /// trace. Run 2 ("failsafe") forces both rungs to fail, exercising the fall-through: the last
    /// rung records the full trace, every rung is tried, and the transcript reaches the handoff
    /// with reason `.exhausted`, so *none is lost*.
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the same reason
    /// `SessionLifecycleDrive` gives: an assertion that lives in the observed process can be
    /// deleted in the same edit that breaks what it observes, and its failure would arrive as an
    /// exit status rather than as a named expectation.
    ///
    /// It also makes no network call, which is the point of running it here at all. `VoccaInject`
    /// is an adapter module (`ModuleBoundaryTests` rule 3), so it may import `VoccaCore` and
    /// nothing else — but "cannot import a networking framework" is not "makes no connection", and
    /// this is the mechanism that says the second thing.
    static func exerciseInjectionLifecycle() -> InjectionDrive {
        // The ladder and its decision are @MainActor-isolated, so the drive has to run on the main
        // actor to touch them. We are already on the main thread here — `main()` is the process
        // entry point — so rather than hop, hand the work to a MainActor-bound Task and pump the
        // run loop until it lands: the same mechanism `settle(for:)` relies on to service main
        // queue work. The box exists because a `@Sendable` closure cannot capture and mutate a
        // `var`; everything it holds is touched on the main thread only, so the `@unchecked`
        // annotation records a fact about this drive, not a gap.
        let semaphore = DispatchSemaphore(value: 0)
        let box = InjectionDriveBox()
        Task { @MainActor in
            box.value = await buildInjectionDrive()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary. Main-thread-only; see the drive's
    /// own comment for why that makes the unchecked annotation honest.
    private final class InjectionDriveBox: @unchecked Sendable {
        var value: InjectionDrive?
    }

    /// Builds the two injectors, runs them, and assembles the report.
    @MainActor
    private static func buildInjectionDrive() async -> InjectionDrive {
        // One handoff serves both runs: a single ledger on which "the delivered run held nothing,
        // the exhausted run held one" is one number instead of two claims about two objects.
        let handoff = ProbeInjectionHandoff()

        let target = TargetContext(
            bundleID: "com.example.WordProcessor", windowTitle: "Document 1", isSecureInput: false)

        // The default order, with the C4 empty allowlist: clipboard first, then keystroke, exactly
        // the ladder actual users run. This is a real `VoccaInject` type, not a probe fake — the
        // seam under test includes the ordering.
        let order = DefaultInjectionStrategyOrder(allowlist: EmptyInjectionAllowlist())

        // Run 1: delivery. The clipboard rung answers `succeeded(verified: false)` — the raw truth
        // of a rung with no read-back — and the keystroke rung would have failed had the ladder
        // reached it, which it should not.
        let delivered = await run(
            text: injectionTranscript,
            into: target,
            order: order,
            handoff: handoff,
            strategies: [
                .clipboardPaste: ProbeInjectionStrategy(
                    rung: .clipboardPaste, outcome: .succeeded(verified: false)),
                .keystrokeSynthesis: ProbeInjectionStrategy(
                    rung: .keystrokeSynthesis, outcome: .failed),
            ])

        // Run 2: fall-through. Every rung fails, so the decision reaches the exhaustion terminal
        // and the transcript travels to the handoff.
        let fallsThrough = await run(
            text: injectionTranscript,
            into: target,
            order: order,
            handoff: handoff,
            strategies: [
                .clipboardPaste: ProbeInjectionStrategy(rung: .clipboardPaste, outcome: .failed),
                .keystrokeSynthesis: ProbeInjectionStrategy(
                    rung: .keystrokeSynthesis, outcome: .failed),
            ])

        let held = await handoff.held

        let fields = [
            "success.rung=\(describe(delivered.result.rung))",
            "success.attempted=\(describe(delivered.result.attempted))",
            "success.verified=\(delivered.result.verified)",
            "success.elapsed=\(milliseconds(delivered.result.elapsed))ms",
            "failsafe.rung=\(describe(fallsThrough.result.rung))",
            "failsafe.attempted=\(describe(fallsThrough.result.attempted))",
            "failsafe.verified=\(fallsThrough.result.verified)",
            "failsafe.elapsed=\(milliseconds(fallsThrough.result.elapsed))ms",
            "handoff.holds=\(held.count)",
            "handoff.reason=\(describe(held.first?.reason))",
            "handoff.capturedAt=\(describe(capturedAt: held.first?.capturedAt))",
        ].joined(separator: " ")

        return InjectionDrive(report: fields, moduleWitness: type(of: delivered.injector))
    }

    /// One ladder run, and the injector that produced it (the type minting the module witness).
    @MainActor
    private struct LadderRun {
        let injector: LadderInjector
        let result: InjectionResult
    }

    /// Drives one complete ladder path through the real ``LadderInjector``.
    @MainActor
    private static func run(
        text: String,
        into target: TargetContext,
        order: any InjectionStrategyOrder,
        handoff: any FailsafeHandoff,
        strategies: [InjectionRung: any InjectionRungStrategy]
    ) async -> LadderRun {
        let injector = LadderInjector(
            strategies: strategies,
            order: order,
            handoff: handoff,
            clock: ProbeInjectionClock(step: injectionClockStep))
        let result = await injector.inject(text, into: target)
        return LadderRun(injector: injector, result: result)
    }

    // MARK: - Spelling the observation

    // Every `describe` below is an exhaustive switch written out by hand rather than
    // `String(describing:)`, and every raw value used is the repository's own persisted spelling
    // (`InjectionRung` and `FailsafeReason` document their `String` raw values as the journal and
    // C8's strategy-memory schemas, so a rename is a migration) — the markers the suite matches on
    // must not change under it because a compiler or framework relabelled something.

    private static func describe(_ rung: InjectionRung) -> String {
        switch rung {
        case .accessibility: return "accessibility"
        case .clipboardPaste: return "clipboardPaste"
        case .keystrokeSynthesis: return "keystrokeSynthesis"
        case .widgetFailsafe: return "widgetFailsafe"
        }
    }

    private static func describe(_ attempted: [InjectionRung]) -> String {
        attempted.map(describe).joined(separator: ",")
    }

    private static func describe(_ reason: FailsafeReason?) -> String {
        switch reason {
        case nil: return "none"
        case .secureInput: return "secureInput"
        case .exhausted: return "exhausted"
        case .noFocusedField: return "noFocusedField"
        case .accessibilityRevoked: return "accessibilityRevoked"
        }
    }

    private static func describe(capturedAt duration: Duration?) -> String {
        switch duration {
        case nil: return "none"
        case .some(let duration): return "\(milliseconds(duration))ms"
        }
    }

    /// A `Duration` in whole milliseconds.
    ///
    /// Written out rather than taken from `Duration`'s own description, which is a standard-library
    /// spelling this package does not control — the same reason every `describe` above is written
    /// by hand.
    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
