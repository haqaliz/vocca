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

/// The engine picker's decision table (`engine-picker` Phase 2, the `FailsafeStateReducerTests`
/// pattern): selection change, tier change, download lifecycle and installed state, pinned
/// headlessly. The picker view is thin glue over this reducer ("executed by nothing in CI" —
/// window-server precedent), so this table is the decision.
///
/// The reducer is **pure**: installed state arrives via ``EnginePickerAction/installedState(_:)``,
/// never probed by the reducer — there is no store call, no I/O and no clock. The one structural
/// invariant is **never-auto-switch**: the action set is closed, and over that closed set no
/// download event and no installed-state answer can change ``EnginePickerState/selection`` — the
/// exhaustive switch in ``EnginePickerStateReducer`` cannot hide a transition no action can carry.
final class EnginePickerStateReducerTests: XCTestCase {

    private func reduce(
        _ actions: [EnginePickerAction],
        from state: EnginePickerState = EnginePickerState()
    ) -> EnginePickerState {
        actions.reduce(state) { EnginePickerStateReducer.reduce($0, action: $1) }
    }

    /// Row 1: the default state is the shipped default selection (Parakeet), every engine's
    /// download slot idle, and no installed claim made until the store answers.
    func testDefaultStateIsTheShippedDefaultSelectionWithEveryEngineIdle() {
        let state = EnginePickerState()
        XCTAssertEqual(state.selection, .defaultSelection)
        XCTAssertEqual(state.selection.engine, .parakeetV3, "the shipped default is Parakeet")
        for engine in EngineCandidate.allCases {
            XCTAssertEqual(state.downloads[engine], .idle, "\(engine) must start idle")
        }
        XCTAssertTrue(state.installed.isEmpty, "no installed claim before the store answers")
    }

    /// Row 2: selecting an engine moves the selection and resets the tier to that engine's
    /// default — the payload's tier is not carried across (`EngineSelection.selecting(engine:)`),
    /// and selecting the already-selected engine applies the same reset.
    func testSelectEngineChangesSelectionAndResetsTheTierToTheNewEnginesDefault() {
        let state = reduce([.selectEngine(EngineSelection(tier: .whisperTurboQ5))])
        XCTAssertEqual(state.selection.engine, .whisperTurbo)
        XCTAssertEqual(state.selection.tier, .whisperTurbo,
            "the tier must reset to the engine's default, never carry the payload tier across")

        let back = reduce([
            .selectEngine(EngineSelection(tier: .whisperTurboQ5)),
            .selectEngine(EngineSelection(tier: .parakeetV3)),
        ])
        XCTAssertEqual(back.selection, .defaultSelection,
            "selecting Parakeet lands on Parakeet's default tier")
    }

    /// Row 3: a tier is only valid for its engine — a foreign tier is refused (a no-op, never a
    /// crash), and a tier of the selected engine is accepted.
    func testSelectTierAcceptsOnlyTiersValidForTheCurrentEngine() {
        let base = EnginePickerState()
        let refusedForeign = reduce([.selectTier(.whisperTurbo)], from: base)
        XCTAssertEqual(refusedForeign, base,
            "a tier foreign to the selected engine must be refused, leaving the state untouched")

        let whisper = reduce([.selectEngine(EngineSelection(tier: .whisperTurbo))], from: base)
        XCTAssertEqual(
            reduce([.selectTier(.parakeetV3)], from: whisper), whisper,
            "Parakeet's tier is foreign to Whisper — refused")

        let accepted = reduce([.selectTier(.whisperTurboQ5)], from: whisper)
        XCTAssertEqual(accepted.selection.tier, .whisperTurboQ5,
            "a tier of the selected engine is accepted")
    }

    /// Row 4 — **never-auto-switch, pinned structurally**: the download-action set is closed, and
    /// over that closed set no download event and no installed-state answer changes the selection.
    func testNoDownloadEventEverChangesTheSelection() {
        let base = EnginePickerState()
        let actions: [(EnginePickerAction, String)] = [
            (.downloadStarted(.whisperTurbo), "downloadStarted"),
            (.downloadProgress(.whisperTurbo, 0.4), "downloadProgress"),
            (.downloadCommitted(.whisperTurbo), "downloadCommitted"),
            (.downloadFailed(.whisperTurbo), "downloadFailed"),
            (.downloadCancelled(.whisperTurbo), "downloadCancelled"),
            (.installedState(["parakeet-tdt-0.6b-v3": true]), "installedState"),
        ]
        for (action, name) in actions {
            let result = EnginePickerStateReducer.reduce(base, action: action)
            XCTAssertEqual(result.selection, base.selection,
                "\(name) must never change the selection")
            XCTAssertEqual(result.selection.engine, .parakeetV3,
                "\(name) must not move the engine")
        }
    }

