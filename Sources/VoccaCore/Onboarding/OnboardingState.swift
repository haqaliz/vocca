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

/// The onboarding flow's five steps (`PRODUCT_SPEC.md:211-242`): WELCOME, then PERMISSIONS,
/// MODEL and TRY IT, ending at DONE. WELCOME is the window's constructed opening state; every
/// other step — and re-entry into WELCOME's successors after a close — is derived by
/// ``OnboardingReducer/initialState(accessibility:microphone:model:)``, which resumes at the
/// first incomplete step (PRD S3): a flow never remembers a step, it re-derives one from the
/// status reads.
public enum OnboardingStep: Sendable, Equatable {
    /// "Vocca types what you say, into any app." — the window's opening surface.
    case welcome
    /// Accessibility then Microphone, one at a time, each with live ✓/✗ and a direct button
    /// to the exact System Settings pane (`PRODUCT_SPEC.md:217-230`).
    case permissions
    /// "Downloading the speech model (≈600 MB, one time)" — progress, resumable, cancellable,
    /// with "Skip for now" (`PRODUCT_SPEC.md:232-236`).
    case model
    /// A live text field in the window itself; success here = onboarding complete
    /// (`PRODUCT_SPEC.md:237-240`).
    case tryIt
    /// "Vocca lives in your menu bar. Hold ⌥Space anywhere." (`PRODUCT_SPEC.md:241-242`).
    case done
}

/// The Accessibility permission's states — **three, never two** (M5c): a ✓ that hides a dead
/// tap is the silent gate this capability exists to kill.
///
/// The tap is created at launch with whatever mask the grant allows; a grant arriving
/// afterwards flips the live ✓ while the existing tap stays deaf until re-creation — a mask
/// cleared at creation cannot be re-enabled (`ARCHITECTURE.md:604`). So "granted" is not a
/// usable state on its own: the restart is the only way to arm, and the middle state carries
/// the restart path (M3).
public enum OnboardingAccessibility: Sendable, Equatable {
    /// No grant: `AXIsProcessTrusted()` is `false` — the hotkey cannot be captured at all,
    /// the one genuinely fatal permission (`PRODUCT_SPEC.md:244`).
    case notGranted
    /// The grant is present and the tap is dead: the process created its tap before the grant,
    /// and a restart is required to re-create it with a live mask. The PERMISSIONS screen
    /// renders this as its own explained state with the [Restart Vocca] path attached.
    case grantedNotArmed
    /// The tap health reports non-`permissionMissing`: the hotkey and the typing both work.
    case armed
}

/// The Microphone permission's states (TCC): `notDetermined` before the first request, then
/// the system's answer. Denial is never a dead end (M2): the denial surface names the exact
/// toggle and the flow continues when it is flipped.
public enum OnboardingMicrophone: Sendable, Equatable {
    case notDetermined
    case denied
    case granted
}

/// The MODEL step's state — mirrors ``DownloadState``'s terminal shapes
/// (`Sources/VoccaUI/DownloadState.swift:21-27`): `committed`, `failed` and `skipped` are the
/// ended session's last words, and a session that has ended must not be moved by straggler
/// events. One deliberate amendment over the mirror: a **fresh** `.downloading` is always
/// accepted from a terminal shape — M7's "[ Download now ]" and the MODEL step's retry are new
/// decisions, not the ended session's late word.
public enum OnboardingModel: Sendable, Equatable {
    /// No model installed and nothing decided.
    case absent
    /// A download is in flight; the fraction mirrors the downloader's clamped progress.
    case downloading(Double)
    /// The download verified and committed: the model serves dictations.
    case committed
    /// The download failed: the MODEL step shows retry, and TRY IT refuses honestly (M7).
    case failed
    /// The user chose "Skip for now" (`PRODUCT_SPEC.md:233-235`): terminal for the cancelled
    /// session; a new download is still a new decision.
    case skipped
}

