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

/// The Speech-tab engine picker's session-start read (`engine-picker` Phase 4): a session
/// resolves the engine it will run **once, at start**, from the selection value that was current
/// then — the snapshot the session keeps, so a mid-session selection change can never swap the
/// engine under a running session (the never-auto-switch rule, and the "no restart needed"
/// promise: the *next* session reads the *new* selection).
///
/// The tier is a model choice, not a different engine: both Whisper tiers resolve to the same
/// identity (``EngineCandidate.whisperTurbo``). The switch is written out in full — no
/// `default:` — so a tier added to ``EngineTier`` must say which engine it belongs to here or
/// this file stops compiling (`EngineSelectionConsumptionTests` pins the table).
public enum EngineSessionStart {

    /// The engine identity a session begun with `selection` runs under.
    public static func resolve(selection: EngineSelection) -> EngineIdentity {
        switch selection.tier {
        case .parakeetV3:
            return EngineCandidate.parakeetV3.identity
        case .whisperTurbo, .whisperTurboQ5:
            return EngineCandidate.whisperTurbo.identity
        }
    }
}

/// The Speech-tab engine picker — the two radio rows with the honest tradeoff copy
/// (`PRODUCT_SPEC.md:189-196`), the per-row installed/download affordance, and the Whisper tier
/// menu.
///
/// **Thin glue, executed by nothing in CI** (the `FailsafeView`/`DownloadProgressView` shape, and
/// the window-server precedent): every decision this surface can make lives above it — the
/// reducer in ``EnginePickerStateReducer`` and the copy in ``EnginePickerCopy``, both tested
/// headlessly. This view renders ``EnginePickerState``, translates the user's intents into
/// ``EnginePickerAction``, and translates ``ModelDownloadSession`` events into the download
/// actions — nothing else.
///
/// The download affordance follows `DownloadWindow`'s wiring: the session arrives from outside
/// (``makeSession`` is the composition root's injection of ``StoreModelDownloadSession`` — a
/// `VoccaASR` type `VoccaUI` may not name), the view owns it for its lifetime, and the events
/// are fed back to the reducer as actions. Cancelling is `session.cancel()`; the stream then
/// terminates in ``ModelDownloadEvent/cancelled`` and the reducer returns the slot to idle — the
/// view never invents a state transition.
public struct EnginePickerView: View {

    /// The reducer's state — the single thing this view renders.
    public let state: EnginePickerState

    /// The funnel every user intent and every download event flows through, verbatim to the
    /// reducer (`FailsafePanel`'s pattern).
    public let onAction: (EnginePickerAction) -> Void

    /// The composition root's download-session factory: candidate → session. The only place a
    /// `StoreModelDownloadSession` may be born, and `VoccaUI` never sees the store.
    public let makeSession: (EngineCandidate) -> any ModelDownloadSession

    /// The sessions this view started and owns, keyed by engine — retained so Cancel can reach
    /// the right session, and dropped when its stream terminates.
    @State private var activeSessions: [EngineCandidate: any ModelDownloadSession] = [:]

    public init(
        state: EnginePickerState,
        onAction: @escaping (EnginePickerAction) -> Void,
        makeSession: @escaping (EngineCandidate) -> any ModelDownloadSession
    ) {
        self.state = state
        self.onAction = onAction
        self.makeSession = makeSession
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            engineRow(for: .parakeetV3)
            engineRow(for: .whisperTurbo)

            if state.selection.engine == .whisperTurbo {
                tierMenu
            }

            Text(EnginePickerCopy.modelManagementLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Rows

    /// One radio row: the spec's glyph, name and tagline on the left, the affordance on the
    /// right. The whole row is the radio — clicking anywhere on it selects the engine.
    private func engineRow(for engine: EngineCandidate) -> some View {
        Button {
            onAction(.selectEngine(EngineSelection(tier: engine.defaultTier)))
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(isSelected(engine) ? EnginePickerCopy.radioSelected : EnginePickerCopy.radioUnselected)
                    .font(.title3)
                    .foregroundStyle(isSelected(engine) ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(EnginePickerCopy.name(for: engine))
                        .font(.body)
                    Text(EnginePickerCopy.tagline(for: engine))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                affordance(for: engine)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(EnginePickerCopy.name(for: engine))
    }

    /// The row's right-hand affordance, rendered from the reducer's state only: installed wins
    /// (a committed download means the model is present); an in-flight download shows its
    /// progress and a Cancel; everything else offers the download — idle, or a fresh attempt
    /// after a failure (`EngineDownloadState/failed` rests visible, never auto-retried).
    @ViewBuilder
    private func affordance(for engine: EngineCandidate) -> some View {
        if state.installed[engine] == true {
            Text(EnginePickerCopy.installedAffordance)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if case .downloading(let fraction) = state.downloadState(for: engine) {
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .frame(width: 80)
                Button("Cancel") {
                    activeSessions[engine]?.cancel()
                }
                .font(.caption)
            }
        } else {
            Button(EnginePickerCopy.downloadAffordance) {
                startDownload(engine)
            }
            .font(.caption)
        }
    }

    private func isSelected(_ engine: EngineCandidate) -> Bool {
        state.selection.engine == engine
    }

    // MARK: - The whisper tier menu

    /// The tier menu, rendered only for the selected engine (Parakeet ships one tier — nothing to
    /// choose). The options are `validTiers(for:)`'s answer for the selected engine; the
    /// selection binding sends ``EnginePickerAction/selectTier(_:)`` and reads the reducer's
    /// state back, so a refused change (foreign tier, or a download in flight) never sticks.
    private var tierMenu: some View {
        HStack(spacing: 8) {
            Text("Model")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(
                "Model",
                selection: Binding(
                    get: { state.selection.tier },
                    set: { onAction(.selectTier($0)) }
                )
            ) {
                ForEach(validTiers(for: state.selection.engine), id: \.self) { tier in
                    Text(EnginePickerCopy.tierLabel(for: tier)).tag(tier)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    // MARK: - The download affordance's wiring

    /// Starts the injected session for `engine` and feeds its events back to the reducer as
    /// actions. One session per engine at a time (the slot guard mirrors the reducer's own:
    /// a download already in flight is not started twice). The view owns the session for its
    /// lifetime and drops it when the stream terminates.
    private func startDownload(_ engine: EngineCandidate) {
        guard activeSessions[engine] == nil else { return }
        let session = makeSession(engine)
        activeSessions[engine] = session
        onAction(.downloadStarted(engine))
        Task {
            for await event in await session.events {
                switch event {
                case .progress(let fraction):
                    onAction(.downloadProgress(engine, fraction))
                case .committed:
                    onAction(.downloadCommitted(engine))
                case .failed(let reason):
                    onAction(.downloadFailed(engine))
                case .cancelled:
                    onAction(.downloadCancelled(engine))
                }
            }
            activeSessions[engine] = nil
        }
        Task { await session.start() }
    }
}

extension EnginePickerCopy {

    /// The row's name from the candidate — the spec's two names, by engine.
    static func name(for engine: EngineCandidate) -> String {
        switch engine {
        case .parakeetV3: return parakeetName
        case .whisperTurbo: return whisperName
        }
    }

    /// The row's tagline from the candidate — the honest tradeoff, by engine.
    static func tagline(for engine: EngineCandidate) -> String {
        switch engine {
        case .parakeetV3: return parakeetTagline
        case .whisperTurbo: return whisperTagline
        }
    }
}
