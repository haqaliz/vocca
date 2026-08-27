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

import SwiftUI
import VoccaCore

/// The five-step onboarding surface (`PRODUCT_SPEC.md:211-242`): WELCOME → PERMISSIONS → MODEL →
/// TRY IT → DONE, rendered from ``OnboardingState`` over the ``OnboardingStore``.
///
/// **Thin glue, executed by nothing in CI** (the ``FailsafeView``/`EnginePickerView` shape, and
/// the window-server precedent): every decision this surface can make lives above it — the
/// reducer's table (`OnboardingReducerTests`), the store's fold and advance
/// (`OnboardingStoreTests`), and the window's routing (`OnboardingWindowContractTests`). What is
/// here is the step rendering and the translation of the user's intents into
/// ``OnboardingAction`` folds and ``OnboardingBindings`` calls — nothing else.
///
/// **The view renders ``OnboardingCopy`` strings only**: every user-visible string comes from
/// the pinned copy enum (G3, byte-for-byte against §6); the pane/request affordances are
/// icon-only (the spec names the direct buttons but no wording for them), the progress
/// percentage is data, and the symbols are system images.
///
/// The MODEL step is the download machinery's first real caller: it consumes
/// ``ModelDownloadSession`` events the ``EnginePickerView`` way — folding each through the
/// shipped ``DownloadStateReducer`` for the bar and through the store as
/// ``OnboardingAction/modelStatusChanged(_:)`` — and Skip routes
/// ``OnboardingAction/modelDownloadCancelled`` plus `cancel()`. The download is user-initiated
/// only: it starts when the step renders (the user navigated here — the step *is* the
/// download), never from `configure` or `main` (M9), and the [ Download now ] affordance
/// (M7) re-enters the step's download as a fresh decision.
public struct OnboardingView: View {

    private let bindings: OnboardingBindings
    private let onRestart: () -> Void

    @ObservedObject private var store: OnboardingStore
    @ObservedObject private var field: OnboardingFieldModel

    public init(
        store: OnboardingStore,
        bindings: OnboardingBindings,
        field: OnboardingFieldModel,
        onRestart: @escaping () -> Void
    ) {
        self.store = store
        self.bindings = bindings
        self.field = field
        self.onRestart = onRestart
    }

    public var body: some View {
        Group {
            switch store.state.step {
            case .welcome: welcomeStep
            case .permissions: permissionsStep
            case .model: ModelStep(store: store, bindings: bindings)
            case .tryIt: tryItStep
            case .done: doneStep
            }
        }
        .frame(width: 460, height: 300)
        .padding(24)
    }

    // MARK: - WELCOME (`PRODUCT_SPEC.md:212-215`)