/// Why TRY IT cannot run — **closed** (M7): the one refusal the flow itself can derive, the
/// pipeline's `.modelUnavailable` made a surface ("the MODEL step was skipped and no model is
/// installed", prd.md M7). Never a dead end: the surface offers [ Download now ] and a way
/// forward; never an auto-download (`PRODUCT_SPEC.md:233-235`).
public enum TryItUnavailable: Sendable, Equatable {
    case modelUnavailable
}

/// The onboarding flow's state — a pure fold target, so the whole decision table runs headless
/// (`OnboardingReducerTests`); the window (A5) is thin glue over this type (`DownloadState`'s
/// shape).
public struct OnboardingState: Sendable, Equatable {
    /// The step the window renders.
    public var step: OnboardingStep
    /// The Accessibility permission's live status — the restart offer rides on its middle
    /// state, never anywhere else (M5c).
    public var accessibility: OnboardingAccessibility
    /// The Microphone permission's live status.
    public var microphone: OnboardingMicrophone
    /// The MODEL step's state.
    public var model: OnboardingModel
    /// Why TRY IT cannot run, `nil` = ready (M7). Set only by a press over an
    /// `absent`/`failed`/`skipped` model; cleared by a fresh model status, a success, a
    /// failure, and every resume fold.
    public var tryItUnavailableReason: TryItUnavailable?
    /// Whether the [ Restart Vocca ] offer is showing (M3/M5c): true exactly while
    /// ``accessibility`` is `.grantedNotArmed`, except when the user has dismissed it this
    /// round — a fresh `grantedNotArmed` status re-offers.
    public var restartOffered: Bool
    /// The TRY IT success payload: the real transcript that landed in the window's field
    /// (G5). Exists exactly while ``completed`` is true.
    public var deliveredTranscript: String?
    /// Onboarding complete = a successful TRY IT dictation (M4) — set by
    /// ``OnboardingAction/tryItSucceeded(_:)`` and by no other transition, and never cleared:
    /// the persisted completion flag (A3) is written from this bit.
    public var completed: Bool

    /// The fresh-install opening state: WELCOME, both permissions unanswered, no model.
    ///
    /// The window (A5) constructs this once; `begin` then re-derives the first incomplete step
    /// (which for a fresh install is PERMISSIONS). After completion the window does not
    /// auto-show (`PRODUCT_SPEC.md` M4), so the resume entry never needs a `completed` input —
    /// the reducer's own fold preserves a done flow (``OnboardingReducer/reduce(_:action:)``).
    public init(
        step: OnboardingStep = .welcome,
        accessibility: OnboardingAccessibility = .notGranted,
        microphone: OnboardingMicrophone = .notDetermined,
        model: OnboardingModel = .absent,
        tryItUnavailableReason: TryItUnavailable? = nil,
        restartOffered: Bool = false,
        deliveredTranscript: String? = nil,
        completed: Bool = false
    ) {
        self.step = step
        self.accessibility = accessibility
        self.microphone = microphone
        self.model = model
        self.tryItUnavailableReason = tryItUnavailableReason
        self.restartOffered = restartOffered
        self.deliveredTranscript = deliveredTranscript
        self.completed = completed
    }
}

