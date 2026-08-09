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

import Foundation
import VoccaCore

/// One engine's download slot in the picker — the `ModelDownloadSession` vocabulary as the row
/// renders it.
///
/// `.cancelled` is deliberately **not** a resting state: the downloadCancelled action returns the
/// slot to ``EngineDownloadState/idle`` (`EnginePickerStateReducerTests` row 5e), so a cancelled
/// engine can immediately be offered a fresh download. That diverges from the one-shot download
/// window's terminal `DownloadState.skipped` on purpose — the picker is a persistent settings
/// surface, not a one-shot window, and the never-auto-switch rule is about the selection, not
/// about locking a row after a user cancels.
public enum EngineDownloadState: Equatable, Sendable {
    /// Nothing in flight and nothing to show — the resting state.
    case idle
    /// A download is in flight; the payload is the aggregate fraction of all bytes written so
    /// far, clamped into 0...1 and never regressing.
    case downloading(Double)
    /// Every file downloaded, verified and committed — the model is present.
    case committed
    /// The last download failed — idle except the flag, so the row can offer a fresh attempt.
    case failed
}

/// The engine picker's state, driven by the user's intents and the injected download/installed
/// answers — a pure reducer, so the whole UI decision table runs headlessly
/// (`EnginePickerStateReducerTests`); the picker view is thin glue over this type.
///
/// The state carries the ``selection`` (the answer a session reads at start), each engine's
/// download slot, and the installed flags. **The installed flags are never probed by the
/// reducer**: they arrive as the store's `isPresent` answer via
/// ``EnginePickerAction/installedState(_:)`` (`ModelStore.isPresent(engineID:version:)` is a
/// `VoccaASR` call, unreachable from `VoccaUI` by the module-boundary rule), so a state with an
/// empty ``installed`` dictionary is a state with no claim one way or the other — the honest
/// rendering of "the store has not answered yet".
public struct EnginePickerState: Equatable, Sendable {
    /// The current selection — the only slot download events may never touch (never-auto-switch).
    public var selection: EngineSelection

    /// Each engine's download slot, seeded all-``EngineDownloadState/idle`` over the closed
    /// candidate set.
    public var downloads: [EngineCandidate: EngineDownloadState]

    /// Which engines are installed, keyed by candidate. An engine absent from this dictionary has
    /// no installed claim — supplied by the store, never probed.
    public var installed: [EngineCandidate: Bool]

    /// The resting state: the shipped default selection, every download slot idle, and no
    /// installed claim until the store answers.
    public init(
        selection: EngineSelection = .defaultSelection,
        installed: [EngineCandidate: Bool] = [:]
    ) {
        self.selection = selection
        self.downloads = Dictionary(
            uniqueKeysWithValues: EngineCandidate.allCases.map { ($0, .idle) })
        self.installed = installed
    }

    /// The download slot for `engine`, `.idle` when no slot is recorded — total over the closed
    /// candidate set, so the reducer never special-cases a missing key.
    public func downloadState(for engine: EngineCandidate) -> EngineDownloadState {
        downloads[engine] ?? .idle
    }
}