    private var welcomeStep: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(OnboardingCopy.welcomeTitle)
                .font(.title2)
                .multilineTextAlignment(.center)
            Text(OnboardingCopy.welcomeBody)
                .foregroundStyle(.secondary)
            Spacer()
            Button(OnboardingCopy.getStarted) {
                store.fold(.begin)
            }
        }
    }

    // MARK: - PERMISSIONS (`PRODUCT_SPEC.md:217-230`)

    /// The two permission rows, one at a time: Accessibility first — the one genuinely fatal
    /// permission — then, only once it is **armed**, the Microphone row (M5c's "one at a time,
    /// never a wall of dialogs"). The mic request fires when the row appears (M5b: the flow
    /// presents the prompts itself, at the moment it controls).
    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            accessibilityRow
            if store.state.accessibility == .armed {
                microphoneRow
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    /// The Accessibility row — the M5c three states, rendered as three distinct surfaces: ✗ with
    /// the pane button (its prompt) when not granted; ✓ with the "granted, restart to arm" line
    /// and the [ Restart Vocca ] offer when granted but deaf — a ✓ that hides a dead tap is the
    /// silent gate this capability exists to kill; ✓ when armed.
    private var accessibilityRow: some View {
        HStack(alignment: .top, spacing: 10) {
            statusMark(granted: store.state.accessibility != .notGranted)
            VStack(alignment: .leading, spacing: 4) {
                Text(OnboardingCopy.accessibilityReason)
                if store.state.accessibility == .grantedNotArmed {
                    Text(OnboardingCopy.accessibilityGrantedNotArmed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if store.state.accessibility == .grantedNotArmed {
                    Button(OnboardingCopy.restartVocca) {
                        onRestart()
                    }
                    .font(.callout)
                }
            }
            Spacer()
            if store.state.accessibility == .notGranted {
                paneButton(bindings.openAccessibilityPane)
            }
        }
    }

    /// The Microphone row — shown only once Accessibility is armed (one at a time). The request
    /// fires on appear while undecided (M5b); a denial shows the pane button — the exact toggle
    /// the M2 denial surface names.
    private var microphoneRow: some View {
        HStack(alignment: .top, spacing: 10) {
            statusMark(granted: store.state.microphone == .granted)
            Text(OnboardingCopy.microphoneReason)
            Spacer()
            if store.state.microphone == .denied {
                paneButton(bindings.openMicrophonePane)
            }
        }
        .onAppear {
            if store.state.microphone == .notDetermined {
                bindings.requestMicrophoneAccess()
            }
        }
    }

    // MARK: - TRY IT and DONE (`PRODUCT_SPEC.md:237-242`)

    /// TRY IT: the live field the real dictation's transcript lands in (M6 — the window's
    /// delivery sink appends here), and the M7 model-unavailable surface: when the MODEL step
    /// was skipped and no model is installed, the honest refusal with [ Download now ] — never
    /// a dead end, never an auto-download. The refusal is derived on the step's appearance (the
    /// flow's "press": ``OnboardingAction/tryItPressed``), so the surface is present the moment
    /// the step is.
    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OnboardingCopy.tryItPrompt)
            TextField("", text: $field.text)
                .textFieldStyle(.roundedBorder)
            if store.state.tryItUnavailableReason == .modelUnavailable {
                Text(OnboardingCopy.tryItModelUnavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(OnboardingCopy.downloadNow) {
                    // A fresh decision (M7): the reducer accepts a fresh `.downloading` from the
                    // terminal skip, and the advance rule moves the flow back to the MODEL step,
                    // whose machinery starts the session.
                    store.fold(.modelStatusChanged(.downloading(0)))
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .onAppear {
            store.fold(.tryItPressed)
        }
    }

    /// DONE (`PRODUCT_SPEC.md:241-242`): the completion surface. The window stays up for the
    /// user to read and close; the menu bar's "Welcome…" item reopens it.
    private var doneStep: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(OnboardingCopy.doneCopy)
                .font(.title3)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - The row chrome

    /// The live ✓/✗ — shape carries the state (a checkmark or a cross, never colour alone).
    private func statusMark(granted: Bool) -> some View {
        Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
            .font(.title3)
            .foregroundStyle(granted ? Color.green : Color.secondary)
    }

    /// The direct pane button — icon-only (the spec names the affordance, not its wording; the
    /// copy enum stays the only user-visible strings).
    private func paneButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up.forward.app")
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - The MODEL step (`PRODUCT_SPEC.md:232-236`)

/// The download step — the shipped download machinery's first real caller: the session comes
/// from the injected ``OnboardingBindings/makeDownloadSession`` (the root's
/// ``StoreModelDownloadSession``), events fold through the shipped ``DownloadStateReducer`` for
/// the bar and through the store for the flow, Skip routes
/// ``OnboardingAction/modelDownloadCancelled`` plus `cancel()`. The download starts when the
/// step renders — user-initiated by being on the download step; never on a CI path (the window
/// is never constructed by `configure` or `main`).
private struct ModelStep: View {

    @ObservedObject var store: OnboardingStore
    let bindings: OnboardingBindings

    /// The in-flight session the view owns — one at a time (`EnginePickerView`'s slot guard).
    @State private var session: (any ModelDownloadSession)?
    /// The bar's state, reduced from the session's events by the shipped reducer.
    @State private var download: DownloadState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OnboardingCopy.modelTitle)
                .font(.headline)
            if case .downloading(let fraction) = download {
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .failed = download {
                Button(OnboardingCopy.downloadNow) {
                    // The retry is a fresh decision, exactly like M7's [ Download now ].
                    store.fold(.modelStatusChanged(.downloading(0)))
                    startDownload()
                }
            }
            HStack {
                Spacer()
                Button(OnboardingCopy.skipForNow) {
                    store.fold(.modelDownloadCancelled)
                    session?.cancel()
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .task {
            startIfNeeded()
        }
    }

    /// Starts the download when the step has no usable model decision — absent (nothing
    /// decided), downloading (a resumed decision — `start()` resumes from the `.part` files),
    /// failed (the retry). Never for a committed or skipped model: those are decisions.
    private func startIfNeeded() {
        guard store.state.model != .committed, store.state.model != .skipped else { return }
        startDownload()
    }

    /// Starts the injected session and consumes its events: one session per mount, the bar
    /// reduced through the shipped ``DownloadStateReducer``, the flow folded through the store.
    private func startDownload() {
        guard session == nil, let newSession = bindings.makeDownloadSession() else { return }
        session = newSession
        Task { await newSession.start() }
        Task {
            for await event in newSession.events {
                download = DownloadStateReducer.reduce(download, event: event)
                store.fold(modelStatus(for: event))
            }
            session = nil
        }
    }

    /// One event → the store's action — `.cancelled` is the skip's own action (the reducer's
    /// terminal), everything else a fresh model status.
    private func modelStatus(for event: ModelDownloadEvent) -> OnboardingAction {
        switch event {
        case .progress(let fraction):
            return .modelStatusChanged(.downloading(fraction))
        case .committed:
            return .modelStatusChanged(.committed)
        case .failed:
            return .modelStatusChanged(.failed)
        case .cancelled:
            return .modelDownloadCancelled
        }
    }
}