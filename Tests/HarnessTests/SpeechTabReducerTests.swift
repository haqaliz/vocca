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

/// **The Speech tab's decision table** (`spec.md` R1–R5, R8) — pure, headless, and the whole of
/// what CI can execute about this surface: the page itself needs a window server and is executed
/// by nothing here (the `AppsSettingsPage`/`EnginePickerView` precedent).
///
/// ## Why this is not `EnginePickerState`
///
/// `EnginePickerState` keys presence and downloads by ``EngineCandidate``. The Speech tab cannot:
/// its `[ installed ]` / `[ download ]` badge is **per tier** (`PRODUCT_SPEC.md:254-262` shows one
/// affordance per row, and a row is a tier), and the two Whisper tiers are two artifacts in two
/// directories with two verified markers — the keying aspect 1 fixed. An engine-keyed dictionary
/// cannot express "turbo is here and q5_0 is not" at all, so the split is structural rather than
/// stylistic. ``EnginePickerCopy`` is reused unchanged; the state is not.
final class SpeechTabReducerTests: XCTestCase {

    /// **R2.** A tier the store answered present reads `installed`; a tier it answered absent
    /// reads `download`. The reducer never probes — presence arrives as an injected snapshot,
    /// exactly as `EnginePickerState.installed` does, because `ModelStore` lives in `VoccaASR`
    /// and this module may import only `VoccaCore`.
    func testAPresentTierReadsInstalledAndAnAbsentTierReadsDownload() {
        let state = SpeechTabReducer.reduce(
            .initial,
            .snapshotLoaded([
                SpeechTabTierSnapshot(tier: .parakeetV3, isPresent: true, bytesOnDisk: 470_000_000),
                SpeechTabTierSnapshot(tier: .whisperTurbo, isPresent: false, bytesOnDisk: 0),
            ]))

        XCTAssertEqual(
            state.row(for: .parakeetV3)?.install, .installed,
            "a tier the store reported present reads installed")
        XCTAssertEqual(
            state.row(for: .whisperTurbo)?.install, .absent,
            "a tier the store reported absent offers the download")
    }

    /// **R2, and aspect 1's fix seen from the surface it was fixed for.** The two Whisper tiers
    /// are one engine and two artifacts — `whisper-large-v3-turbo` at full precision and
    /// `whisper-large-v3-turbo-q5_0`, in two directories with two verified markers
    /// (`EngineTier.storageID`). Downloading one must never make the other read `[ installed ]`.
    ///
    /// This is the test an engine-keyed state cannot pass, because `[EngineCandidate: Bool]` has
    /// one slot for both rows. It is here rather than only in `ModelStoreTierKeyingTests` because
    /// the badge is where a user would act on the wrong answer: a row reading `installed` for a
    /// model that is not there sends the next dictation into `.modelUnavailable` with no
    /// explanation on the page that promised otherwise.
    func testOneWhisperTierBeingPresentNeverMakesTheOtherReadInstalled() {
        let state = SpeechTabReducer.reduce(
            .initial,
            .snapshotLoaded([
                SpeechTabTierSnapshot(tier: .whisperTurbo, isPresent: true, bytesOnDisk: 1_600_000_000),
                SpeechTabTierSnapshot(tier: .whisperTurboQ5, isPresent: false, bytesOnDisk: 0),
            ]))

        XCTAssertEqual(state.row(for: .whisperTurbo)?.install, .installed)
        XCTAssertEqual(
            state.row(for: .whisperTurboQ5)?.install, .absent,
            """
            the q5_0 tier is a different artifact in a different directory. One tier's download \
            must never answer for the other's — the keying defect aspect 1 fixed, and this is the \
            row a user would have acted on.
            """)
        XCTAssertEqual(
            state.row(for: .whisperTurboQ5)?.bytesOnDisk, 0,
            "and it occupies nothing, however large its sibling is")
    }