/// The intents and injected answers the picker offers the reducer.
///
/// **The set is closed** — there is no store call and no I/O in it, and nothing but the user's
/// explicit ``EnginePickerAction/selectEngine(_:)`` can change ``EnginePickerState/selection``:
/// every download action names the engine it happened to, and the reducer's exhaustive switch
/// cannot hide a transition no action can carry. That is the structural pin on never-auto-switch.
public enum EnginePickerAction: Equatable, Sendable {
    /// The user picked an engine (a radio row). The payload's *engine* is the message; the tier
    /// resets to that engine's default via `EngineSelection.selecting(engine:)` — the payload
    /// tier is never carried across (there is no foreign tier to inherit).
    case selectEngine(EngineSelection)
    /// The user picked a tier for the current engine. Refused (a no-op) when the tier is foreign
    /// to the selected engine (`validTiers(for:)`) or the selected engine is downloading (the
    /// plan's decided rule: refused, not queued).
    case selectTier(EngineTier)
    /// The download session for `engine` started — the slot goes to `.downloading(0)`.
    case downloadStarted(EngineCandidate)
    /// The download session for `engine` reported the aggregate fraction of all bytes written so
    /// far, 0...1. Applied only when that engine is downloading.
    case downloadProgress(EngineCandidate, Double)
    /// The download session for `engine` committed — every file verified on disk, so the engine
    /// also counts as installed.
    case downloadCommitted(EngineCandidate)
    /// The download session for `engine` failed — the slot rests ``EngineDownloadState/failed``.
    case downloadFailed(EngineCandidate)
    /// The download session for `engine` was cancelled by the user — the slot returns to idle,
    /// free for a fresh attempt.
    case downloadCancelled(EngineCandidate)
    /// The store's installed-state answer: engine id (``EngineCandidate/id``) → present. Unknown
    /// ids are dropped — the candidate set is closed. Touches ``EnginePickerState/installed``
    /// only; injected, never probed.
    case installedState([String: Bool])
}

/// The transition table: every action × state rule the picker obeys.
///
/// - ``EnginePickerAction/selectEngine(_:)`` is the *only* action that moves
///   ``EnginePickerState/selection``, and it is always the user's explicit intent; every
///   download event and every installed-state answer leaves the selection exactly where it was
///   (never-auto-switch, row 4 of the decision table).
/// - A tier change is refused unless the tier belongs to the selected engine **and** the
///   selected engine is not downloading — both refusals are pure no-ops (rows 3 and 6).
/// - Progress is clamped into 0...1 and never regresses (the store's own aggregate is monotonic
///   by construction; the reducer defends the bar against anything else), and applies only to
///   the engine that is actually downloading — it never starts an idle slot (row 5b).
/// - ``EnginePickerAction/downloadCommitted(_:)`` also sets the engine's installed flag: a
///   committed download means the model is present (`ModelDownloadEvent.committed`). Failed and
///   cancelled downloads never claim installed and never clear it — the store's answer, not the
///   reducer's guess, is the truth for "not installed".
/// - ``EnginePickerAction/downloadCancelled(_:)`` returns the slot to idle — the picker is a
///   persistent settings surface, so a cancelled engine must be offered a fresh download, unlike
///   the one-shot window's terminal `DownloadState.skipped` (row 5e).
public enum EnginePickerStateReducer {

    public static func reduce(
        _ state: EnginePickerState,
        action: EnginePickerAction
    ) -> EnginePickerState {
        switch action {
        case .selectEngine(let selection):
            var next = state
            next.selection = selection.selecting(engine: selection.engine)
            return next

        case .selectTier(let tier):
            guard validTiers(for: state.selection.engine).contains(tier) else { return state }
            guard case .downloading = state.downloadState(for: state.selection.engine) else {
                var next = state
                next.selection = EngineSelection(tier: tier)
                return next
            }
            return state

        case .downloadStarted(let engine):
            var next = state
            next.downloads[engine] = .downloading(0)
            return next

        case .downloadProgress(let engine, let fraction):
            guard case .downloading(let current) = state.downloadState(for: engine) else {
                return state
            }
            var next = state
            next.downloads[engine] = .downloading(max(current, min(1, max(0, fraction))))
            return next

        case .downloadCommitted(let engine):
            var next = state
            next.downloads[engine] = .committed
            next.installed[engine] = true
            return next

        case .downloadFailed(let engine):
            var next = state
            next.downloads[engine] = .failed
            return next

        case .downloadCancelled(let engine):
            var next = state
            next.downloads[engine] = .idle
            return next

        case .installedState(let flags):
            var next = state
            for candidate in EngineCandidate.allCases {
                if let present = flags[candidate.id] {
                    next.installed[candidate] = present
                }
            }
            return next
        }
    }
}
