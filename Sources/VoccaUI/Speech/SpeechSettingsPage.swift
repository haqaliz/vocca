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

/// **The Speech tab** (`PRODUCT_SPEC.md:254-262`): which engine transcribes, which tier of it, and
/// the model management the spec's own line promises — disk used, remove, re-download.
///
/// Thin glue over ``SpeechTabReducer`` — the ``AppsSettingsPage`` split. Every gesture folds an
/// action and, where the world must move with it, drives the binding that moves it; the outcome
/// folds back. Nothing is decided here.
///
/// **Executed by nothing in CI** (the window-server rule). Every decision it renders is tested in
/// `SpeechTabReducerTests`, every word in `SpeechTabCopyTests`, and the agreement between this
/// page, the menu bar and the pill in `EngineStateAgreementTests`. Its first execution is
/// `SMOKE_CHECKLIST.md` §13.
struct SpeechSettingsPage: View {

    let bindings: SettingsBindings

    @State private var state = SpeechTabState.initial
    /// The download sessions in flight, one per tier — the `ModelStep`'s slot guard, per row.
    @State private var sessions: [EngineTier: any ModelDownloadSession] = [:]
    var body: some View {
        Form {
            Section("Engine") {
                ForEach(EngineCandidate.allCases, id: \.self) { engine in
                    engineRow(engine)
                }
            }

            Section(EnginePickerCopy.modelManagementLine) {
                ForEach(state.rows) { row in
                    tierRow(row)
                }
                if let errorMessage = state.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    // MARK: - The engine rows (`PRODUCT_SPEC.md:254-256`)

    /// One engine: the radio, the spec's tagline, and — the R7 half — what Vocca has actually run
    /// through it. Shape and text carry the selection; the glyph is the spec's own.
    private func engineRow(_ engine: EngineCandidate) -> some View {
        let isSelected = state.selection.engine == engine
        return Button {
            apply(.selectEngine(engine))
            bindings.setEngineSelection(state.selection.selecting(engine: engine))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(
                    isSelected
                        ? EnginePickerCopy.radioSelected : EnginePickerCopy.radioUnselected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine == .parakeetV3 ? EnginePickerCopy.parakeetName : EnginePickerCopy.whisperName)
                    Text(
                        engine == .parakeetV3
                            ? EnginePickerCopy.parakeetTagline : EnginePickerCopy.whisperTagline
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(SpeechTabCopy.engineStatus(for: engine))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - The tier rows: the badge, the bytes, the controls

    /// One tier: what the store says about it, how much disk it takes, and the one control its
    /// state permits. The tier picker is here rather than in the engine row because a tier *is* a
    /// row — the two Whisper tiers are two artifacts, which is the whole of aspect 1.
    @ViewBuilder
    private func tierRow(_ row: SpeechTabRow) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                switch row.install {
                case .unknown:
                    EmptyView()
                case .installed:
                    Text(EnginePickerCopy.installedAffordance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .absent:
                    Text(EnginePickerCopy.downloadAffordance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(SpeechTabCopy.downloadButton) { startDownload(of: row.tier) }
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 90)
                    Button(SpeechTabCopy.stopDownloadButton) { cancelDownload(of: row.tier) }
                case .failed:
                    Button(SpeechTabCopy.redownloadButton) { startDownload(of: row.tier) }
                }
            }
        } label: {
            Button {
                apply(.selectTier(row.tier))
                bindings.setEngineSelection(EngineSelection(tier: row.tier))
            } label: {
                Text(SpeechTabCopy.name(for: row.tier))
                    .fontWeight(row.isSelected ? .semibold : .regular)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - The gestures

    /// Reads the world into the tab: the store's answers and the root's readiness, in that order,
    /// so the page opens describing what is rather than what was.
    private func load() async {
        apply(.snapshotLoaded(await bindings.modelSnapshot()))
        apply(.engineStatusChanged(bindings.engineReadiness()))
    }

    /// [Download] / [Re-download] — one session per tier, its events folded through the reducer,
    /// its running-ness reported to the root so the other surfaces can describe the wait.
    private func startDownload(of tier: EngineTier) {
        guard sessions[tier] == nil, let session = bindings.makeDownloadSession(tier) else { return }
        sessions[tier] = session
        apply(.downloadStarted(tier))
        bindings.downloadActivityChanged(tier, true)
        Task { await session.start() }
        Task {
            for await event in session.events {
                switch event {
                case .progress(let fraction):
                    apply(.downloadProgress(tier, fraction))
                case .committed:
                    apply(.downloadCommitted(tier, bytesOnDisk: bytesOnDisk(of: tier)))
                case .failed:
                    apply(.downloadFailed(tier))
                case .cancelled:
                    apply(.downloadCancelled(tier))
                }
            }
            sessions[tier] = nil
            bindings.downloadActivityChanged(tier, false)
            // The store is the truth about what landed; the events only said what happened.
            apply(.snapshotLoaded(await bindings.modelSnapshot()))
            apply(.engineStatusChanged(bindings.engineReadiness()))
        }
    }

    private func cancelDownload(of tier: EngineTier) {
        sessions[tier]?.cancel()
    }

    /// The bytes a committed download left behind, read back from the store rather than summed
    /// from the manifest — the row's figure and the directory it offers to delete are the same
    /// number. `0` until the re-read below lands, which is one turn away.
    private func bytesOnDisk(of tier: EngineTier) -> Int {
        state.bytes[tier] ?? 0
    }

    private func apply(_ action: SpeechTabAction) {
        state = SpeechTabReducer.reduce(state, action)
    }
}