/// The intents the flow can offer the reducer. **The set is closed and time-free**: there is no
/// clock, no timer and no time-based action in it — so no transition in the flow can happen on
/// its own (the never-auto-dismiss rule, ``FailsafeAction``'s shape). The exhaustive switch in
/// ``OnboardingReducer`` cannot hide a transition no action can carry.
///
/// The permission-status actions carry the **reads' answers** — the reads themselves are
/// adapters behind injected seams (A2); this file holds no read and no system call, so a test
/// can reach every decision.
public enum OnboardingAction: Sendable, Equatable {
    /// The [ Get started ] button — and the window's *advance* action: re-derive the first
    /// incomplete step from the statuses (the same pure function `windowClosed` uses). A step
    /// whose preconditions are met advances when the window folds this.
    case begin
    /// A fresh Accessibility status read: the grant's live ✓/✗ (M5). Sets the restart offer on
    /// ``OnboardingAccessibility/grantedNotArmed``; never moves the step.
    case accessibilityStatusChanged(OnboardingAccessibility)
    /// The `com.apple.accessibility.api` grant-change signal (`TapHealthTimer`
    /// `accessibilityGrantChanged()`): the wiring's *hint* that the status may have changed.
    /// The reducer cannot read, so the hint alone is a no-op — the wiring answers it with a
    /// fresh read, which arrives as ``accessibilityStatusChanged`` (M5).
    case accessibilityGrantSignal
    /// A fresh Microphone status read.
    case microphoneStatusChanged(OnboardingMicrophone)
    /// The `requestAccess` callback's answer (M5b): true → granted, false → denied.
    case microphoneRequestResulted(Bool)
    /// A fresh MODEL status (the download session's events, mirrored).
    case modelStatusChanged(OnboardingModel)
    /// Skip for now (`PRODUCT_SPEC.md:233-235`): the download session's cancel, terminal.
    case modelDownloadCancelled
    /// The user pressed TRY IT: derives ``OnboardingState/tryItUnavailableReason`` from the
    /// model (M7) — the refusal is a surface, never a silent dead end.
    case tryItPressed
    /// A real transcript landed in the window's field (G5): the **only** transition that
    /// completes the flow (M4/R4) and moves it to DONE.
    case tryItSucceeded(String)
    /// The dictation failed: keeps the step (the failure surface is the window's), clears any
    /// refusal, never completes.
    case tryItFailed
    /// The [ Restart Vocca ] button (M3): a wiring signal — the relaunch itself is the change,
    /// and the offer survives the request so a failed relaunch remains retryable (R2).
    case restartRequested
    /// The user declined the restart: the offer clears until a fresh `grantedNotArmed` status.
    case restartDismissed
    /// The window closed (S3): resume at the first incomplete step, exactly like `begin` — and
    /// on a completed flow, a no-op: closing must never un-complete.
    case windowClosed
}

/// The onboarding flow's transition table — every action × state rule, over the closed set.
///
/// The shape of the table:
///
/// - **Resume** (`begin`/`windowClosed`, S3): re-derive the first incomplete step from the
///   statuses, exactly as ``initialState(accessibility:microphone:model:)`` does — never from
///   remembered step state. A completed flow is preserved whole: nothing in the closed set
///   clears the completion flag (M4/R4).
/// - **Statuses are facts, never steps**: a status change updates its field and never moves
///   the step — the flow is not yanked backwards by a revoked grant mid-flow (M5c edge case),
///   and it does not advance itself either; the window folds `begin` to advance.
/// - **The restart offer** (M3/M5c) is set by exactly one status —
///   ``OnboardingAccessibility/grantedNotArmed`` — and cleared by the other two and by a
///   dismiss; it is the one state in the table that says "granted, but not armed" out loud,
///   because a ✓ that hides a dead tap is the silent gate this capability exists to kill.
/// - **The model is ``DownloadState``-terminal** (its rule at
///   `Sources/VoccaUI/DownloadState.swift:36-50`): `committed`/`failed`/`skipped` reject their
///   ended session's stragglers, with the one amendment that a **fresh** `.downloading` is a
///   new decision (M7's "[ Download now ]", the MODEL step's retry).
/// - **TRY IT** derives its refusal from the model at the press (M7), completes **only** via a
///   real transcript (M4), and a failure keeps the step.
/// - **No time-based transition exists anywhere**: there is no clock in this function's
///   signature and no timer in the action set — a window left alone stays exactly where it is.
public enum OnboardingReducer {

