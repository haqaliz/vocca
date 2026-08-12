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

/// **The live pill's store↔window binding: show/hide follows the reducer state, and the window
/// can never take focus (`PRODUCT_SPEC.md:22`).**
///
/// ``WidgetPanel`` is glue, and its *focus behaviour* is the smoke checklist's row — whether a
/// non-activating panel actually stays out of the target app's way is a window-server question
/// CI cannot answer. What CI can answer, and what this suite pins, is everything the panel's own
/// documentation claims about the binding: that the window is **driven by the store** — any
/// non-IDLE state or terminal notice orders it front, a return to IDLE orders it out — and that
/// its construction honours `PRODUCT_SPEC.md:22`'s "never takes focus" by carrying the
/// non-activating mask and refusing to become key.
///
/// The `@Published` observation hops to the main actor (`WidgetPanel.swift:80-84`), so every
/// assertion after a fold drains the main-actor queue first — the same yield discipline the
/// composed-loop tests use for the router's tasks.
@MainActor
final class WidgetPanelBindingTests: XCTestCase {

    /// The level source the panel renders with — a plain value conformer, exactly what the seam
    /// promises (`LiveLevelSource.swift`: one synchronous read).
    private final class FakeLevelSource: LiveLevelSource {
        let level: Float
        init(level: Float) {
            self.level = level
        }
        func latestLevel() -> Float { level }
    }

    // MARK: - The store drives the window

    /// IDLE → RECORDING → IDLE: the pill follows the reducer state in both directions — the
    /// self-driving show/hide that needs no push from the composition root.
    func testThePanelFollowsTheStoreFromIdleThroughRecordingAndBack() async {
        let store = WidgetStateStore(clock: TestClock())
        let panel = WidgetPanel(store: store, levelSource: FakeLevelSource(level: 0.5))

        XCTAssertFalse(panel.isVisible, "a store that starts IDLE must keep the window off-screen")

        store.fold(.state(.recording))
        await drainMainActor()
        XCTAssertTrue(panel.isVisible, "a non-IDLE state orders the window front")

        store.fold(.state(.idle))
        await drainMainActor()
        XCTAssertFalse(panel.isVisible, "a return to IDLE orders the window out")
    }

    /// OPENING orders the window front too — the state the user sees first, before any audio
    /// exists (`PRODUCT_SPEC.md:33-38`). The binding is "anything but IDLE shows", not a
    /// recording-only rule.
    func testAnOpeningStateOrdersTheWindowFront() async {
        let store = WidgetStateStore(clock: TestClock())
        let panel = WidgetPanel(store: store, levelSource: FakeLevelSource(level: 0))

        store.fold(.state(.opening(targetAppName: "Notes")))
        await drainMainActor()

        XCTAssertTrue(panel.isVisible, "OPENING is a state the user must see")
    }

    /// A terminal notice over IDLE is still something to show — the capture-unavailable notice
    /// would otherwise be invisible, which is the "the press appeared to do nothing" failure the
    /// notice exists to prevent (`WidgetProjection.swift`).
    func testANoticeOrdersTheWindowFront() async {
        let store = WidgetStateStore(clock: TestClock())
        let panel = WidgetPanel(store: store, levelSource: FakeLevelSource(level: 0))

        store.fold(.notice(.captureUnavailable))
        await drainMainActor()

        XCTAssertTrue(panel.isVisible, "a terminal notice is something to show over an idle pill")
    }

    // MARK: - Never takes focus (PRODUCT_SPEC.md:22)

    /// The panel is non-activating and **cannot become key** — the live pill's defining absence,
    /// stated as the two facts the window server honours. The FAILSAFE's `canBecomeKey` override
    /// is what its ⌘C/⏎ affordances need; the live pill has no affordances and must never steal
    /// the field the user is dictating into (`WidgetPanel.swift:27-34`).
    func testThePanelIsNonActivatingAndCanNeverBecomeKey() {
        let store = WidgetStateStore(clock: TestClock())
        let panel = WidgetPanel(store: store, levelSource: FakeLevelSource(level: 0))

        XCTAssertTrue(
            panel.styleMask.contains(.nonactivatingPanel),
            "the pill must order in without activating Vocca")
        XCTAssertFalse(
            panel.canBecomeKey,
            "a pill that can become key is one keypress from stealing the field — PRODUCT_SPEC.md:22")
    }

    // MARK: - Fixture

    /// Turns the main-actor queue so the `@Published` observation's task hop lands.
    private func drainMainActor() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}