    /// **The never-auto-switch rule, inherited from `EnginePickerStateReducer` and re-pinned
    /// here** because the state type is different and an inherited rule that nothing re-asserts is
    /// a rule that lapses.
    ///
    /// Nothing but the user's finger moves the selection. A committed download in particular must
    /// not: "I fetched Whisper to have it available" and "I want to dictate with Whisper" are
    /// different sentences, and a tab that conflated them would switch the engine under someone
    /// who was only downloading. Driven over the **closed action set** minus the two selection
    /// actions, so an action added without a decision here fails this test rather than passing it
    /// silently.
    func testNoActionButAnExplicitChoiceEverMovesTheSelection() {
        let loaded = SpeechTabReducer.reduce(
            .initial,
            .snapshotLoaded([
                SpeechTabTierSnapshot(tier: .parakeetV3, isPresent: true, bytesOnDisk: 1),
                SpeechTabTierSnapshot(tier: .whisperTurbo, isPresent: false, bytesOnDisk: 0),
            ]))
        XCTAssertEqual(loaded.selection, .defaultSelection, "the shipped default, to start")

        let nonSelecting: [SpeechTabAction] = [
            .snapshotLoaded([
                SpeechTabTierSnapshot(tier: .whisperTurbo, isPresent: true, bytesOnDisk: 9)
            ]),
            .downloadStarted(.whisperTurbo),
            .downloadProgress(.whisperTurbo, 0.5),
            .downloadCommitted(.whisperTurbo, bytesOnDisk: 1_600_000_000),
            .downloadFailed(.whisperTurbo),
            .downloadCancelled(.whisperTurbo),
        ]

        for action in nonSelecting {
            let next = SpeechTabReducer.reduce(loaded, action)
            XCTAssertEqual(
                next.selection, loaded.selection,
                "\(action) moved the selection. Only the user's own choice may.")
        }
    }

    /// **The other half of the same rule**: an explicit choice *does* move it, and picking an
    /// engine lands on that engine's default tier rather than carrying a foreign one across —
    /// `EngineSelection.selecting(engine:)`'s contract, which the tab must not re-implement.
    func testAnExplicitChoiceMovesTheSelectionAndPickingAnEngineResetsTheTier() {
        var state = SpeechTabReducer.reduce(.initial, .selectTier(.whisperTurboQ5))
        XCTAssertEqual(
            state.selection.tier, .whisperTurboQ5, "the user picked a tier; it is the selection")
        XCTAssertEqual(state.selection.engine, .whisperTurbo, "and the engine follows from it")

        state = SpeechTabReducer.reduce(state, .selectEngine(.parakeetV3))
        XCTAssertEqual(
            state.selection, EngineSelection(tier: .parakeetV3),
            "picking an engine lands on that engine's default tier")

        state = SpeechTabReducer.reduce(state, .selectEngine(.whisperTurbo))
        XCTAssertEqual(
            state.selection.tier, .whisperTurbo,
            """
            picking Whisper again lands on turbo, its default — not on the q5_0 tier chosen \
            earlier. There is no foreign tier to inherit, and the tab does not invent a memory \
            `EngineSelection` deliberately does not have.
            """)
    }

    /// **R8, tier and engine changes during a transfer.** Switching away from a downloading tier
    /// lets the download continue: it is that tier's model and it is still wanted (the plan's
    /// M12 table). The row keeps its progress; only the radio moves.
    ///
    /// This diverges from `EnginePickerStateReducer`, which **refuses** a tier change while the
    /// selected engine downloads. That reducer drives a one-shot picker; this is a persistent
    /// settings page where a user may reasonably queue a download and go on using the engine they
    /// have. The divergence is deliberate and is why the two states are not one type.
    func testSwitchingTierOrEngineDuringADownloadLeavesTheDownloadRunning() {
        var state = SpeechTabReducer.reduce(.initial, .selectEngine(.whisperTurbo))
        state = SpeechTabReducer.reduce(state, .downloadStarted(.whisperTurbo))
        state = SpeechTabReducer.reduce(state, .downloadProgress(.whisperTurbo, 0.4))

        let afterTierChange = SpeechTabReducer.reduce(state, .selectTier(.whisperTurboQ5))
        XCTAssertEqual(
            afterTierChange.row(for: .whisperTurbo)?.install, .downloading(0.4),
            "the turbo download is untouched by a move to the q5_0 row")
        XCTAssertEqual(afterTierChange.selection.tier, .whisperTurboQ5, "and the radio moved")

        let afterEngineChange = SpeechTabReducer.reduce(state, .selectEngine(.parakeetV3))
        XCTAssertEqual(
            afterEngineChange.row(for: .whisperTurbo)?.install, .downloading(0.4),
            "and by a move to the other engine entirely")
    }

    /// **Terminal download states do not move.** Progress arriving after a commit or a failure is
    /// ignored rather than reopening the row.
    ///
    /// The hazard is real and not hypothetical: `StoreModelDownloadSession` publishes into an
    /// `AsyncStream` and a page consumes it on a task, so a late `.progress` can be folded after
    /// the terminal event on a slow main actor. A bar that jumped back to 40% after saying "done"
    /// is the in-between window this repository keeps building — a state that looks like working,
    /// or worse, a finished state that looks unfinished.
    func testProgressAfterATerminalDownloadEventIsIgnored() {
        var committed = SpeechTabReducer.reduce(.initial, .downloadStarted(.whisperTurbo))
        committed = SpeechTabReducer.reduce(
            committed, .downloadCommitted(.whisperTurbo, bytesOnDisk: 1_600_000_000))
        committed = SpeechTabReducer.reduce(committed, .downloadProgress(.whisperTurbo, 0.4))
        XCTAssertEqual(
            committed.row(for: .whisperTurbo)?.install, .installed,
            "a committed tier stays installed; a late progress event does not un-finish it")
        XCTAssertEqual(
            committed.row(for: .whisperTurbo)?.bytesOnDisk, 1_600_000_000,
            "and the disk figure the commit reported survives")

        var failed = SpeechTabReducer.reduce(.initial, .downloadStarted(.whisperTurboQ5))
        failed = SpeechTabReducer.reduce(failed, .downloadFailed(.whisperTurboQ5))
        failed = SpeechTabReducer.reduce(failed, .downloadProgress(.whisperTurboQ5, 0.9))
        XCTAssertEqual(
            failed.row(for: .whisperTurboQ5)?.install, .failed,
            "and a failed row stays failed until something is started again")
    }

