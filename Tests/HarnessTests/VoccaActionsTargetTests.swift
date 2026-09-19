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
import XCTest

/// Pins the `audit-log` aspect's module as a manifest fact, not a preference (`ARCHITECTURE.md` —
/// `VoccaActions/` is the P4 action layer's module, and the audit log is its first resident): the
/// `VoccaActions` target must be declared in `Package.swift` as a product and a target, must
/// depend on `VoccaCore` and on nothing else among Vocca modules (the `ModuleBoundaryTests` rule 3
/// in its manifest-side twin), and the module directory must exist and hold Swift files.
///
/// Everything here is headless: no file is written, no store is constructed. The target's
/// dependencies are asserted against `swift package dump-package` output (the ``PackageManifest``
/// reader) so the reading cannot drift from what SwiftPM itself believes, and the product/target
/// declaration against the manifest's raw text so a rename of either is a reviewed edit rather
/// than a silent drift.
///
/// **The `VoccaBootstrap` leg its sibling suite has is deliberately absent.** `VoccaContext`
/// requires the composition root to depend on it, because the root composes the context provider.
/// This aspect wires nothing into the root — that is what keeps the G5 digest pin untouched — so
/// asserting such an edge here would pin a dependency the unit deliberately does not create.
final class VoccaActionsTargetTests: XCTestCase {

    /// The package root, located the way every suite in `HarnessTests` locates it.
    private var packageRoot: URL {
        get throws {
            try PackageRootLocator.find(from: #filePath)
        }
    }

    /// `Package.swift` read as text — the place SwiftPM records products and targets.
    private func manifestText() throws -> String {
        try String(
            contentsOf: try packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    }

    /// The manifest the way SwiftPM itself sees it, for the target-dependency edges.
    private func manifest() throws -> PackageManifest {
        try PackageManifest.load(packageRoot: try packageRoot)
    }

    /// The `VoccaActions` product and target must both be declared in `Package.swift`.
    func testPackageSwiftDeclaresTheVoccaActionsTarget() throws {
        let text = try manifestText()
        XCTAssertTrue(
            text.contains("name: \"VoccaActions\""),
            """
            Package.swift must declare the VoccaActions product and target. Without the \
            declaration the audit log cannot build, and the action spine has nowhere to record \
            what it decided.
            """)
    }

    /// The `VoccaActions` target must depend on `VoccaCore` and on **nothing else** — asserted by
    /// equality, not by containment.
    ///
    /// Containment would admit a transport dependency, a second adapter, or an SDK, each of which
    /// is exactly the change this unit exists to make expensive: the module is meant to hold a
    /// file and a vocabulary, and an adapter that imports another adapter has stopped implementing
    /// a seam the core owns.
    func testTheTargetDependsOnVoccaCoreAndNothingElse() throws {
        let target = try XCTUnwrap(
            try manifest().targets["VoccaActions"],
            "Package.swift must declare a VoccaActions target")
        XCTAssertEqual(
            target.dependencies, ["VoccaCore"],
            """
            The VoccaActions target's dependencies must be exactly [VoccaCore]. Declared: \
            \(target.dependencies.sorted()). The module records the vocabulary the core owns; the \
            module-boundary rule admits no other Vocca import, and PRD M8 forbids a transport \
            outright.
            """)
    }

    /// The `HarnessTests` target must depend on `VoccaActions`.
    ///
    /// Nothing else in the package depends on the module — this aspect wires nothing into the
    /// composition root, deliberately — so without this edge SwiftPM would not build it during
    /// `swift test`, and the audit suite would fail to compile rather than run. The assertion
    /// exists so that a later wiring change cannot quietly drop the only edge that makes the
    /// module reachable from CI.
    func testTheTestTargetDependsOnVoccaActions() throws {
        let target = try XCTUnwrap(
            try manifest().targets["HarnessTests"],
            "Package.swift must declare a HarnessTests target")
        XCTAssertTrue(
            target.dependencies.contains("VoccaActions"),
            """
            HarnessTests must depend on VoccaActions. Declared: \
            \(target.dependencies.sorted()). Nothing else in the package depends on the module, \
            so this edge is the whole of what makes it build under `swift test`.
            """)
    }

    /// The module directory must exist and hold at least one `.swift` file — the boundary tests'
    /// existence claim, spelled for this module: a vacuous scan (a directory with no Swift files,
    /// or no directory at all) is the failure mode this check exists to prevent, and it is why the
    /// directory and the manifest stanza land in the same commit.
    func testTheModuleDirectoryExistsWithSwiftFiles() throws {
        let moduleDirectory = try packageRoot
            .appendingPathComponent("Sources/VoccaActions", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: moduleDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "Sources/VoccaActions must exist as a directory — the module the aspect ships in")
        let files = SwiftSourceScanner.swiftFiles(under: moduleDirectory)
        XCTAssertFalse(
            files.isEmpty,
            "Sources/VoccaActions must hold at least one .swift file — an empty directory would "
                + "pass the boundary rules vacuously")
    }
}
