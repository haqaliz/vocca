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
import VoccaUI
import XCTest

/// The onboarding window's `@MainActor` store (`first-run-permissions` A5) — the
/// ``WidgetStateStore`` shape applied to the onboarding flow: the store folds the closed
/// ``OnboardingAction`` set through ``OnboardingReducer``, the raw status facts arrive through
/// **injected closures** (the ``SettingsBindings`` closure-seam shape), and the store never calls
/// a system API — everything the flow can read or write comes in through those closures or goes
/// out through the injected completion write.
///
/// Three things are pinned here that the reducer tests cannot pin, because they are the store's,
/// not the table's:
///
/// - **The route**: every action in the closed set folds through to exactly the reducer's answer
///   (the same closed-set totality `WidgetStateStoreTests` runs for its input set).
/// - **The reads**: ``OnboardingStore/refresh()`` consults exactly the three injected closures
///   and maps their answers through ``OnboardingPermissionReads`` — including the **armed-fact
///   feed**: `TapHealth != .permissionMissing` is the raw `tapArmed` input, and a trusted-but-
///   deaf tap must read as ``OnboardingAccessibility/grantedNotArmed`` (M5c), never as armed.
/// - **The completion write**: ``markComplete`` fires exactly when ``tryItSucceeded`` lands —
///   the R4 pin held at the store surface — and no other transition touches it.
///
/// The store also carries the flow's one piece of glue beyond the reducer: the **advance rule**.
/// The reducer's statuses are facts that never move the step, and the window has no "Next"
/// button — the spec's mock names only [ Get started ], Skip, and [ Restart Vocca ] — so the
/// store folds ``OnboardingAction/begin`` itself when the current step's preconditions are met
/// (`OnboardingReducer/initialState(accessibility:microphone:model:)`'s resume target differs
/// from the current step). Pinned here over the rows that matter: never at WELCOME (the button's
/// job), never past TRY IT without a real transcript, and never over a shown M7 refusal.
@MainActor
final class OnboardingStoreTests: XCTestCase {

    // MARK: - The probe

    /// The three raw facts and the completion write, all recorded — a plain (non-isolated) class
    /// so the store's closures capture it freely.
    private final class Probe {
        var trusted = false
        var tapArmed = false
        var microphone: MicrophoneAuthorizationStatus = .notDetermined
        var completeCalls = 0
        var trustedReads = 0
        var tapArmedReads = 0
        var microphoneReads = 0

@MainActor
        func makeStore() -> OnboardingStore {
            OnboardingStore(
                accessibilityTrusted: { self.trustedReads += 1; return self.trusted },
                tapArmed: { self.tapArmedReads += 1; return self.tapArmed },
                microphoneStatus: { self.microphoneReads += 1; return self.microphone },
                markComplete: { self.completeCalls += 1 })
        }
    }

    /// One action per closed-set case, with representative payloads.
    private var closedSet: [OnboardingAction] {
        [
            .begin,
            .accessibilityStatusChanged(.grantedNotArmed),
            .accessibilityGrantSignal,
            .microphoneStatusChanged(.denied),
            .microphoneRequestResulted(false),
            .modelStatusChanged(.downloading(0.5)),
            .modelDownloadCancelled,
            .tryItPressed,
            .tryItSucceeded("hello"),
            .tryItFailed,
            .restartRequested,
            .restartDismissed,
            .windowClosed,
        ]
    }

    // MARK: - The route

    /// A fresh store opens at WELCOME — the window's constructed opening state
    /// (`OnboardingState`'s own defaults; `begin` re-derives the first incomplete step).
    func testTheStoreStartsAtTheWelcomeStep() {
        let store = Probe().makeStore()
        XCTAssertEqual(store.state.step, .welcome)
        XCTAssertEqual(store.state, OnboardingState())
    }

    /// The closed set folds through: every action the views can deliver lands in exactly the
    /// reducer's answer, from a WELCOME state where the advance rule is inert by construction
    /// (the advance never fires at WELCOME — [ Get started ] is the button's job).
    func testTheStoreFoldsEveryActionOfTheClosedSetThroughTheReducer() {
        let probe = Probe()
        let store = probe.makeStore()

        for action in closedSet {
            let expected = OnboardingReducer.reduce(store.state, action: action)
            store.fold(action)
            XCTAssertEqual(
                store.state, expected,
                "\(action) must fold through to exactly the reducer's answer")
        }
        XCTAssertEqual(
            probe.completeCalls, 1,
            "the closed set's tryItSucceeded is the one write in the whole fold — and only it")
    }

