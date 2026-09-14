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

/// Pins the kokoro-binding unit's dependency decision as a manifest fact, not a preference
/// (`docs/planning/kokoro-binding/port-vetting/spec.md`): the `KokoroCoreML` product of the
/// `kokoro-coreml` package (Jud/kokoro-coreml, Apache-2.0, v0.11.2) must be declared in
/// `Package.swift` and be the `VoccaSpeech` target's dependency, and the composition root
/// (`VoccaBootstrap`) must depend on `VoccaSpeech` for the speech modules to reach the app.
///
/// The URL is asserted against the manifest's raw text (SwiftPM encodes package-level
/// dependencies nowhere the `PackageManifest` dump helper decodes — it parses targets and
/// products only), while the target edges are asserted against `swift package dump-package`
/// output so the reading cannot drift from what SwiftPM itself believes. Everything here is
/// headless: no model, no network, no build of the port.
final class KokoroDependencyTests: XCTestCase {

    /// The package root, located the way every suite in `HarnessTests` locates it.
    private var packageRoot: URL {
        get throws {
            try PackageRootLocator.find(from: #filePath)
        }
    }

    /// `Package.swift` read as text — the only place SwiftPM records the package-level
    /// dependency URLs, which `PackageManifest` deliberately does not decode.
    private func manifestText() throws -> String {
        try String(
            contentsOf: try packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    }

    /// The manifest the way SwiftPM itself sees it, for the target-dependency edges.
    private func manifest() throws -> PackageManifest {
        try PackageManifest.load(packageRoot: try packageRoot)
    }

    /// The `kokoro-coreml` package URL must be declared in `Package.swift`: the dependency
    /// decision is pinned as a fact, so a rename or a repoint of the source is a reviewed
    /// edit, not a silent drift.
    func testPackageDeclaresTheKokoroCoreMLPackageURL() throws {
        let text = try manifestText()
        XCTAssertTrue(
            text.contains("https://github.com/Jud/kokoro-coreml.git"),
            """
            Package.swift must declare the kokoro-coreml package URL \
            (https://github.com/Jud/kokoro-coreml.git). Without the package the KokoroCoreML \
            product cannot resolve and the engine binding has nothing to build on.
            """)
    }

    /// The `VoccaSpeech` target must depend on the `KokoroCoreML` product of the
    /// `kokoro-coreml` package — the seam the engine binding will speak to lives in
    /// `VoccaSpeech`, so the port must be reachable from it.
    func testVoccaSpeechTargetDependsOnTheKokoroCoreMLProduct() throws {
        let target = try XCTUnwrap(
            try manifest().targets["VoccaSpeech"],
            "Package.swift must declare a VoccaSpeech target")
        XCTAssertTrue(
            target.dependencies.contains("KokoroCoreML"),
            """
            The VoccaSpeech target's dependencies must include the KokoroCoreML product. \
            Declared: \(target.dependencies.sorted()). The engine binding compiles only if \
            the port's product is a dependency of the module that will use it.
            """)
    }

    /// The `VoccaBootstrap` target must depend on `VoccaSpeech`: the composition root wires
    /// the modules together, so the speech adapter must be reachable from it or the app
    /// cannot construct a synthesizer.
    func testVoccaBootstrapTargetDependsOnVoccaSpeech() throws {
        let target = try XCTUnwrap(
            try manifest().targets["VoccaBootstrap"],
            "Package.swift must declare a VoccaBootstrap target")
        XCTAssertTrue(
            target.dependencies.contains("VoccaSpeech"),
            """
            The VoccaBootstrap target's dependencies must include VoccaSpeech. Declared: \
            \(target.dependencies.sorted()). The composition root wires the modules together, \
            and the speech modules reach the app only through it.
            """)
    }
}