    /// The pure resume entry: the state a flow folds into from the status reads — the first
    /// step whose precondition is unmet, derived deterministically and never from extra
    /// persisted step state (PRD S3).
    ///
    /// - Permissions is unmet until the Accessibility grant is **armed** and the Microphone is
    ///   granted: a `grantedNotArmed` grant is not armed — the tap is still dead until the
    ///   restart (M5c) — and a denied mic is the M2 surface the flow must not skip.
    /// - The MODEL step is unmet while no usable model decision exists: `absent` (nothing
    ///   decided), `failed` (the decision failed; the step shows retry) and `downloading`
    ///   (the decision is in flight; the step shows its progress).
    /// - A `skipped` model *is* a decision (M7's "try again" surface lives at the TRY IT
    ///   step, so a skip must be able to land there — this resolves the plan's matrix row
    ///   deliberately, see the file's tests), as is `committed`: the flow resumes at TRY IT.
    ///
    /// The completion flag cannot be derived from the three reads — only a successful
    /// dictation sets it (M4) — so the resume entry returns an uncompleted state, and the
    /// reducer's own fold preserves a completed flow (the completed case of `begin`/
    /// `windowClosed`).
    public static func initialState(
        accessibility: OnboardingAccessibility,
        microphone: OnboardingMicrophone,
        model: OnboardingModel
    ) -> OnboardingState {
        let step: OnboardingStep
        if accessibility != .armed || microphone != .granted {
            step = .permissions
        } else {
            switch model {
            case .absent, .failed, .downloading:
                step = .model
            case .committed, .skipped:
                step = .tryIt
            }
        }
        return OnboardingState(
            step: step,
            accessibility: accessibility,
            microphone: microphone,
            model: model,
            restartOffered: accessibility == .grantedNotArmed)
    }

    /// Fold one action into the state.
    public static func reduce(_ state: OnboardingState, action: OnboardingAction) -> OnboardingState {
        switch action {
        case .begin, .windowClosed:
            guard !state.completed else { return state }
            return initialState(
                accessibility: state.accessibility,
                microphone: state.microphone,
                model: state.model)

        case .accessibilityStatusChanged(let status):
            var next = state
            next.accessibility = status
            next.restartOffered = (status == .grantedNotArmed)
            return next

        case .accessibilityGrantSignal:
            return state

        case .microphoneStatusChanged(let status):
            var next = state
            next.microphone = status
            return next

        case .microphoneRequestResulted(let granted):
            var next = state
            next.microphone = granted ? .granted : .denied
            return next

        case .modelStatusChanged(let status):
            switch (state.model, status) {
            case (.committed, _),
                 (.failed, .committed), (.failed, .failed), (.failed, .skipped), (.failed, .absent),
                 (.skipped, .committed), (.skipped, .failed), (.skipped, .skipped), (.skipped, .absent):
                return state
            case (_, .downloading), (_, .committed), (_, .failed), (_, .absent), (_, .skipped):
                var next = state
                next.model = status
                next.tryItUnavailableReason = nil
                return next
            }

        case .modelDownloadCancelled:
            switch state.model {
            case .absent, .downloading:
                var next = state
                next.model = .skipped
                return next
            case .committed, .failed, .skipped:
                return state
            }

        case .tryItPressed:
            var next = state
            switch state.model {
            case .absent, .failed, .skipped:
                next.tryItUnavailableReason = .modelUnavailable
            case .committed, .downloading:
                next.tryItUnavailableReason = nil
            }
            return next

        case .tryItSucceeded(let transcript):
            guard !state.completed else { return state }
            var next = state
            next.step = .done
            next.completed = true
            next.deliveredTranscript = transcript
            next.tryItUnavailableReason = nil
            return next

        case .tryItFailed:
            var next = state
            next.tryItUnavailableReason = nil
            return next

        case .restartRequested:
            return state

        case .restartDismissed:
            var next = state
            next.restartOffered = false
            return next
        }
    }
}