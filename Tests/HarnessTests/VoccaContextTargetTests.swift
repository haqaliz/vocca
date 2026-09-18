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

/// Pins the `accessibility-context` aspect's module reservation as a manifest fact, not a
/// preference (`ARCHITECTURE.md:151` — `VoccaContext/` is the `accessibility-context` aspect's
/// module, the `ContextProvider` seam's real implementation): the `VoccaContext` target must be
/// declared in `Package.swift` as a product and a target, must depend on `VoccaCore` and on
/// nothing else among Vocca modules (the `ModuleBoundaryTests` rule 3 in its manifest-side twin —
/// an adapter implements a seam `VoccaCore` owns and imports nothing else among Vocca modules),
/// and the module directory must exist and hold Swift files.
///
/// Everything here is headless: no AX call, no grant, no focused application. The target's
/// dependencies are asserted against `swift package dump-package` output (the
/// ``PackageManifest`` reader) so the reading cannot drift from what SwiftPM itself believes,
/// and the product/target declaration against the manifest's raw text so a rename of either is
/// a reviewed edit, not a silent drift.
final class VoccaContextTargetTests: XCTestCase {

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

    /// The `VoccaContext` product and target must both be declared in `Package.swift`: the
    /// module reservation (`ARCHITECTURE.md:151`) is pinned as a fact, so a rename or a drop of
    /// either is a reviewed edit, not a silent drift.
    func testPackageSwiftDeclaresTheVoccaContextTarget() throws {
        let text = try manifestText()
        XCTAssertTrue(
            text.contains("name: \"VoccaContext\""),
            """
            Package.swift must declare the VoccaContext product and target. Without the \
            declaration the accessibility adapter cannot build and the ContextProvider seam has \
            no real implementation.
            """)
    }

    /// The `VoccaContext` target must depend on `VoccaCore` and on nothing else among Vocca
    /// modules — the adapter rule's manifest-side twin (`ModuleBoundaryTests` rule 3): an
    /// adapter exists to implement a seam `VoccaCore` owns, and importing any other Vocca
    /// module would point an adapter at another adapter.
    func testTheTargetDependsOnVoccaCoreAndNothingElseAmongVoccaModules() throws {
        let target = try XCTUnwrap(
            try manifest().targets["VoccaContext"],
            "Package.swift must declare a VoccaContext target")
        XCTAssertEqual(
            target.dependencies, ["VoccaCore"],
            """
            The VoccaContext target's dependencies must be exactly [VoccaCore]. Declared: \
            \(target.dependencies.sorted()). The adapter implements the ContextProvider seam \
            the core owns, and the module-boundary rule admits no other Vocca import.
            """)
    }

    /// The `VoccaBootstrap` target must depend on `VoccaContext`: the composition root wires
    /// the modules together, so the context adapter and its consent store must be reachable
    /// from it or the app cannot compose them — the `KokoroDependencyTests`
    /// `testVoccaBootstrapTargetDependsOnVoccaSpeech` precedent, for the C12 module. The root
    /// is the one module permitted to import adapters (`ARCHITECTURE.md` §2); this test pins
    /// that the permission is *taken*.
    func testVoccaBootstrapTargetDependsOnVoccaContext() throws {
        let target = try XCTUnwrap(
            try manifest().targets["VoccaBootstrap"],
            "Package.swift must declare a VoccaBootstrap target")
        XCTAssertTrue(
            target.dependencies.contains("VoccaContext"),
            """
            The VoccaBootstrap target's dependencies must include VoccaContext. Declared: \
            \(target.dependencies.sorted()). The composition root wires the modules together, \
            and the context adapter reaches the app only through it.
            """)
    }

    /// The module directory must exist and hold at least one `.swift` file — the boundary
    /// tests' existence claim, spelled for this module: a vacuous scan (a directory with no
    /// Swift files, or no directory at all) is the failure mode this check exists to prevent.
    func testTheModuleDirectoryExistsWithSwiftFiles() throws {
        let moduleDirectory = try packageRoot
            .appendingPathComponent("Sources/VoccaContext", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: moduleDirectory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "Sources/VoccaContext must exist as a directory — the module the aspect ships in")
        let files = SwiftSourceScanner.swiftFiles(under: moduleDirectory)
        XCTAssertFalse(
            files.isEmpty,
            "Sources/VoccaContext must hold at least one .swift file — an empty directory would "
                + "pass the boundary rules vacuously")
    }
}