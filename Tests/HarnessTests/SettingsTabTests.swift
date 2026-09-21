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
import VoccaUI
import XCTest

/// **The settings window's tabs** — the first test this enum has ever had, added because the
/// Apps tab is the first case appended to it since the window shipped, and updated for Usage,
/// the sixth (`daily-use-ledger/usage-tab/spec.md` E1), and Actions, the seventh
/// (`action-surface-wiring/actions-tab`).
///
/// `SettingsView` iterates `allCases` and switches exhaustively over them, so a case that exists
/// gets a tab and a page or the build fails. What the compiler cannot check is the part a user
/// sees: that the tab has words on it, a symbol above them, and a stable identity — and that a
/// case was not silently dropped while another was added.
final class SettingsTabTests: XCTestCase {

    /// Seven tabs: the four the window shipped with, Apps, Actions, and Usage.
    func testAllCasesAreTheSevenShippedTabs() {
        XCTAssertEqual(
            SettingsTab.allCases,
            [.general, .speech, .cleanup, .dictionary, .apps, .actions, .usage],
            """
            The settings window's tabs changed. Each one is a thing a user can decide about, so \
            adding or removing one is a product decision — and the order is the order they read \
            in: how you start, who hears you, what happens to the text, which words Vocca gets \
            wrong, where it all ends up, what may act on your behalf, and how it went.
            """)
    }

    /// The Apps tab's own label and symbol.
    func testTheAppsTabIsLabelledAndSymbolled() {
        XCTAssertEqual(SettingsTab.apps.title, "Apps")
        XCTAssertEqual(SettingsTab.apps.symbolName, "square.grid.2x2")
        XCTAssertEqual(SettingsTab.apps.id, "apps")
    }

    /// The Usage tab's own label and symbol. `calendar` rather than a chart glyph: the tab is a
    /// ledger of days, and a bar chart is the picture of the analytics dashboard
    /// `PRODUCT_SPEC.md:367` says this product does not have.
    func testTheUsageTabIsLabelledAndSymbolled() {
        XCTAssertEqual(SettingsTab.usage.title, "Usage")
        XCTAssertEqual(SettingsTab.usage.symbolName, "calendar")
        XCTAssertEqual(SettingsTab.usage.id, "usage")
    }

    /// The Actions tab's own label and symbol. `bolt` rather than a network glyph: the tab is
    /// about what may act on this machine, and a cloud-shaped picture would be the
    /// analytics-tab mistake in reverse.
    func testTheActionsTabIsLabelledAndSymbolled() {
        XCTAssertEqual(SettingsTab.actions.title, "Actions")
        XCTAssertEqual(SettingsTab.actions.symbolName, "bolt")
        XCTAssertEqual(SettingsTab.actions.id, "actions")
    }

    /// Every tab has a non-empty title and symbol, and no two share either. A duplicate symbol
    /// gives two tabs the same picture, which is the one thing a user navigates by.
    func testEveryTabHasADistinctTitleAndSymbol() {
        let titles = SettingsTab.allCases.map(\.title)
        let symbols = SettingsTab.allCases.map(\.symbolName)
        XCTAssertFalse(titles.contains(where: \.isEmpty))
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
        XCTAssertEqual(Set(titles).count, titles.count, "Two tabs share a title.")
        XCTAssertEqual(Set(symbols).count, symbols.count, "Two tabs share a symbol.")
        XCTAssertEqual(
            Set(SettingsTab.allCases.map(\.id)).count, SettingsTab.allCases.count,
            "Two tabs share an identity — the TabView's selection would be ambiguous.")
    }
}
