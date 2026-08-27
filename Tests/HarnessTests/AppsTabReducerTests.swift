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
import VoccaUI
import XCTest

/// **The Apps tab's decisions** (`apps-tab/spec.md` AC 1–3, 5, 7) — a pure reducer over an
/// injected store snapshot, in the house style (``EnginePickerStateReducer``,
/// ``FailsafeStateReducer``, ``OnboardingReducer``).
///
/// Two things it deliberately does **not** do, both worth stating because their absence is the
/// design:
///
/// - **it holds no memory logic.** The health a row shows is Core's own projection
///   (`StrategyMemory.orderedRungs`), asked for the settled answer; the freeze an override
///   creates is Core's too. This reducer writes the override and reads the projection, and the
///   test that matters most here — ``testADemoteOrReProbeEventForAnOverriddenAppLeavesItUntouched``
///   — drives the *shipped* decisions rather than anything defined in this module;
/// - **it has no clock.** The projection is asked at `now: 0`, which is never past a re-probe
///   window, so the column reads the state an application has *settled* into rather than the
///   momentary "a probe happens to be due this second". A settings table that changed what it
///   said about an app because a week elapsed while it was open would be reporting a
///   scheduling detail as a fact about the app.
final class AppsTabReducerTests: XCTestCase {

    // MARK: - Fixtures

    private static let notes = "com.apple.Notes"
    private static let editor = "com.example.Editor"
    private static let chrome = "com.google.Chrome"
    private static let window = StrategyMemoryTargets.reprobeWindowSeconds

    private func entry(
        _ bundleID: String,
        name: String,
        strategy: InjectionStrategy = InjectionStrategy(),
        allowlisted: Bool = false
    ) -> AppStrategyEntry {
        var scoped = strategy
        scoped.bundleID = bundleID
        return AppStrategyEntry(
            bundleID: bundleID, displayName: name, strategy: scoped, isAllowlisted: allowlisted)
    }

    private func loaded(_ entries: [AppStrategyEntry]) -> AppsTabState {
        AppsTabReducer.reduce(.initial, .snapshotLoaded(entries))
    }

    private func row(_ state: AppsTabState, _ bundleID: String) -> AppsRow? {
        state.rows.first { $0.bundleID == bundleID }
    }

    // MARK: - Loading

    /// Nothing is claimed before the snapshot lands. `isLoaded == false` with no rows is the
    /// state the window opens in, and it is *not* the empty state — the difference between "Vocca
    /// has learned nothing" and "we haven't looked yet" is the whole reason the flag exists
    /// (the `DictionarySettingsPage` guard).
    func testDefaultStateIsLoadedFalseWithNoRows() {
        XCTAssertFalse(AppsTabState.initial.isLoaded)
        XCTAssertTrue(AppsTabState.initial.rows.isEmpty)
        XCTAssertNil(AppsTabState.initial.saveError)
    }

    /// The snapshot becomes rows, sorted by the name a person reads — not by bundle identifier,
    /// which sorts `com.apple.*` above everything else for reasons that are Apple's and not the
    /// user's.
    func testSnapshotLoadedBuildsRowsSortedByDisplayName() {
        let state = loaded([
            entry(Self.editor, name: "Zed"),
            entry(Self.notes, name: "Notes", allowlisted: true),
            entry(Self.chrome, name: "Google Chrome"),
        ])

        XCTAssertTrue(state.isLoaded)
        XCTAssertEqual(state.rows.map(\.displayName), ["Google Chrome", "Notes", "Zed"])
        XCTAssertEqual(state.rows.map(\.bundleID), [Self.chrome, Self.notes, Self.editor])
    }

    /// Two applications with the same display name still sort deterministically — a table whose
    /// row order changed between openings looks like the data changed.
    func testRowsWithEqualDisplayNamesSortByBundleIDForStability() {
        let state = loaded([
            entry("com.example.b", name: "Editor"),
            entry("com.example.a", name: "Editor"),
        ])
        XCTAssertEqual(state.rows.map(\.bundleID), ["com.example.a", "com.example.b"])
    }

