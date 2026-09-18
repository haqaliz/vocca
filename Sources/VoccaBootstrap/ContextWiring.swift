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
import VoccaHotkey
import VoccaUI

/// **The C12 context composition's surface** (`bootstrap-wiring` D1/D2/D3/D4): the three
/// closures the composition root assigns to its slots — the consent-gated per-turn
/// resolution, the indicator fold, and the one-action kill switch.
///
/// The closures are the wiring's own vocabulary, not a parallel seam: each is the recipe's
/// answer over the shipped seams (`ContextProvider`, `ConsentStore`,
/// `SecureInputStateReader`, the widget store's `setContext`), so a consumer compiles
/// against the composition rather than against the modules the composition wires.
public struct ContextWiring: Sendable {

    /// The per-turn, consent-gated resolution for the focused bundle ID (D2): consent is
    /// consulted **before** the provider — declined answers the all-absent snapshot and the
    /// provider is never invoked (M5); Secure Input answers the all-absent snapshot and the
    /// provider is never invoked (M5b); consented answers the provider's snapshot. A
    /// resolution also folds its signal through ``foldIndicator`` — the badge rides the
    /// resolution (D3).
    public let resolve: @Sendable @MainActor (String?) async -> ContextSnapshot

    /// The indicator fold (D3): the badge signal folded into the widget store through the
    /// widget-indicator aspect's shipped fold case (`setContext` — never a reducer edit) and
    /// the menu-bar conditions fact. The wiring folds at resolution time, at wiring time, and
    /// whenever the kill switch or a consent edit re-folds.
    public let foldIndicator: @Sendable @MainActor (WidgetContextSignal) -> Void

    /// The one-action kill switch (M9, D4): a runtime revoke, never a persisted setting and
    /// never an invitation to grant. Throwing it (a) marks the composition revoked — every
    /// further resolution answers the empty snapshot and the provider is not called again,
    /// (b) discards the in-flight snapshot (nothing is persisted, so the discard is total),
    /// and (c) clears the indicator fold in the same call.
    public let killSwitch: @Sendable @MainActor () -> Void

    public init(
        resolve: @escaping @Sendable @MainActor (String?) async -> ContextSnapshot,
        foldIndicator: @escaping @Sendable @MainActor (WidgetContextSignal) -> Void,
        killSwitch: @escaping @Sendable @MainActor () -> Void
    ) {
        self.resolve = resolve
        self.foldIndicator = foldIndicator
        self.killSwitch = killSwitch
    }
}

extension AppBootstrap {

    /// **The context composition's revocation carrier** (D4): the "revoked" fact the kill
    /// switch throws and every resolution consults — a `Mutex`-backed flag (the `countLock`
    /// shape, `AppBootstrap.swift:3716`). Plain `Sendable` state, and carries no content:
    /// nothing a kill discards is retained anywhere (M10).
    final class ContextRevocation: Sendable {
        private let revoked = Mutex(false)

        init() {}

        var isRevoked: Bool {
            revoked.withLock { $0 }
        }

        func revoke() {
            revoked.withLock { $0 = true }
        }
    }

    /// **The context composition's per-turn carrier** (D3): the snapshot a resolution
    /// produced and the signal it folded — the two halves of one resolution, so the fold can
    /// never disagree with the answer. Plain data, `Sendable`; nothing is retained after the
    /// call (M10 — snapshots are ephemeral per turn).
    struct ContextResolutionCarrier: Sendable {
        let snapshot: ContextSnapshot
        let signal: WidgetContextSignal
    }

