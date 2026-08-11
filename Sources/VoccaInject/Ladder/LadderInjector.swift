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

/// One of ``TextInjector``'s implementations: the orchestration half of the injection seam
/// (`ARCHITECTURE.md:212`), which runs ``decide(text:target:targetAppName:orderedRungs:strategies:handoff:clock:)``
/// over injected rung strategies, strategy order, failsafe handoff and clock.
///
/// The per-rung strategies are the other half of the same seam (the adapters aspect); this struct
/// owns none of the system calls and none of the decisions about what a rung's answer means —
/// it resolves the target's rung order through the injected ``InjectionStrategyOrder`` (whose
/// allowlist gate is where the accessibility rung is earned), hands the decision its inputs, and
/// returns whatever the decision decided. The failsafe outcome (`rung == .widgetFailsafe`) is a
/// *successful* result under I1 and is returned, never thrown (`ARCHITECTURE.md:199`).
///
/// The focused application's name is not yet resolvable at this aspect (it arrives with the
/// adapters aspect' resolver), so the decision is told `nil` and the failsafe window falls back
/// to its name-less phrasing until then.
///
/// ## Isolation
///
/// `@MainActor`, and for the reason every other object on this path is: the ladder crosses no
/// actor boundaries on the latency path, and its only non-`Sendable` dependency — the injected
/// ``MonotonicClock`` — is confined to this one domain with it. ``TextInjector``'s `Sendable`
/// requirement is satisfied by the isolation.
///
/// ## The one branch this struct owns
///
/// ``decide`` is `throws` because the handoff's journal reports its own failure by throwing, and
/// the decision surfaces it. This conformance cannot — ``TextInjector`` has no throwing variant —
/// so a handoff that refuses custody lands here: the ladder did fall through to the failsafe
/// terminal, and the transcript's *custody* failing is the journal's defect, made unreachable by
/// the durable-before-return contract. The residual reports the failsafe outcome rather than
/// crashing or inventing an error the seam cannot carry.
@MainActor
public struct LadderInjector: TextInjector {
    private let strategies: [InjectionRung: any InjectionRungStrategy]
    private let order: any InjectionStrategyOrder
    private let handoff: any FailsafeHandoff
    private let clock: any MonotonicClock

    /// - Parameters:
    ///   - strategies: The rung strategies, keyed by rung. The caller wires the allowlist into
    ///     the order it injects — ``DefaultInjectionStrategyOrder(allowlist:)`` is where the C4
    ///     empty allowlist enters the ladder.
    ///   - order: The rung order for the target application (C8's per-app strategy memory will be
    ///     a second implementation).
    ///   - handoff: The failsafe floor — the journal in the `failsafe-surface` aspect.
    ///   - clock: The only way time enters the ladder.
    public init(
        strategies: [InjectionRung: any InjectionRungStrategy],
        order: any InjectionStrategyOrder,
        handoff: any FailsafeHandoff,
        clock: any MonotonicClock
    ) {
        self.strategies = strategies
        self.order = order
        self.handoff = handoff
        self.clock = clock
    }

    public func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        do {
            return try await decide(
                text: text,
                target: target,
                targetAppName: nil,
                orderedRungs: order.orderedRungs(for: target.bundleID),
                strategies: strategies,
                handoff: handoff,
                clock: clock)
        } catch {
            // The handoff refused custody — the I1-floor residual documented above.
            return InjectionResult(
                rung: .widgetFailsafe, attempted: [], verified: false, elapsed: .zero)
        }
    }
}