    /// An empty snapshot is loaded-and-empty: the empty state, distinct from the opening state.
    func testAnEmptyStoreShowsTheEmptyState() {
        let state = loaded([])
        XCTAssertTrue(state.isLoaded)
        XCTAssertTrue(state.rows.isEmpty)
    }

    // MARK: - The health mapping

    /// Every state an application's strategy can settle into, and the word the column shows.
    ///
    /// The two `pasting` rows are the ones worth reading twice: a **seeded-hostile** application
    /// and one whose accessibility rung was **demoted by a failure** are indistinguishable here,
    /// and should be — the user is being told how Vocca types into the app, not the history of
    /// how it found out.
    func testHealthMappingTableForEveryEffectiveFirstRung() {
        let promoted = InjectionStrategy(learnedAllowlist: true)
        let demoted = InjectionStrategy(
            demotedRungs: [.accessibility], reprobeWindows: [.accessibility: Self.window])
        let manual = InjectionStrategy(
            overrideRungs: AppsTabMethod.manual.rungs)

        let state = loaded([
            entry("com.a.seeded", name: "Seeded", allowlisted: true),
            entry("com.a.promoted", name: "Promoted", strategy: promoted),
            entry("com.a.unknown", name: "Unknown"),
            entry("com.a.hostile", name: "Hostile", strategy: demoted),
            entry("com.a.demoted", name: "Demoted", strategy: demoted, allowlisted: true),
            entry("com.a.manual", name: "Manual", strategy: manual),
        ])

        XCTAssertEqual(row(state, "com.a.seeded")?.health, .typingDirectly)
        XCTAssertEqual(row(state, "com.a.promoted")?.health, .typingDirectly)
        XCTAssertEqual(row(state, "com.a.unknown")?.health, .pasting)
        XCTAssertEqual(row(state, "com.a.hostile")?.health, .pasting)
        XCTAssertEqual(
            row(state, "com.a.demoted")?.health, .pasting,
            "An allowlisted app whose accessibility rung was demoted still reads as blessed.")
        XCTAssertEqual(row(state, "com.a.manual")?.health, .manualOnly)
    }

    /// A due re-probe does not change the column, and the reducer does not merely get away with
    /// it because real windows are large: the window here is zero — due at every instant there
    /// is — and the answer is still the settled one, because the projection is asked with the
    /// windows stripped.
    func testADueReProbeDoesNotChangeTheReportedHealth() {
        let due = InjectionStrategy(
            demotedRungs: [.accessibility], reprobeWindows: [.accessibility: 0])
        let state = loaded([entry(Self.chrome, name: "Google Chrome", strategy: due)])
        XCTAssertEqual(
            row(state, Self.chrome)?.health, .pasting,
            """
            The health column reported a momentary re-probe as the app's state. One probe is \
            scheduled; nothing has been learned yet, and the app still pastes.
            """)
    }

    // MARK: - Overrides

    /// A pin sets the rung order, flips the row to overridden, and clears any stale save error.
    func testOverrideSetPinsTheRungsAndMarksTheRowOverridden() {
        var state = loaded([entry(Self.chrome, name: "Google Chrome")])
        state.saveError = "stale"
        state = AppsTabReducer.reduce(
            state, .overrideSet(bundleID: Self.chrome, method: .typeDirectly))

        XCTAssertEqual(
            state.entries[Self.chrome]?.strategy.overrideRungs,
            AppsTabMethod.typeDirectly.rungs)
        XCTAssertEqual(row(state, Self.chrome)?.isOverridden, true)
        XCTAssertEqual(row(state, Self.chrome)?.method, .typeDirectly)
        XCTAssertNil(state.saveError)
    }