    /// **The C12 context wiring recipe** (`bootstrap-wiring` D1): the consent-gated
    /// resolution slot, the indicator fold and the kill switch, composed over the shipped
    /// seams — the `ContextProvider` (the composed default is `NullContext`, which reads
    /// nothing), the `ConsentStore` (the composition's parameter — an absent store, `nil` or
    /// a store over a missing file, answers "no consents" silently), and the
    /// `SecureInputStateReader` (the same Carbon fact the tap-health poll reads).
    ///
    /// ## The consumed shapes, as shipped (recorded — this plan's provisional names differed)
    ///
    /// - The consent read is the shipped seam's `load() -> Set<String>`; the decision is the
    ///   `ContextConsentGate`-shaped check (`consent-store`'s value lives in `VoccaContext`,
    ///   unreachable from the composition root by module boundary — `accessibility-context`
    ///   deliberately left `VoccaBootstrap` without that dependency), expressed over the
    ///   shipped Core vocabulary (`ConsentBundleID.isValid` + the loaded set).
    /// - The Secure Input routing consumes the shipped `SecureInputStateReader`
    ///   (`VoccaHotkey` — the root's existing seam for the same `IsSecureEventInputEnabled`
    ///   fact); the accessibility-context read (`ContextSecureInputRead`) stays the real
    ///   adapter's own refusal inside `AccessibilityContext`.
    ///
    /// ## Probe-safe by construction (D1)
    ///
    /// Nothing here starts, reads, or provisions: the provider is constructed by the caller
    /// (the composed default reads nothing), the consent store is consulted per resolution —
    /// never at composition — and the recipe names no network type and performs no content
    /// read of its own. The initial fold (the launch task) resolves once for no focused app,
    /// which the consent gate declines before any provider call.
    @MainActor
    public static func composeContextWiring(
        provider: any ContextProvider,
        consentStore: (any ConsentStore)?,
        secureInput: any SecureInputStateReader,
        root: DictationLoopRoot
    ) -> ContextWiring {
        let revocation = ContextRevocation()

        let foldIndicator: @Sendable @MainActor (WidgetContextSignal) -> Void = { signal in
            root.widgetStore.setContext(signal)
            root.updateMenuBarConditions {
                $0.isContextReading = signal.consentActive && !signal.secureInputActive
            }
        }

        let resolve: @Sendable @MainActor (String?) async -> ContextSnapshot = { bundleID in
            let absent = ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil)

            // The revoked gate first: after a kill, no further resolution consults anything.
            guard !revocation.isRevoked else { return absent }

            // The consent store, consulted before the provider — the decline-before-any-read
            // doctrine (M5). An absent store — nil, or a store over a missing file — answers
            // "no consents" silently (the silent-empty-memory precedent).
            let consented = await consentStore?.load() ?? []

            // The mid-turn discard: a resolution suspended when the kill lands answers the
            // empty snapshot and never reaches the provider (M9).
            guard !revocation.isRevoked else { return absent }

            let consentActive = Self.consentAllows(bundleID: bundleID, consented: consented)
            let secureInputActive = secureInput.isSecureInputActive

            guard consentActive else {
                // The decline-before-any-read half: no consent means the provider is never
                // invoked (M5) — not read-then-discard, never read — and the fold answers the
                // unlit signal in the same turn.
                foldIndicator(
                    WidgetContextSignal(
                        consentActive: false, secureInputActive: secureInputActive,
                        appName: nil))
                return absent
            }

            guard !secureInputActive else {
                // A Secure Input field is never asked (M5b): the refusal orders before any
                // provider call, and the signal's secure-input fact keeps the badge unlit in
                // the same fold.
                foldIndicator(
                    WidgetContextSignal(
                        consentActive: consentActive, secureInputActive: true, appName: nil))
                return absent
            }

            let snapshot = provider.resolveCurrent()

            guard !revocation.isRevoked else {
                // The mid-turn discard, read half: a snapshot read while the kill lands is
                // discarded — nothing is persisted, so the discard is total (M9/M10).
                foldIndicator(
                    WidgetContextSignal(
                        consentActive: false, secureInputActive: false, appName: nil))
                return absent
            }

            // The per-turn fold rides the resolution (D3): one `contextChanged` per
            // resolution, through the shipped fold case. The wiring carries no app-name
            // source — the snapshot's vocabulary has none (`ContextSnapshot` carries bundle
            // ID, window title, selection) — so the hover copy's fallback renders honestly.
            foldIndicator(
                WidgetContextSignal(
                    consentActive: consentActive, secureInputActive: false, appName: nil))
            return snapshot
        }

        let killSwitch: @Sendable @MainActor () -> Void = {
            revocation.revoke()
            // The same-fold clear (M9): the kill folds the revoked signal — the badge clears
            // in the same call, no intermediate state, no timer.
            foldIndicator(
                WidgetContextSignal(
                    consentActive: false, secureInputActive: false, appName: nil))
        }

        return ContextWiring(
            resolve: resolve,
            foldIndicator: foldIndicator,
            killSwitch: killSwitch)
    }

    /// The consent decision — the `ContextConsentGate`-shaped check, expressed over the
    /// shipped Core vocabulary: nil, invalid or unconsented is declined, before any provider
    /// call. (`consent-store`'s gate value lives in `VoccaContext`, unreachable from the
    /// composition root by module boundary; the decision is the gate's own.)
    private static func consentAllows(bundleID: String?, consented: Set<String>) -> Bool {
        guard let bundleID, ConsentBundleID.isValid(bundleID) else { return false }
        return consented.contains(bundleID)
    }
}