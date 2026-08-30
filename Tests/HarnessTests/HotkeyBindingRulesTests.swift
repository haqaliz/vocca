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
import XCTest

/// **What makes a hotkey binding legal** (`binding-vocabulary/spec.md`, M6/M7).
///
/// Every other aspect of `hotkey-rebinding` asks this decision table; nothing else decides it.
/// The asymmetry that shapes these tests is in `plan_20260830.md` §6: a false `refused` is an
/// annoyance the user works around, while a false `accepted` on a text-entry key makes that key
/// untypeable **system-wide**, with the recovery path behind a Settings window that needs the
/// keyboard. So the refusal side is driven over whole tables and the acceptance side is
/// representative.
final class HotkeyBindingRulesTests: XCTestCase {

    // MARK: - The vocabulary

    /// The refusal set is closed at three reasons, and `CaseIterable` is the mechanism the
    /// exhaustiveness test below rides on rather than decoration: a fourth reason added without a
    /// candidate that produces it fails there, not in review.
    func testTheRefusalVocabularyIsClosed() {
        XCTAssertEqual(
            Set(HotkeyBindingRefusal.allCases),
            [.modifierOnly, .reservedByVocca, .unmodifiedTextEntryKey],
            """
            The refusal vocabulary changed. A new reason is a product decision — spec.md names \
            the closed set — and it needs a candidate that produces it before it exists.
            """)
    }
    /// The answer is three-way, and `warned` is not `accepted`. `shortcut-conflicts` needs
    /// somewhere to put "this is legal, and Spotlight already uses it" without inventing a second
    /// vocabulary — and a surface that renders a warning the same as an acceptance has silently
    /// dropped the only thing the warning was for. The conflicting shortcut's **name is part of
    /// the answer's identity**, because "used by another shortcut" and "used by Spotlight" are
    /// different sentences to show a user.
    func testTheValidityAnswerIsThreeWayAndAWarningCarriesItsName() {
        XCTAssertNotEqual(HotkeyBindingValidity.accepted, .warned(.usedBySystemShortcut(name: nil)))
        XCTAssertNotEqual(
            HotkeyBindingValidity.warned(.usedBySystemShortcut(name: "Spotlight")),
            .warned(.usedBySystemShortcut(name: nil)))
        XCTAssertNotEqual(
            HotkeyBindingValidity.refused(.modifierOnly), .refused(.reservedByVocca))
        XCTAssertEqual(HotkeyBindingValidity.refused(.modifierOnly), .refused(.modifierOnly))
    }
}
