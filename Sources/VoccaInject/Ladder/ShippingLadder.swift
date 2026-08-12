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

/// The shipping ladder's assembly: the real rung strategies, composed over the real adapters,
/// in the one place the composition root can reach them.
///
/// The three rung adapters (`AccessibilityRungStrategy`, `ClipboardRungStrategy`,
/// ``KeystrokeSource``) and their seams are module-internal — they sit behind the H7 per-seam
/// table, and nothing else in `VoccaInject` may name the system families they speak. This type is
/// the seam between that confinement and the outside: it composes the internal types into the
/// ``LadderInjector`` the composition root wires, and its public surface names no system
/// identifier at all (the `loop-wiring` Task 3 pattern — "a small public factory ... it composes
/// existing internal types" — applied to the ladder).
///
/// ## What ships, and what deliberately does not
///
/// The strategy map holds the accessibility rung (allowlist-gated, read-back-verified) and the
/// clipboard rung (save, set, paste, settle, restore-if-ours). The **keystroke-synthesis rung has
/// no strategy yet**: its adapter (`KeystrokeSource.typeText`) exists, but the rung wrapper that
/// paces it was never built, so the map omits it — and the ladder decision's contract treats an
/// absent rung as a failed rung ("the map is the truth", `InjectionLadderDecision.swift:110-116`),
/// which is how the shipped ladder falls through to the failsafe rather than typing blindly. When
/// the keystroke rung strategy lands, it is added to the map here and nowhere else.
///
/// ## Isolation
///
/// `@MainActor`, like every object on the latency path: the ladder and the rung strategies live
/// in the one isolation domain the session graph lives in.
@MainActor
public enum ShippingLadder {

    /// The shipped ``LadderInjector``: seeded allowlist, default rung order, real strategies.
    ///
    /// - Parameters:
    ///   - allowlist: The accessibility rung's gate — ``SeededInjectionAllowlist`` at ship. It is
    ///     handed to the rung *and* to the order, so the two can never disagree about which
    ///     applications earn the verified rung.
    ///   - handoff: The failsafe floor — the ``JournalTranscriptHolder`` over the recovery
    ///     journal, at ship. The same holder the composition root hands the FAILSAFE panel.
    ///   - clock: The only way time enters the ladder.
    public static func make(
        allowlist: any InjectionAllowlist,
        handoff: any FailsafeHandoff,
        clock: any MonotonicClock
    ) -> LadderInjector {
        let keystrokes = KeystrokeSource()
        let strategies: [InjectionRung: any InjectionRungStrategy] = [
            .accessibility: AccessibilityRungStrategy(
                allowlist: allowlist, insert: AXSource()),
            .clipboardPaste: ClipboardRungStrategy(
                pasteboard: SystemPasteboard(), keystrokes: keystrokes),
        ]
        return LadderInjector(
            strategies: strategies,
            order: DefaultInjectionStrategyOrder(allowlist: allowlist),
            handoff: handoff,
            clock: clock)
    }
}
