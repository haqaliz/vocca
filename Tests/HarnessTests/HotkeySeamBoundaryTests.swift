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

import XCTest

/// Acceptance H7, as amended by the injection-adapters aspect: **no CoreGraphics event type
/// escapes a seam's one permitted implementation file.**
///
/// The seam is the reason this aspect is testable at all. `CGEvent.tapCreate` returns `nil` without
/// an Accessibility grant and no hosted runner can be granted one, so anything phrased in terms of
/// `CGEvent` is untestable *forever* rather than untested for now. `HotkeyEventSource` yields plain
/// `RawKeyEvent` values and the flag translation takes a `UInt64`, and that is what puts every
/// branch worth testing on the reachable side.
///
/// The rule is therefore not "`VoccaHotkey` may not speak CoreGraphics" — it is an adapter, it must
/// — but "**one file per seam may**". The tap seam's one file is ``CGEventTapSource``; the keystroke
/// seam's is `VoccaInject`'s keystroke adapter. Both halves of the injection loop — reading the
/// keyboard and writing to it — are seams with exactly one permitted file, and everything else in
/// every module still takes and returns integers and enum values only, which is what keeps the
/// classification, the flag translation and the whole health policy on the reachable side.
///
/// ## Where the rules live
///
/// The per-seam table and every rule that consumes it moved to
/// ``InjectionSeamBoundaryTests`` with the amendment: the permitted-file table keyed by seam
/// (`tap`, `keystroke`), the tree-wide scan against its union, the per-seam count test
/// (`testEachSeamPermitsExactlyOneFile` — the successor of this file's
/// `testAtMostOneFileMayNameEventTypes`, replaced rather than weakened), the two-sided pins, the
/// laundering-route rules and every positive control. Nothing in this file is duplicated there.
///
/// What stays here is the tap seam's own module guard: ``testTheScanReachesTheAdapterModuleItIsMeantToPolice``
/// names a specific `VoccaHotkey` file, so it belongs to the seam it polices rather than to the
/// table.
final class HotkeySeamBoundaryTests: XCTestCase {

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    // MARK: - The tap seam's vacuity guard

    /// The lint's own vacuity guard, stated as a fact rather than assumed: files were scanned, and
    /// the file this phase actually added was one of them.
    ///
    /// The table's other half is guarded by ``InjectionSeamBoundaryTests``' per-seam directory
    /// check; this one names the tap module's flag translation because it is the file whose very
    /// existence this lint exists to keep covered.
    func testTheScanReachesTheAdapterModuleItIsMeantToPolice() throws {
        let root = try sourcesRoot()
        let scanned = SwiftSourceScanner.swiftFiles(under: root)
            .map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }

        XCTAssertTrue(
            scanned.contains("VoccaHotkey/HotkeyFlagTranslation.swift"),
            """
            The flag translation was not among the \(scanned.count) files scanned. Either it has \
            been renamed and this lint no longer covers it, or the scan is not reaching \
            VoccaHotkey at all.
            """)
    }
}