    // MARK: - The reads

    /// `refresh()` consults exactly the three injected closures and folds the mapped statuses —
    /// the `SettingsBindings` shape: the store reads nothing on its own, and the mappings are
    /// the pure seam's (``OnboardingPermissionReads``), reached through the raw facts.
    func testRefreshConsultsTheInjectedReadsAndFoldsTheMappedStatuses() {
        let probe = Probe()
        probe.trusted = true
        probe.tapArmed = true
        probe.microphone = .granted
        let store = probe.makeStore()

        store.refresh()

        XCTAssertEqual(store.state.accessibility, .armed)
        XCTAssertEqual(store.state.microphone, .granted)
        XCTAssertEqual(probe.trustedReads, 1, "refresh reads the trust fact exactly once")
        XCTAssertEqual(probe.tapArmedReads, 1, "refresh reads the armed fact exactly once")
        XCTAssertEqual(probe.microphoneReads, 1, "refresh reads the mic status exactly once")
    }

    /// The armed-fact feed (M5c): `TapHealth != .permissionMissing` is the raw input, and the
    /// three-state mapping is driven through it — a trusted-but-deaf tap is `grantedNotArmed`
    /// with the restart offer, never a fabricated `armed`.
    func testTheArmedFactFeedsTheAccessibilityStatusThreeStates() {
        // Trusted + armed: the tap delivers — the grant is real and the hotkey works.
        let armedProbe = Probe()
        armedProbe.trusted = true
        armedProbe.tapArmed = true
        let armedStore = armedProbe.makeStore()
        armedStore.refresh()
        XCTAssertEqual(armedStore.state.accessibility, .armed)
        XCTAssertFalse(armedStore.state.restartOffered)

        // Trusted + deaf (health == .permissionMissing): granted, restart to arm — the ✓ that
        // hides a dead tap is the silent gate this capability exists to kill.
        let deafProbe = Probe()
        deafProbe.trusted = true
        deafProbe.tapArmed = false
        let deafStore = deafProbe.makeStore()
        deafStore.refresh()
        XCTAssertEqual(deafStore.state.accessibility, .grantedNotArmed)
        XCTAssertTrue(deafStore.state.restartOffered)

        // Not trusted: whatever the tap's health says, a dead tap cannot fabricate a grant.
        let untrustedProbe = Probe()
        untrustedProbe.trusted = false
        untrustedProbe.tapArmed = true
        let untrustedStore = untrustedProbe.makeStore()
        untrustedStore.refresh()
        XCTAssertEqual(untrustedStore.state.accessibility, .notGranted)
        XCTAssertFalse(untrustedStore.state.restartOffered)
    }

    /// The mic mapping routes through the same injected-read shape: the raw TCC status becomes
    /// the reducer's vocabulary in the pure seam, not in the store.
    func testTheMicrophoneReadMapsThroughThePureSeam() {
        let probe = Probe()
        probe.microphone = .denied
        let store = probe.makeStore()
        store.refresh()
        XCTAssertEqual(store.state.microphone, .denied)
        XCTAssertEqual(probe.microphoneReads, 1)
    }

    /// The store never calls a system API: folding actions consults **no** read at all — the
    /// reads are the closures' whole job, and only `refresh()` ever touches them.
    func testFoldingActionsConsultsNoRead() {
        let probe = Probe()
        let store = probe.makeStore()

        for action in closedSet {
            store.fold(action)
        }

        XCTAssertEqual(probe.trustedReads, 0, "an action fold must not read the trust fact")
        XCTAssertEqual(probe.tapArmedReads, 0, "an action fold must not read the armed fact")
        XCTAssertEqual(probe.microphoneReads, 0, "an action fold must not read the mic status")
    }

    // MARK: - The completion write (R4, at the store surface)

    /// TRY IT success completes the flow and writes the flag exactly once: `completed`, the
    /// DONE step, the delivered transcript — and `markComplete` fires once, never again for a
    /// second fold of a completed flow (the reducer's own guard, held at the store).
    func testTryItSuccessCompletesTheFlowAndWritesTheCompletionFlagExactlyOnce() {
        let probe = Probe()
        let store = probe.makeStore()

        store.fold(.tryItSucceeded("hello world"))

        XCTAssertTrue(store.state.completed)
        XCTAssertEqual(store.state.step, .done)
        XCTAssertEqual(store.state.deliveredTranscript, "hello world")
        XCTAssertEqual(probe.completeCalls, 1)

        store.fold(.tryItSucceeded("again"))
        XCTAssertEqual(probe.completeCalls, 1, "a completed flow cannot complete again")
    }