    /// **Progress is clamped and never regresses.** The aggregate the store publishes is monotonic
    /// by construction; the reducer defends the bar against anything else, because a bar is the
    /// only thing a user has to judge a five-minute transfer by.
    func testProgressIsClampedAndMonotonic() {
        var state = SpeechTabReducer.reduce(.initial, .downloadStarted(.parakeetV3))
        state = SpeechTabReducer.reduce(state, .downloadProgress(.parakeetV3, 0.6))
        state = SpeechTabReducer.reduce(state, .downloadProgress(.parakeetV3, 0.2))
        XCTAssertEqual(
            state.row(for: .parakeetV3)?.install, .downloading(0.6), "progress never goes backwards")

        state = SpeechTabReducer.reduce(state, .downloadProgress(.parakeetV3, 7))
        XCTAssertEqual(
            state.row(for: .parakeetV3)?.install, .downloading(1), "and never exceeds the whole")
    }

    /// **A tier nothing has been said about renders neither badge.** `[ download ]` for a model
    /// already on disk offers a pointless 470 MB transfer; `[ installed ]` for one that is not
    /// there is the failure this repository keeps re-finding — a surface that looks like working.
    /// So the honest rendering of "we have not looked yet" is its own state.
    func testATierTheStoreHasNotAnsweredAboutReadsNeitherBadge() {
        XCTAssertEqual(
            SpeechTabState.initial.row(for: .parakeetV3)?.install, .unknown,
            "the window opens with no claim about any tier")
        XCTAssertEqual(
            SpeechTabState.initial.rows.count, EngineTier.allCases.count,
            "every tier still has a row — the claim is missing, not the row")
    }

    /// **A completed removal makes the tier read absent, and frees its disk figure.** The store's
    /// `remove(tier:version:)` deletes the version directory *and* its verified marker together,
    /// so the tab's own answer must move with it — a row still reading `[ installed ]` after a
    /// removal is the surface half of the defect that ordering exists to prevent.
    func testACompletedRemovalMakesTheTierReadAbsentAndFreesItsBytes() {
        var state = SpeechTabReducer.reduce(
            .initial,
            .snapshotLoaded([
                SpeechTabTierSnapshot(tier: .whisperTurbo, isPresent: true, bytesOnDisk: 1_600_000_000)
            ]))
        state = SpeechTabReducer.reduce(state, .removalCompleted(.whisperTurbo))

        XCTAssertEqual(state.row(for: .whisperTurbo)?.install, .absent)
        XCTAssertEqual(state.row(for: .whisperTurbo)?.bytesOnDisk, 0, "the bytes are gone with it")
        XCTAssertNil(state.errorMessage, "and nothing went wrong")
    }

    /// **A failed removal surfaces, and does not clear the row.** `ModelStore.remove` throws when
    /// a directory that exists cannot be deleted — and a removal the user asked for that did not
    /// happen must say so, not quietly redraw the row as gone.
    ///
    /// The `DictionarySettingsPage`/`AppsTabCopy.saveError` rule: a store that silently fails is
    /// one the user acts on again next launch, having been told it worked.
    func testAFailedRemovalSurfacesAndLeavesTheRowInstalled() {
        var state = SpeechTabReducer.reduce(
            .initial,
            .snapshotLoaded([
                SpeechTabTierSnapshot(tier: .whisperTurbo, isPresent: true, bytesOnDisk: 1_600_000_000)
            ]))
        state = SpeechTabReducer.reduce(
            state, .removalFailed(.whisperTurbo, "Permission denied"))

        XCTAssertEqual(
            state.row(for: .whisperTurbo)?.install, .installed,
            "the model is still there, so the row still says so")
        XCTAssertEqual(
            state.row(for: .whisperTurbo)?.bytesOnDisk, 1_600_000_000,
            "and it still occupies the disk it occupied")
        XCTAssertEqual(
            state.errorMessage, SpeechTabCopy.removalFailed("Permission denied"),
            "and the failure is on the page, in the store's own words")
    }
}
