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

/// What the model store answered about one tier, at the moment the tab asked.
///
/// Carried in rather than looked up: `ModelStore` lives in `VoccaASR` and this module may import
/// only `VoccaCore` (`ModuleBoundaryTests`). The wiring asks; the reducer folds the answer. It is
/// also what makes the whole tab testable with no store, no disk and no window server.
public struct SpeechTabTierSnapshot: Sendable, Equatable {
    /// The tier the answer is about.
    public let tier: EngineTier
    /// `ModelStore.isPresent(tier:version:)` — present **and** verified, never "a directory
    /// exists".
    public let isPresent: Bool
    /// `ModelStore.bytesOnDisk(tier:version:)` — `0` when the tier is not there.
    public let bytesOnDisk: Int

    public init(tier: EngineTier, isPresent: Bool, bytesOnDisk: Int) {
        self.tier = tier
        self.isPresent = isPresent
        self.bytesOnDisk = bytesOnDisk
    }
}

/// What a row's affordance says: `PRODUCT_SPEC.md:254-262`'s `[ installed ]` / `[ download ]`,
/// plus the two states a spec mock cannot draw.
///
/// ``unknown`` exists so that "the store has not answered yet" is not rendered as either badge.
/// A tab that claimed `[ download ]` for a model already on disk would offer 470 MB of pointless
/// transfer; one that claimed `[ installed ]` for a model that is not there would be the
/// `LSUIElement` failure again — a state that looks like working.
public enum SpeechTabInstall: Sendable, Equatable {
    /// The store has not answered about this tier. Neither badge is shown.
    case unknown
    /// Present and verified.
    case installed
    /// Not there, and nothing in flight.
    case absent
    /// A download for this tier is running; the payload is the aggregate byte fraction, 0...1.
    case downloading(Double)
    /// The last download for this tier failed. Idle except the flag, so a fresh attempt is one
    /// click away — the `EngineDownloadState.failed` shape.
    case failed
}

/// **What the Speech tab says about the engine the user has selected** — one of the three
/// renderings `spec.md` R6 requires to agree.
///
/// Four answers rather than the readiness gate's three, because a download is a wait with a number
/// on it and a warm-up is a wait without one, and a user reading a settings page can act on the
/// difference. The mapping from the gate's ``EngineReadinessState`` is total and lives in one
/// place (``SpeechTabReducer/engineStatus(readiness:selection:downloads:)``), so this cannot drift
/// from what the menu bar and the next press report.
public enum SpeechTabEngineStatus: Sendable, Equatable {
    /// The selected engine is prepared; a press opens the microphone.
    case ready
    /// Its `prepare()` is running. A press is refused, and waiting is the remedy.
    case preparing
    /// Its model is arriving, this far along. A press is refused, and waiting is the remedy.
    case downloading(Double)
    /// Nothing is in flight and the engine cannot transcribe — a removed model, or a preparation
    /// that failed. A press is refused, and waiting is **not** the remedy, which is the whole
    /// reason this is not the same case as the two above.
    case unavailable
}

/// One row of the Speech tab: one **tier**, not one engine.
///
/// The spec's mock draws one row per engine because each engine had one tier when it was written.
/// Whisper has two, and they are two artifacts of very different sizes — so the row, the badge,
/// the disk figure and the [Remove] button are all per tier. That is also the only shape in which
/// aspect 1's keying fix is visible to a user.
public struct SpeechTabRow: Sendable, Equatable, Identifiable {
    /// The tier this row is about — and the row's identity.
    public let tier: EngineTier
    /// The engine the tier belongs to, derived, never stored separately.
    public var engine: EngineCandidate { tier.engine }
    /// Whether this tier is the current selection.
    public let isSelected: Bool
    /// What the affordance says.
    public let install: SpeechTabInstall
    /// How many bytes this tier occupies. `0` when it is not on disk.
    public let bytesOnDisk: Int

    public var id: EngineTier { tier }

    public init(tier: EngineTier, isSelected: Bool, install: SpeechTabInstall, bytesOnDisk: Int) {
        self.tier = tier
        self.isSelected = isSelected
        self.install = install
        self.bytesOnDisk = bytesOnDisk
    }
}