    /// No transition but `tryItSucceeded` writes the flag — the R4 pin driven over the whole
    /// closed set from an uncompleted state: nothing a mid-flow user can do persists completion.
    func testNoActionButTryItSuccessWritesTheCompletionFlag() {
        let probe = Probe()
        let store = probe.makeStore()

        for action in closedSet where action != .tryItSucceeded("hello") {
            store.fold(action)
        }

        XCTAssertFalse(store.state.completed)
        XCTAssertEqual(probe.completeCalls, 0)
    }

    // MARK: - The advance rule

    /// The one piece of glue beyond the reducer: when the current step's preconditions are met,
    /// the store folds `begin` itself — the flow has no Next button, so the advance is derived,
    /// deterministically, from the same pure resume the reducer owns. Both permissions granted
    /// and armed advance PERMISSIONS → MODEL; a committed model advances MODEL → TRY IT.
    func testTheStoreAdvancesWhenTheCurrentStepsPreconditionsAreMet() {
        let store = Probe().makeStore()
        store.fold(.begin)
        XCTAssertEqual(store.state.step, .permissions, "a fresh flow resumes at PERMISSIONS")

        store.fold(.accessibilityStatusChanged(.grantedNotArmed))
        store.fold(.microphoneStatusChanged(.granted))
        XCTAssertEqual(
            store.state.step, .permissions,
            "a granted-but-deaf tap is not armed — the flow must not advance past it (M5c)")
        XCTAssertTrue(store.state.restartOffered)

        store.fold(.accessibilityStatusChanged(.armed))
        XCTAssertEqual(store.state.step, .model, "both permissions met advances to MODEL")

        store.fold(.modelStatusChanged(.committed))
        XCTAssertEqual(store.state.step, .tryIt, "a committed model advances to TRY IT")

        store.fold(.begin)
        XCTAssertEqual(
            store.state.step, .tryIt,
            "the advance never moves past TRY IT without a real transcript (M4)")
    }

    /// The advance never fires at WELCOME — the [ Get started ] button is the door — and the
    /// M7 refusal survives a fold: pressing TRY IT over a skipped model sets the refusal and
    /// does not advance (the surface must show, not vanish).
    func testTheAdvanceRespectsWelcomeAndTheM7Refusal() {
        let store = Probe().makeStore()
        store.fold(.accessibilityStatusChanged(.armed))
        store.fold(.microphoneStatusChanged(.granted))
        XCTAssertEqual(
            store.state.step, .welcome,
            "statuses at WELCOME must not advance — [ Get started ] is the door")

        store.fold(.begin)
        store.fold(.modelStatusChanged(.skipped))
        XCTAssertEqual(store.state.step, .tryIt, "a skip is a decision — the flow lands at TRY IT")

        store.fold(.tryItPressed)
        XCTAssertEqual(store.state.tryItUnavailableReason, .modelUnavailable)
        XCTAssertEqual(
            store.state.step, .tryIt,
            "the M7 refusal must survive the fold — the [ Download now ] surface is not a "
                + "blink")
    }

    /// Closing the window folds `windowClosed`: the resume entry re-derives the first incomplete
    /// step, and a completed flow is preserved whole — closing must never un-complete (M4/R4).
    func testWindowClosedResumesAndNeverUncompletes() {
        let store = Probe().makeStore()
        store.fold(.begin)
        store.fold(.accessibilityStatusChanged(.armed))
        store.fold(.microphoneStatusChanged(.granted))
        store.fold(.modelStatusChanged(.skipped))
        XCTAssertEqual(store.state.step, .tryIt)

        store.fold(.windowClosed)
        XCTAssertEqual(
            store.state.step, .tryIt,
            "closing resumes at the first incomplete step — TRY IT, for a skipped model")

        store.fold(.tryItSucceeded("done"))
        store.fold(.windowClosed)
        XCTAssertTrue(store.state.completed, "closing must never un-complete")
        XCTAssertEqual(store.state.step, .done)
    }
}