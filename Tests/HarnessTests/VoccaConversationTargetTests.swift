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

/// Pins the `history-store` aspect's module reservation as a manifest fact, not a preference
/// (`plan_20261011.md` D1 — a new adapter module `VoccaConversation`, because rooting the
/// FileManager seam in the composition root would have forced permitting `AppBootstrap.swift`,
/// which already names `FileManager`): the `VoccaConversation` target must be declared in
/// `Package.swift` as a product and a target, must depend on `VoccaCore` and on nothing else
/// among Vocca modules (the `ModuleBoundaryTests` rule 3 in its manifest-side twin — an adapter
/// implements a seam `VoccaCore` owns and imports nothing else among Vocca modules), the
/// composition root must be able to compose it, and the module directory must exist and hold
/// Swift files.
///
/// Everything here is headless: no file is written, no store is constructed. The target's
/// dependencies are asserted against `swift package dump-package` output (the
/// ``PackageManifest`` reader) so the reading cannot drift from what SwiftPM itself believes,
/// and the product/target declaration against the manifest's raw text so a rename of either is
/// a reviewed edit, not a silent drift.
final class VoccaConversationTargetTests: XCTestCase {

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

    /// The `VoccaConversation` product and target must both be declared in `Package.swift`: the
    /// module reservation (`plan_20261011.md` D1) is pinned as a fact, so a rename or a drop of
    /// either is a reviewed edit, not a silent drift.
    func testPackageSwiftDeclaresTheVoccaConversationTarget() throws {
        let text = try manifestText()
        XCTAssertTrue(
            text.contains("name: \"VoccaConversation\""),
            """
            Package.swift must declare the VoccaConversation product and target. Without the \
            declaration the conversation store cannot build and the ConversationRecording seam \
            has no real implementation.
            """)
    }

    /// The `VoccaConversation` target must depend on `VoccaCore` and on nothing else among Vocca
    /// modules — the adapter rule's manifest-side twin (`ModuleBoundaryTests` rule 3): an
    /// adapter exists to implement a seam `VoccaCore` owns, and importing any other Vocca
    /// module would point an adapter at another adapter.
    func testTheTargetDependsOnVoccaCoreAndNothingElseAmongVoccaModules() throws {
        let target = try XCTUnwrap(
            try manifest().targets["VoccaConversation"],
            "Package.swift must declare a VoccaConversation target")
        XCTAssertEqual(
            target.dependencies, ["VoccaCore"],
            """
            The VoccaConversation target's dependencies must be exactly [VoccaCore]. Declared: \
            \(target.dependencies.sorted()). The adapter implements the ConversationRecording \
            seam the core owns, and the module-boundary rule admits no other Vocca import.
            """)
    }

    /// The `VoccaBootstrap` target must depend on `VoccaConversation`: the composition root wires
    /// the modules together, so the conversation store must be reachable from it or the app
    /// cannot compose it — the `VoccaContextTargetTests`
    /// `testVoccaBootstrapTargetDependsOnVoccaContext` precedent. The root is the one module
    /// permitted to import adapters (`ARCHITECTURE.md` §2); this test pins that the permission
    /// is *taken*.
    func testVoccaBootstrapTargetDependsOnVoccaConversation() throws {
        let target = try XCTUnwrap(
            try manifest().targets["VoccaBootstrap"],
            "Package.swift must declare a VoccaBootstrap target")
        XCTAssertTrue(
            target.dependencies.contains("VoccaConversation"),
            """
            The VoccaBootstrap target's dependencies must include VoccaConversation. Declared: \
            \(target.dependencies.sorted()). The composition root wires the modules together, \
            and the conversation store reaches the app only through it.
            """)
    }

    /// The `HarnessTests` target must depend on `VoccaConversation`.
    ///
    /// The module is reachable from the tests transitively through the probe, exactly as every
    /// adapter module is — but the edge is declared and pinned anyway, the
    /// `VoccaActionsTargetTests.testTheTestTargetDependsOnVoccaActions` shape: the dependency
    /// exists so a later wiring change cannot quietly drop the only edge that makes the module
    /// directly reachable from CI.
    func testTheTestTargetDependsOnVoccaConversation() throws {
        let target = try XCTUnwrap(
            try manifest().targets["HarnessTests"],
            "Package.swift must declare a HarnessTests target")
        XCTAssertTrue(
            target.dependencies.contains("VoccaConversation"),
            """
            HarnessTests must depend on VoccaConversation. Declared: \
            \(target.dependencies.sorted()).
            """)
    }

    /// The module directory must exist and hold at least one `.swift` file — the boundary
    /// tests' existence claim, spelled for this module: a vacuous scan (a directory with no
    /// Swift files, or no directory at all) is the failure mode this check exists to prevent.
    func testTheModuleDirectoryExistsWithSwiftFiles() throws {
        let moduleDirectory = try packageRoot
            .appendingPathComponent("Sources/VoccaConversation", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: moduleDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "Sources/VoccaConversation must exist as a directory — the module the aspect ships in")
        let files = SwiftSourceScanner.swiftFiles(under: moduleDirectory)
        XCTAssertFalse(
            files.isEmpty,
            "Sources/VoccaConversation must hold at least one .swift file — an empty directory "
                + "would pass the boundary rules vacuously")
    }
}