/// What the Speech tab is showing.
public struct SpeechTabState: Sendable, Equatable {
    /// The chosen engine and tier — the answer the next session reads.
    public var selection: EngineSelection
    /// The store's presence answers, keyed by tier. A tier absent from this dictionary has no
    /// claim either way, which is what ``SpeechTabInstall/unknown`` renders.
    public var presence: [EngineTier: Bool]
    /// The store's disk figures, keyed by tier.
    public var bytes: [EngineTier: Int]
    /// Downloads in flight, keyed by tier. A tier absent from this dictionary has nothing running.
    public var downloads: [EngineTier: SpeechTabInstall]
    /// The rows, derived from everything above, in the spec's order.
    public var rows: [SpeechTabRow]
    /// The last thing that went wrong, in words. `nil` once something succeeds.
    public var errorMessage: String?
    /// The readiness gate's answer, as the root reports it. Injected, never inferred: the gate is
    /// the single fact all three surfaces read, and a tab that guessed at it from its own download
    /// slots would be the second source of truth R6 exists to prevent.
    public var readiness: EngineReadinessState

    /// The state the window opens in: the shipped default selection and no claim about any tier.
    public static let initial = SpeechTabState(selection: .defaultSelection)

    public init(selection: EngineSelection) {
        self.selection = selection
        self.presence = [:]
        self.bytes = [:]
        self.downloads = [:]
        self.errorMessage = nil
        self.readiness = .unavailable
        self.rows = SpeechTabReducer.rows(
            selection: selection, presence: [:], bytes: [:], downloads: [:])
    }

    /// What the tab says about the selected engine — the R6 rendering.
    public var engineStatus: SpeechTabEngineStatus {
        SpeechTabReducer.engineStatus(
            readiness: readiness, selection: selection, downloads: downloads)
    }

    /// The row for a tier, or `nil` — total over ``EngineTier/allCases`` in practice, but spelled
    /// as an optional rather than force-unwrapped: a crash in a settings page is a poor way to
    /// learn that the tier set moved.
    public func row(for tier: EngineTier) -> SpeechTabRow? {
        rows.first { $0.tier == tier }
    }
}

/// Everything that can happen to the Speech tab. A closed set, folded exhaustively, with no
/// time-based transition in it — the `AppsTabAction` discipline: nothing here changes while a
/// user is reading it.
///
/// **The selection can be moved by exactly two of these**, and both are the user's own gesture.
/// Every download action names the tier it happened to, so the reducer's exhaustive switch cannot
/// hide a transition no action can carry — the structural half of never-auto-switch, exactly as
/// `EnginePickerAction` argues it.
public enum SpeechTabAction: Sendable, Equatable {
    /// The store was asked about every tier; these are its answers.
    case snapshotLoaded([SpeechTabTierSnapshot])
    /// The user picked an engine (a radio row). The selection lands on that engine's default
    /// tier — `EngineSelection.selecting(engine:)`, never re-implemented here.
    case selectEngine(EngineCandidate)
    /// The user picked a tier. Allowed during a download, unlike the standalone picker's rule:
    /// see ``SpeechTabReducer``.
    case selectTier(EngineTier)
    /// A download for this tier started.
    case downloadStarted(EngineTier)
    /// A download for this tier reported the aggregate fraction of all bytes written, 0...1.
    case downloadProgress(EngineTier, Double)
    /// A download for this tier committed: every file verified on disk, so the tier is present
    /// and occupies the reported bytes.
    case downloadCommitted(EngineTier, bytesOnDisk: Int)
    /// A download for this tier failed.
    case downloadFailed(EngineTier)
    /// A download for this tier was cancelled — by the user's Stop, or by a removal that had to
    /// clear the way (M12). The row returns to the store's own answer.
    case downloadCancelled(EngineTier)
    /// The store deleted this tier's version directory and its verified marker.
    case removalCompleted(EngineTier)
    /// The store could not delete it, in the store's own words.
    case removalFailed(EngineTier, String)
    /// The root's readiness gate moved. The tab reports it; it never decides it.
    case engineStatusChanged(EngineReadinessState)
}

/// The Speech tab's decisions — pure, clock-free, and holding no store of its own.
public enum SpeechTabReducer {

