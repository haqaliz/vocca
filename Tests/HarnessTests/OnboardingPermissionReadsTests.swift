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
import XCTest

/// The A2 Core seam's pure translations (`first-run-permissions` / `permission-reads`): the raw
/// facts the adapters hand across the seam — an Accessibility trust `Bool` and a tap-armed
/// `Bool` from the wiring, a raw microphone status from ``MicrophoneAuthorization`` — mapped
/// into the reducer's vocabulary (`OnboardingAccessibility`/`OnboardingMicrophone`, A1).
///
/// The mapping's home is **decided here, in this test**: it lives in ``OnboardingPermissionReads``,
/// the seam the root feeds, never in the reducer. The reducer's vocabulary stays the two enums it
/// already folds (`OnboardingReducerTests` pins that table); the reads seam is the one place raw
/// facts become states — so the M5c three-state rule (a ✓ that hides a dead tap is the silent
/// gate this capability exists to kill) is enforced where the facts enter, not re-derived where
/// the flow renders.
final class OnboardingPermissionReadsTests: XCTestCase {

    // MARK: - The accessibility mapping (M5, M5c)

    /// The full truth table of `(trusted, tapArmed)` → `OnboardingAccessibility` — all four
    /// combinations, in one table: `notGranted` = no trust; `grantedNotArmed` = trust without a
    /// live tap (the restart-required middle state); `armed` = trust and a live tap.
    func testTheAccessibilityMappingCoversAllFourCombinations() {
        let table: [(trusted: Bool, tapArmed: Bool, expected: OnboardingAccessibility)] = [
            (false, false, .notGranted),
            (false, true, .notGranted),
            (true, false, .grantedNotArmed),
            (true, true, .armed),
        ]
        for row in table {
            XCTAssertEqual(
                OnboardingPermissionReads.accessibility(trusted: row.trusted, tapArmed: row.tapArmed),
                row.expected,
                "(trusted: \(row.trusted), tapArmed: \(row.tapArmed)) must map to \(row.expected)")
        }
    }

    /// The M5c row, stated alone: trust without a live tap is `grantedNotArmed`, **never**
    /// `armed` — a ✓ that hides a dead tap is the silent gate this capability exists to kill,
    /// and the restart path (M3) rides on this state.
    func testTrustWithoutALiveTapIsGrantedNotArmed() {
        XCTAssertEqual(
            OnboardingPermissionReads.accessibility(trusted: true, tapArmed: false),
            .grantedNotArmed)
    }

    /// A dead tap cannot fabricate a grant: the tap's health (`TapHealth != .permissionMissing`)
    /// is only consulted once the trust Bool is true, so the row no trust can reach is
    /// `notGranted` regardless of what the tap reports.
    func testNoTrustIsNotGrantedEvenWhenTheTapWouldReportArmed() {
        XCTAssertEqual(
            OnboardingPermissionReads.accessibility(trusted: false, tapArmed: true),
            .notGranted)
    }

    // MARK: - The microphone mapping

    /// The raw TCC status → the reducer's vocabulary: the three raw states ARE the three
    /// reducer states, translated in the one place the adapter's answer becomes a flow fact.
    func testTheMicrophoneMappingCoversAllThreeStatuses() {
        let table: [(raw: MicrophoneAuthorizationStatus, expected: OnboardingMicrophone)] = [
            (.notDetermined, .notDetermined),
            (.denied, .denied),
            (.granted, .granted),
        ]
        for row in table {
            XCTAssertEqual(
                OnboardingPermissionReads.microphone(status: row.raw),
                row.expected,
                "\(row.raw) must map to \(row.expected)")
        }
    }

    // MARK: - The struct

    /// The seam's payload: a plain snapshot of the two current statuses, consumed by the
    /// reducer's entry and refresh paths.
    func testTheStructCarriesTheCurrentStatusesForTheReducer() {
        let reads = OnboardingPermissionReads(
            accessibility: .grantedNotArmed,
            microphone: .denied)
        XCTAssertEqual(reads.accessibility, .grantedNotArmed)
        XCTAssertEqual(reads.microphone, .denied)
        XCTAssertEqual(
            reads,
            OnboardingPermissionReads(accessibility: .grantedNotArmed, microphone: .denied),
            "the struct is a value: equal inputs fold to equal reads")
    }
}