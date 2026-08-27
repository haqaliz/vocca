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

import Combine
import Foundation
import VoccaCore

/// The onboarding flow's observable state: the `@MainActor` store the window renders, folding
/// the closed ``OnboardingAction`` set through ``OnboardingReducer`` over **injected** raw facts
/// — the ``WidgetStateStore`` shape applied to `first-run-permissions` A5, and the
/// ``SettingsBindings`` closure-seam shape for the reads.
///
/// ## The store never calls a system API
///
/// Everything the flow can read comes in through the three injected closures — the AX trust
/// `Bool`, the tap-armed fact (`TapHealth != .permissionMissing`), and the raw
/// ``MicrophoneAuthorizationStatus`` — and everything it can write goes out through the injected
/// ``markComplete``. The mapping from raw facts to the reducer's vocabulary is the pure seam's
/// (``OnboardingPermissionReads``), reached here in one place: ``refresh()``. A test drives the
/// store with recording fakes and pins that an action fold consults **no** read at all.
///
/// ## The one glue beyond the reducer: the advance rule
///
/// The reducer's statuses are facts that never move the step, and the spec's mock names no Next
/// button — only [ Get started ], Skip, and [ Restart Vocca ] (`PRODUCT_SPEC.md:211-242`). So
/// the store folds ``OnboardingAction/begin`` itself when the current step's preconditions are
/// met: after every fold, if the resume target
/// (``OnboardingReducer/initialState(accessibility:microphone:model:)``) differs from the
/// current step, the flow advances. Three guards keep the rule honest:
///
/// - **Never at WELCOME**: [ Get started ] is the door — statuses arriving on the opening step
///   must not skip it.
/// - **Never past TRY IT** without a real transcript: only ``tryItSucceeded`` completes (M4).
/// - **Never over a shown refusal**: the M7 surface (`tryItUnavailableReason` set by
///   ``OnboardingAction/tryItPressed``) survives the fold — the advance is conditional on the
///   *resume target moving*, so a fold that would only rebuild the state (clearing the refusal)
///   is not made.
///
/// ## The completion write
///
/// ``markComplete`` fires exactly when a fold lands `completed` — the R4 pin ("TRY IT success is
/// the only writer") held at the store surface: no other transition in the closed set invokes it,
/// and a completed flow never invokes it twice.
///
/// ## Isolation
///
/// `@MainActor`, like the window it drives: `ObservableObject` state that views render belongs in
/// the one isolation domain the UI renders from.
@MainActor
public final class OnboardingStore: ObservableObject {

    /// The reducer's state — the single thing the window renders, published so SwiftUI observes
    /// it.
    @Published public private(set) var state: OnboardingState

    /// The raw AX trust fact (`AXSource.isProcessTrusted()` at ship).
    private let accessibilityTrusted: () -> Bool
    /// The armed fact (`TapHealth != .permissionMissing` at ship) — M5c's second input: a ✓
    /// that hides a dead tap is the silent gate this capability exists to kill.
    private let tapArmed: () -> Bool
    /// The raw microphone authorization status (`MicrophoneAuthorization.authorizationStatus()`
    /// at ship).
    private let microphoneStatus: () -> MicrophoneAuthorizationStatus
    /// The persisted-completion write (`CompletionFlagStore.markComplete()` at ship) — the
    /// store's one write, invoked only by a landed `tryItSucceeded`.
    private let markComplete: () -> Void

    /// - Parameters:
    ///   - accessibilityTrusted: `AXIsProcessTrusted()`'s answer — the grant's raw `Bool`.
    ///   - tapArmed: whether the event tap is armed — `TapHealth != .permissionMissing` at ship.
    ///   - microphoneStatus: the TCC status, raw (`MicrophoneAuthorizationStatus`).
    ///   - markComplete: persists "onboarding complete" (A3) — fired exactly on TRY IT success.
    public init(
        accessibilityTrusted: @escaping () -> Bool,
        tapArmed: @escaping () -> Bool,
        microphoneStatus: @escaping () -> MicrophoneAuthorizationStatus,
        markComplete: @escaping () -> Void
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.tapArmed = tapArmed
        self.microphoneStatus = microphoneStatus
        self.markComplete = markComplete
        // The window's constructed opening state (A1): WELCOME, both permissions unanswered, no
        // model. `begin` re-derives the first incomplete step from the statuses.
        self.state = OnboardingState()
    }

    /// Fold one action into the reducer's state, then apply the advance rule.
    public func fold(_ action: OnboardingAction) {
        let wasCompleted = state.completed
        state = OnboardingReducer.reduce(state, action: action)
        advanceIfReady()
        // The write is fired on the *transition*, not on the flag: a completed flow stays
        // completed, and a stray fold must not re-write what the reducer has already decided
        // (the R4 pin's "exactly once", held here).
        if !wasCompleted && state.completed {
            markComplete()
        }
    }

    /// Re-read the two permission facts from the injected closures and fold the mapped statuses
    /// — the live ✓/✗ (M5), fed by the wiring whenever it has reason to believe a status moved
    /// (the window's show, and the tap-health poll's every answer at ship).
    public func refresh() {
        let reads = OnboardingPermissionReads(
            accessibility: OnboardingPermissionReads.accessibility(
                trusted: accessibilityTrusted(), tapArmed: tapArmed()),
            microphone: OnboardingPermissionReads.microphone(status: microphoneStatus()))
        fold(.accessibilityStatusChanged(reads.accessibility))
        fold(.microphoneStatusChanged(reads.microphone))
    }

    /// The advance rule: if the current step is not the resume target, fold `begin` — the one
    /// place the flow moves itself, guarded so a fold that would only rebuild the state (and
    /// clear a shown M7 refusal) is never made.
    private func advanceIfReady() {
        guard !state.completed, state.step != .welcome else { return }
        let resume = OnboardingReducer.initialState(
            accessibility: state.accessibility,
            microphone: state.microphone,
            model: state.model)
        guard resume.step != state.step else { return }
        state = OnboardingReducer.reduce(state, action: .begin)
    }
}