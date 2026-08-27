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

import AVFoundation
import VoccaAudio
import VoccaCore
import XCTest

/// The microphone-permission adapter's tested half (`first-run-permissions` A2, PRD M5/M5b):
/// the pure translation from the system's 4-state answer to the raw 3-state status. The reads
/// themselves — `authorizationStatus()` and `requestAccess()` — are executed by nothing in CI
/// (no TCC grant on a hosted runner, and the prompt is a window-server interaction); this file
/// pins the one place a judgment row exists.
final class MicrophoneAuthorizationTests: XCTestCase {

    /// The four system answers, all four rows. `.restricted` (parental controls / MDM) is the
    /// one judgment row: it is a denial the user cannot lift from the pane, so it reads as
    /// `.denied` — the M2 denial surface is the honest rendering for it, and the flow must
    /// never claim a restricted microphone is merely undecided.
    func testTheFourSystemAnswersMapToTheThreeRawStatuses() {
        XCTAssertEqual(MicrophoneAuthorization.status(from: .notDetermined), .notDetermined)
        XCTAssertEqual(MicrophoneAuthorization.status(from: .restricted), .denied)
        XCTAssertEqual(MicrophoneAuthorization.status(from: .denied), .denied)
        XCTAssertEqual(MicrophoneAuthorization.status(from: .authorized), .granted)
    }

    /// The raw status → the reducer's vocabulary is the Core seam's job (A2), and the adapter
    /// never maps it: `OnboardingPermissionReads.microphone(status:)` is the one place the
    /// adapter's answer becomes a flow fact — pinned here so the two seams meet in the test
    /// that owns the boundary.
    func testTheRawStatusesMapToTheReducersVocabularyThroughTheCoreSeam() {
        XCTAssertEqual(
            OnboardingPermissionReads.microphone(status: .notDetermined),
            .notDetermined)
        XCTAssertEqual(OnboardingPermissionReads.microphone(status: .denied), .denied)
        XCTAssertEqual(OnboardingPermissionReads.microphone(status: .granted), .granted)
    }

    /// The request surface, pinned by reference — never by execution: calling it would land a
    /// real TCC prompt on the machine running the suite, which is the moment M5b says the flow
    /// controls, not CI.
    func testTheRequestSurfaceExists() {
        let request: () async -> Bool = MicrophoneAuthorization.requestAccess
        _ = request
    }
}