    /// Row 4, explicit: a download committed for an engine that is not selected leaves the
    /// selection untouched, and selecting the engine a download just committed for keeps it
    /// committed — a selection change never disturbs a finished download.
    func testACommittedDownloadForAnotherEngineLeavesSelectionUntouchedAndStaysCommittedWhenSelected() {
        let whisperQ5 = reduce([
            .selectEngine(EngineSelection(tier: .whisperTurbo)),
            .selectTier(.whisperTurboQ5),
            .downloadCommitted(.parakeetV3),
        ])
        XCTAssertEqual(whisperQ5.selection.tier, .whisperTurboQ5,
            "a download committed for the other engine must not change the selection")

        let reSelected = reduce([
            .selectEngine(EngineSelection(tier: .whisperTurbo)),
            .downloadCommitted(.whisperTurbo),
            .selectEngine(EngineSelection(tier: .whisperTurbo)),
        ])
        XCTAssertEqual(reSelected.selection.tier, .whisperTurbo)
        XCTAssertEqual(reSelected.downloads[.whisperTurbo], .committed,
            "selecting the engine a download committed for must keep it committed")
        XCTAssertEqual(reSelected.installed[.whisperTurbo], true)
    }

    /// Row 5a: downloadStarted marks the named engine downloading from zero; no other slot moves.
    func testDownloadStartedMarksTheEngineDownloadingFromZero() {
        let state = reduce([.downloadStarted(.whisperTurbo)])
        XCTAssertEqual(state.downloads[.whisperTurbo], .downloading(0))
        XCTAssertEqual(state.downloads[.parakeetV3], .idle, "only the named engine moves")
    }

    /// Row 5b: progress updates only the engine that is downloading — it never starts an idle
    /// engine and never moves a committed one — and is clamped into 0...1, never regressing.
    func testDownloadProgressUpdatesOnlyTheDownloadingEngineClampedAndMonotonic() {
        XCTAssertEqual(
            reduce([.downloadProgress(.whisperTurbo, 0.5)]).downloads[.whisperTurbo], .idle,
            "progress must not start an idle engine")
        XCTAssertEqual(
            reduce([.downloadCommitted(.whisperTurbo), .downloadProgress(.whisperTurbo, 0.9)])
                .downloads[.whisperTurbo], .committed,
            "progress must not move a committed engine")

        let clamped = reduce([
            .downloadStarted(.whisperTurbo),
            .downloadProgress(.whisperTurbo, -0.5),
            .downloadProgress(.whisperTurbo, 2),
            .downloadProgress(.whisperTurbo, 0.1),
        ])
        XCTAssertEqual(clamped.downloads[.whisperTurbo], .downloading(1),
            "progress must be clamped into 0...1 and never regress")
    }

    /// Row 5c: downloadCommitted is the terminal success — the slot rests committed and the engine
    /// counts as installed (committed means every file verified on disk, `ModelDownloadSession`).
    func testDownloadCommittedMarksCommittedAndInstalled() {
        let state = reduce([
            .downloadStarted(.whisperTurbo),
            .downloadProgress(.whisperTurbo, 1.0),
            .downloadCommitted(.whisperTurbo),
        ])
        XCTAssertEqual(state.downloads[.whisperTurbo], .committed)
        XCTAssertEqual(state.installed[.whisperTurbo], true,
            "a committed download means the model is present")
        XCTAssertNil(state.installed[.parakeetV3], "only the committed engine is claimed installed")
    }

    /// Row 5d: a failed download lands the engine in the failed resting state — idle except the
    /// flag — and the selection is untouched (never-auto-switch).
    func testDownloadFailedReturnsTheEngineToIdleWithTheFailedFlag() {
        let base = reduce([.selectEngine(EngineSelection(tier: .whisperTurbo))])
        let state = reduce([
            .downloadStarted(.whisperTurbo),
            .downloadProgress(.whisperTurbo, 0.4),
            .downloadFailed(.whisperTurbo),
        ], from: base)
        XCTAssertEqual(state.downloads[.whisperTurbo], .failed)
        XCTAssertEqual(state.selection, base.selection, "a failure must not move the selection")
        XCTAssertNil(state.installed[.whisperTurbo],
            "a failed download must not claim installed")
    }