    /// The row shows the **pin's** health, never the learned one. An app that Vocca decided to
    /// paste into and the user pinned to type directly reads "typing directly" — otherwise the
    /// control appears not to have worked.
    func testAnOverriddenAppShowsTheOverridesHealthNotTheLearnedOne() {
        let demoted = InjectionStrategy(
            demotedRungs: [.accessibility], reprobeWindows: [.accessibility: Self.window])
        var state = loaded([
            entry(Self.notes, name: "Notes", strategy: demoted, allowlisted: true)
        ])
        XCTAssertEqual(row(state, Self.notes)?.health, .pasting)

        state = AppsTabReducer.reduce(
            state, .overrideSet(bundleID: Self.notes, method: .typeDirectly))
        XCTAssertEqual(row(state, Self.notes)?.health, .typingDirectly)
    }

    /// Pinning an application Vocca has never typed into creates its row: the override *is* the
    /// strategy, so there is now something to remember about it.
    func testAnOverrideOnAnUnknownAppCreatesItsRow() {
        var state = loaded([])
        state = AppsTabReducer.reduce(
            state, .overrideSet(bundleID: "com.example.New", method: .paste))

        XCTAssertEqual(state.rows.count, 1)
        XCTAssertEqual(row(state, "com.example.New")?.isOverridden, true)
        XCTAssertEqual(
            row(state, "com.example.New")?.displayName, "com.example.New",
            "A row with no resolved name must still be nameable — the bundle identifier is the "
            + "fallback, never a blank.")
    }

    /// Clearing a pin returns the row to what Vocca learned, badge and health together.
    func testOverrideClearedReturnsTheAppToItsLearnedState() {
        let demoted = InjectionStrategy(
            demotedRungs: [.accessibility], reprobeWindows: [.accessibility: Self.window])
        var state = loaded([
            entry(Self.notes, name: "Notes", strategy: demoted, allowlisted: true)
        ])
        state = AppsTabReducer.reduce(
            state, .overrideSet(bundleID: Self.notes, method: .typeDirectly))
        state = AppsTabReducer.reduce(state, .overrideCleared(bundleID: Self.notes))

        XCTAssertNil(state.entries[Self.notes]?.strategy.overrideRungs)
        XCTAssertEqual(row(state, Self.notes)?.isOverridden, false)
        XCTAssertNil(row(state, Self.notes)?.method)
        XCTAssertEqual(
            row(state, Self.notes)?.health, .pasting,
            "Clearing the pin did not restore the learned answer — the demotion is still there.")
    }

    /// A hand-edited `strategies.json` can pin any order at all. The row is overridden and its
    /// health is that order's first rung; the picker simply has nothing selected, rather than
    /// the tab rewriting the user's file to the nearest thing it recognises.
    func testAnUnrecognisedOverrideOrderIsShownWithoutBeingRewritten() {
        let odd = InjectionStrategy(overrideRungs: [.keystrokeSynthesis])
        let state = loaded([entry(Self.editor, name: "Zed", strategy: odd)])

        XCTAssertEqual(row(state, Self.editor)?.isOverridden, true)
        XCTAssertNil(row(state, Self.editor)?.method)
        XCTAssertEqual(row(state, Self.editor)?.health, .manualOnly)
        XCTAssertEqual(state.entries[Self.editor]?.strategy.overrideRungs, [.keystrokeSynthesis])
    }

    /// **S2's absolute freeze, pinned end-to-end over the shipped decisions.** The override this
    /// reducer writes is handed to Core's own record fold and projection: the strategy comes back
    /// byte-for-byte identical, and the order is the pin — no demotion, no promotion, no
    /// re-probe. If the freeze were absent this fails, which is why the aspect is built last.
    func testADemoteOrReProbeEventForAnOverriddenAppLeavesItUntouched() {
        var state = loaded([entry(Self.chrome, name: "Google Chrome")])
        state = AppsTabReducer.reduce(
            state, .overrideSet(bundleID: Self.chrome, method: .typeDirectly))
        let pinned = try! XCTUnwrap(state.entries[Self.chrome]?.strategy)

        // A run in which the pinned first rung lost and clipboard delivered: for any unpinned
        // app this demotes accessibility with a fresh window.
        let folded = StrategyMemory.record(
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
                verified: false, elapsed: .zero),
            attempted: [.accessibility, .clipboardPaste],
            now: Self.window * 4,
            allowlisted: false,
            into: pinned)

