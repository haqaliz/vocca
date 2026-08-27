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

import VoccaUI
import XCTest

/// The System Settings pane seam (`first-run-permissions` A2): the two frozen pane paths and the
/// one open function, pinned here — the strings are **user-visible navigation targets**, lifted
/// out of `AppBootstrap.swift:441-446` (PRD M1) so the smoke rows can check them, and a drift in
/// either would send a user to the wrong privacy pane.
///
/// The seam itself is executed by nothing in CI (the `MenuBarItem` precedent: window-server
/// glue — opening a pane is a window-server action a hosted runner cannot perform and must not
/// fake), so this suite pins the data byte-for-byte and the surface by reference, never by
/// execution.
final class SystemSettingsPaneTests: XCTestCase {

    // MARK: - The two frozen paths

    /// The Accessibility pane — where the user must add Vocca themselves, because macOS will not
    /// prompt for this grant on an app's behalf (`ARCHITECTURE.md:603`).
    func testTheAccessibilityPanePathIsFrozenByteForByte() {
        XCTAssertEqual(
            SystemSettingsPane.accessibilityPanePath,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// The Microphone pane — the exact toggle the M2 denial screen names.
    func testTheMicrophonePanePathIsFrozenByteForByte() {
        XCTAssertEqual(
            SystemSettingsPane.microphonePanePath,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// **No duplicated constants**: both frozen paths live in exactly the seam's file (and this
    /// pinning test), nowhere else in `Sources/` or `Tests/` — the PRD M1 lift, pinned two-sided
    /// the ``WarmStartRatioTests`` single-source-scan way. A copy re-planted in `AppBootstrap`
    /// (or anywhere else) is a second source of truth for a navigation target.
    func testTheFrozenPathsLiveInExactlyTheOneSourceFile() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let namedFile = "SystemSettingsPane.swift"
        let pinningTest = "SystemSettingsPaneTests.swift"
        let paths = [
            SystemSettingsPane.accessibilityPanePath,
            SystemSettingsPane.microphonePanePath,
        ]

        var sightings: [String: Int] = [:]
        for tree in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")] {
            for file in SwiftSourceScanner.swiftFiles(under: tree) {
                let content = try String(contentsOf: file, encoding: .utf8)
                let stripped = SwiftSourceScanner.stripComments(from: content)
                for path in paths where stripped.contains(path) {
                    sightings[file.lastPathComponent, default: 0] += 1
                }
            }
        }

        XCTAssertFalse(sightings.isEmpty, "vacuity guard: the scan saw no files at all")
        XCTAssertEqual(
            Set(sightings.keys), [namedFile, pinningTest],
            "the pane paths must live in exactly the named seam and its pinning test, got: \(sightings)")
        XCTAssertEqual(
            sightings[namedFile], 2,
            "both paths must exist in the seam's own file — the vacuity guard's second direction")
    }

    // MARK: - The seam surface

    /// The seam's surface is the two constants plus the one open function — pinned by reference,
    /// never by execution: calling it would open a real System Settings pane on the machine
    /// running the suite, which is the window-server action CI cannot perform and must not fake.
    @MainActor
    func testTheOpenFunctionIsTheSeamSurface() {
        let opener: @MainActor (String) -> Void = SystemSettingsPane.open(at:)
        _ = opener
    }

    /// The relaunch adapter's surface (`first-run-permissions` M3), pinned beside the pane seam:
    /// `[Restart Vocca]` must have something to call when the M5c middle state offers it, and a
    /// relaunch is exactly as unexecutable in CI as an open pane is.
    @MainActor
    func testTheRelaunchSurfaceExists() {
        let relaunch: @MainActor () -> Void = AppRelaunch.relaunch
        _ = relaunch
    }
}