    /// Row 5e: cancelling a download returns the engine to idle — the slot is free for a fresh
    /// attempt — and never changes the selection.
    func testDownloadCancelledReturnsTheEngineToIdle() {
        let state = reduce([
            .selectEngine(EngineSelection(tier: .whisperTurbo)),
            .downloadStarted(.whisperTurbo),
            .downloadProgress(.whisperTurbo, 0.3),
            .downloadCancelled(.whisperTurbo),
        ])
        XCTAssertEqual(state.downloads[.whisperTurbo], .idle,
            "a cancelled download must return the engine to idle")
        XCTAssertEqual(state.selection.engine, .whisperTurbo, "a cancel must not move the selection")
        XCTAssertNil(state.installed[.whisperTurbo], "a cancel must not claim installed")
    }

    /// Row 6: a tier change while the selected engine is downloading is **refused** (decided, not
    /// queued) — the user cannot quietly change the model under an in-flight download; once the
    /// download has ended, the tier is changeable again.
    func testTierChangeIsRefusedWhileTheSelectedEngineIsDownloading() {
        let downloading = reduce([
            .selectEngine(EngineSelection(tier: .whisperTurbo)),
            .downloadStarted(.whisperTurbo),
            .downloadProgress(.whisperTurbo, 0.5),
            .selectTier(.whisperTurboQ5),
        ])
        XCTAssertEqual(downloading.selection.tier, .whisperTurbo,
            "a tier change during an active download must be refused")
        XCTAssertEqual(downloading.downloads[.whisperTurbo], .downloading(0.5),
            "the refusal must leave the download untouched")

        let afterCommit = reduce([
            .selectEngine(EngineSelection(tier: .whisperTurbo)),
            .downloadStarted(.whisperTurbo),
            .downloadCommitted(.whisperTurbo),
            .selectTier(.whisperTurboQ5),
        ])
        XCTAssertEqual(afterCommit.selection.tier, .whisperTurboQ5,
            "once the download has ended, the tier is changeable again")
    }

    /// Rule 6's scope: only the *tier* change is refused during an active download — switching
    /// engines is an explicit user intent and stays allowed, and the in-flight download is not
    /// disturbed by it.
    func testSwitchingEnginesIsAllowedWhileADownloadIsInFlight() {
        let state = reduce([
            .downloadStarted(.whisperTurbo),
            .selectEngine(EngineSelection(tier: .parakeetV3)),
        ])
        XCTAssertEqual(state.selection.engine, .parakeetV3,
            "an explicit engine switch must be allowed during a download")
        XCTAssertEqual(state.downloads[.whisperTurbo], .downloading(0),
            "the in-flight download must not be disturbed by the switch")
    }

    /// Row 7: the store's installed-state answer updates the installed flags only — it touches
    /// neither the selection nor any download slot, and unknown engine ids are dropped (the
    /// candidate set is closed).
    func testInstalledStateUpdatesInstalledFlagsOnly() {
        let base = reduce([
            .selectEngine(EngineSelection(tier: .whisperTurbo)),
            .downloadStarted(.whisperTurbo),
        ])
        let state = reduce([
            .installedState([
                "parakeet-tdt-0.6b-v3": true,
                "whisper-large-v3-turbo": false,
                "some-future-engine": true,
            ]),
        ], from: base)
        XCTAssertEqual(state.installed[.parakeetV3], true)
        XCTAssertEqual(state.installed[.whisperTurbo], false)
        XCTAssertEqual(state.installed.count, 2, "unknown ids must be dropped, not stored")
        XCTAssertEqual(state.selection, base.selection,
            "an installed-state answer must not move the selection")
        XCTAssertEqual(state.downloads[.whisperTurbo], .downloading(0),
            "an installed-state answer must not touch download slots")
    }

    /// The state is a value: identical runs compare equal, and each field's difference is a
    /// difference in equality — the reducer can never share a mutable slot between states.
    func testStateEqualityDistinguishesEveryField() {
        let a = reduce([.selectEngine(EngineSelection(tier: .whisperTurbo))])
        XCTAssertEqual(a, reduce([.selectEngine(EngineSelection(tier: .whisperTurbo))]),
            "identical runs must produce equal states")
        XCTAssertNotEqual(a, EnginePickerState(), "a different selection must differ")

        let differentDownload = reduce([
            .selectEngine(EngineSelection(tier: .whisperTurbo)),
            .downloadStarted(.whisperTurbo),
        ])
        XCTAssertNotEqual(a, differentDownload, "a different download slot must differ")

        let differentInstalled = reduce([
            .selectEngine(EngineSelection(tier: .whisperTurbo)),
            .installedState(["parakeet-tdt-0.6b-v3": true]),
        ])
        XCTAssertNotEqual(a, differentInstalled, "a different installed flag must differ")
    }
}