        XCTAssertEqual(
            folded, pinned,
            """
            A pinned application was changed by a ladder outcome. An override is the user's \
            instruction and is absolute (PRD S2): memory neither demotes, promotes nor re-probes \
            an app the user has pinned.
            """)
        XCTAssertEqual(
            StrategyMemory.orderedRungs(
                for: pinned, allowlisted: false, now: Self.window * 4),
            AppsTabMethod.typeDirectly.rungs,
            "The projection did not return the pin verbatim.")
    }

    // MARK: - Reset

    /// Reset drops what Vocca worked out — the whole row, not an emptied one. A row that
    /// survives as an empty strategy would also survive the launch-time hostile seed, which only
    /// mints for applications it knows nothing about: Chrome would silently come back
    /// *un*-seeded, which is worse than either state the user asked for.
    func testResetRestoresSeededDefaultsForEveryApp() {
        let promoted = InjectionStrategy(learnedAllowlist: true)
        let demoted = InjectionStrategy(
            demotedRungs: [.accessibility], reprobeWindows: [.accessibility: Self.window])
        var state = loaded([
            entry(Self.editor, name: "Zed", strategy: promoted),
            entry(Self.chrome, name: "Google Chrome", strategy: demoted),
        ])
        state.saveError = "stale"

        state = AppsTabReducer.reduce(state, .resetLearned)

        XCTAssertTrue(
            state.rows.isEmpty,
            """
            Reset left rows behind. Everything in the table was learned, so after "reset what \
            Vocca learned" there is nothing left to show — and an emptied-but-present row would \
            defeat the launch-time hostile seed, which only mints for apps with no entry.
            """)
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertTrue(state.isLoaded)
        XCTAssertNil(state.saveError)
    }

    /// Overrides survive a reset, and keep their health. "Reset what Vocca learned" is scoped by
    /// its own wording to *learning*; a pin is an instruction, and a reset that silently undid
    /// one would teach the user that their settings do not stick.
    func testResetPreservesExplicitOverrides() {
        let demotedAndPinned = InjectionStrategy(
            demotedRungs: [.accessibility],
            learnedAllowlist: true,
            reprobeWindows: [.accessibility: Self.window],
            overrideRungs: AppsTabMethod.manual.rungs)
        var state = loaded([
            entry(Self.notes, name: "Notes", strategy: demotedAndPinned, allowlisted: true),
            entry(Self.editor, name: "Zed", strategy: InjectionStrategy(learnedAllowlist: true)),
        ])

        state = AppsTabReducer.reduce(state, .resetLearned)

        XCTAssertEqual(state.rows.map(\.bundleID), [Self.notes])
        XCTAssertEqual(row(state, Self.notes)?.isOverridden, true)
        XCTAssertEqual(row(state, Self.notes)?.health, .manualOnly)
        let kept = state.entries[Self.notes]?.strategy
        XCTAssertEqual(kept?.overrideRungs, AppsTabMethod.manual.rungs)
        XCTAssertEqual(
            kept?.demotedRungs, [],
            "The pinned app kept a learned demotion through a reset.")
        XCTAssertEqual(kept?.learnedAllowlist, false)
        XCTAssertEqual(kept?.reprobeWindows, [:])
    }

    /// Reset on an empty table changes nothing and, in particular, does not un-load the tab.
    func testResetOnAnEmptyStoreIsANoOp() {
        let state = AppsTabReducer.reduce(loaded([]), .resetLearned)
        XCTAssertEqual(state, loaded([]))
    }

    // MARK: - Saving

    /// A failed write is carried in state and cleared by the next success — never swallowed.
    func testSaveFailureSurfacesAnErrorAndSaveSuccessClearsIt() {
        var state = loaded([entry(Self.notes, name: "Notes", allowlisted: true)])
        state = AppsTabReducer.reduce(state, .saveFailed("disk full"))
        XCTAssertEqual(state.saveError, "disk full")

        state = AppsTabReducer.reduce(state, .saveSucceeded)
        XCTAssertNil(state.saveError)
    }

    /// A failure leaves the rows alone: the pin the user just made is still on screen, so they
    /// can see what did not save.
    func testSaveFailureLeavesTheRowsIntact() {
        var state = loaded([entry(Self.notes, name: "Notes", allowlisted: true)])
        state = AppsTabReducer.reduce(
            state, .overrideSet(bundleID: Self.notes, method: .manual))
        let before = state.rows
        state = AppsTabReducer.reduce(state, .saveFailed("disk full"))
        XCTAssertEqual(state.rows, before)
    }

    // MARK: - Totality

    /// Every action folds from every state without trapping — the closed-set discipline. The
    /// interesting half is that it also folds from the *unloaded* state, which is what a gesture
    /// arriving before the snapshot would produce.
    func testTheClosedActionSetFoldsFromEveryState() {
        let states: [AppsTabState] = [
            .initial,
            loaded([]),
            loaded([entry(Self.notes, name: "Notes", allowlisted: true)]),
            AppsTabReducer.reduce(
                loaded([entry(Self.chrome, name: "Google Chrome")]),
                .overrideSet(bundleID: Self.chrome, method: .manual)),
        ]
        let actions: [AppsTabAction] = [
            .snapshotLoaded([]),
            .snapshotLoaded([entry(Self.editor, name: "Zed")]),
            .overrideSet(bundleID: Self.notes, method: .paste),
            .overrideCleared(bundleID: Self.notes),
            .overrideCleared(bundleID: "com.example.NeverSeen"),
            .resetLearned,
            .saveSucceeded,
            .saveFailed("x"),
        ]

        for state in states {
            for action in actions {
                let next = AppsTabReducer.reduce(state, action)
                XCTAssertFalse(
                    next.rows.contains { $0.bundleID.isEmpty },
                    "A fold produced a row with no bundle identifier.")
            }
        }
    }

    /// No action clears `isLoaded` once it is set. The tab never returns to "we haven't looked
    /// yet", which would show the opening state to a user who is looking at a table.
    func testNoActionUnloadsTheTab() {
        var state = loaded([entry(Self.notes, name: "Notes", allowlisted: true)])
        for action: AppsTabAction in [
            .overrideSet(bundleID: Self.notes, method: .paste),
            .overrideCleared(bundleID: Self.notes), .resetLearned, .saveSucceeded,
            .saveFailed("x"),
        ] {
            state = AppsTabReducer.reduce(state, action)
            XCTAssertTrue(state.isLoaded)
        }
    }

    /// Equality distinguishes every field, so a test asserting two states equal cannot pass by
    /// comparing a subset.
    func testStateEqualityDistinguishesEveryField() {
        let base = loaded([entry(Self.notes, name: "Notes", allowlisted: true)])
        XCTAssertNotEqual(base, AppsTabState.initial)
        XCTAssertNotEqual(base, AppsTabReducer.reduce(base, .saveFailed("x")))
        XCTAssertNotEqual(
            base,
            AppsTabReducer.reduce(base, .overrideSet(bundleID: Self.notes, method: .manual)))
        XCTAssertNotEqual(base, loaded([entry(Self.notes, name: "Notes 2", allowlisted: true)]))
        XCTAssertEqual(base, loaded([entry(Self.notes, name: "Notes", allowlisted: true)]))
    }
}