    public static func reduce(_ state: SpeechTabState, _ action: SpeechTabAction) -> SpeechTabState
    {
        var next = state
        switch action {
        case .snapshotLoaded(let snapshots):
            for snapshot in snapshots {
                next.presence[snapshot.tier] = snapshot.isPresent
                next.bytes[snapshot.tier] = snapshot.bytesOnDisk
            }

        case .selectEngine(let engine):
            next.selection = next.selection.selecting(engine: engine)

        case .selectTier(let tier):
            next.selection = EngineSelection(tier: tier)

        case .downloadStarted(let tier):
            next.downloads[tier] = .downloading(0)

        case .downloadProgress(let tier, let fraction):
            // Applies only to a tier that is actually downloading, so progress never starts an
            // idle row and never reopens a terminal one; clamped and monotonic, because a bar
            // that went backwards would be reporting the transport's bookkeeping as a fact.
            guard case .downloading(let current) = next.downloads[tier] else { break }
            next.downloads[tier] = .downloading(max(current, min(1, max(0, fraction))))

        case .downloadCommitted(let tier, let bytesOnDisk):
            // The row leaves the download vocabulary entirely: a committed download is a present
            // model, and presence is what the badge should read from afterwards. Recording it as
            // presence rather than as a terminal download state is what lets a re-download start
            // from the same row without a reset.
            next.downloads[tier] = nil
            next.presence[tier] = true
            next.bytes[tier] = bytesOnDisk

        case .downloadFailed(let tier):
            next.downloads[tier] = .failed

        case .downloadCancelled(let tier):
            // Back to whatever the store last said — not to `absent`. A cancelled download keeps
            // its `.part` files and the model may well have been there all along.
            next.downloads[tier] = nil

        case .removalCompleted(let tier):
            next.presence[tier] = false
            next.bytes[tier] = 0
            next.downloads[tier] = nil
            next.errorMessage = nil

        case .engineStatusChanged(let readiness):
            next.readiness = readiness

        case .removalFailed(_, let message):
            // Nothing about the tier moves. The model is still on disk, so the row that says so
            // is the accurate one; only the failure is new.
            next.errorMessage = SpeechTabCopy.removalFailed(message)
        }
        next.rows = rows(
            selection: next.selection, presence: next.presence, bytes: next.bytes,
            downloads: next.downloads)
        return next
    }

    /// The selected engine's status: the gate's answer, with a download of **that tier** taking
    /// precedence over a warm-up.
    ///
    /// The precedence is the menu bar's own, deliberately (`MenuBarStateReducer`: "A download
    /// outranks a warm-up: it is the far longer wait and the one with progress worth showing").
    /// Copying its reasoning rather than inventing a second one is what makes the two surfaces
    /// agree by construction instead of by coincidence.
    ///
    /// A download of a tier the user has **not** selected changes nothing here, and that is the
    /// half a naive wiring gets wrong: fetching Whisper in the background while dictating with
    /// Parakeet blocks nothing, and a page saying otherwise would report five minutes of
    /// unavailability that never happened.
    static func engineStatus(
        readiness: EngineReadinessState,
        selection: EngineSelection,
        downloads: [EngineTier: SpeechTabInstall]
    ) -> SpeechTabEngineStatus {
        if case .downloading(let fraction) = downloads[selection.tier] {
            return .downloading(fraction)
        }
        switch readiness {
        case .ready: return .ready
        case .preparing: return .preparing
        case .unavailable: return .unavailable
        }
    }

    /// The rows a fact set produces — one per tier, in ``EngineTier/allCases`` order, which is the
    /// spec's order (Parakeet first, then Whisper's tiers). Order is fixed rather than sorted: a
    /// settings list whose rows moved between openings looks like the data changed.
    static func rows(
        selection: EngineSelection,
        presence: [EngineTier: Bool],
        bytes: [EngineTier: Int],
        downloads: [EngineTier: SpeechTabInstall]
    ) -> [SpeechTabRow] {
        EngineTier.allCases.map { tier in
            SpeechTabRow(
                tier: tier,
                isSelected: selection.tier == tier,
                install: install(for: tier, presence: presence, downloads: downloads),
                bytesOnDisk: bytes[tier] ?? 0)
        }
    }

    /// A tier's affordance. A download in flight (or a failure) outranks the presence answer,
    /// because it is the newer fact about the same tier — and because presence is only re-read
    /// when the page asks, which is not during a transfer.
    private static func install(
        for tier: EngineTier,
        presence: [EngineTier: Bool],
        downloads: [EngineTier: SpeechTabInstall]
    ) -> SpeechTabInstall {
        if let inFlight = downloads[tier] { return inFlight }
        guard let isPresent = presence[tier] else { return .unknown }
        return isPresent ? .installed : .absent
    }
}
