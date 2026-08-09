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

/// Raised when the `Sources/` tree cannot be scanned meaningfully: the package root is
/// missing, nothing was found to scan, or an expected module directory is absent.
private enum ModuleBoundaryTestError: Error, CustomStringConvertible {
    case noModulesDiscovered(sourcesRoot: String)
    case noSwiftFilesScanned(sourcesRoot: String)
    case missingExpectedModules(Set<String>)

    var description: String {
        switch self {
        case .noModulesDiscovered(let root):
            return
                "No module directories were found under \(root) — the boundary rules were not evaluated against anything"
        case .noSwiftFilesScanned(let root):
            return
                "No .swift files were found under \(root) — the boundary rules were not evaluated against anything"
        case .missingExpectedModules(let names):
            return
                "Expected module directories missing under Sources/: \(names.sorted().joined(separator: ", "))"
        }
    }
}

/// Enforces the module dependency rules for the Vocca package's `Sources/` tree:
///
/// 1. No leaf module imports `VoccaCore`.
/// 2. No leaf module imports another leaf module.
/// 3. An **adapter** module imports `VoccaCore` and nothing else among Vocca modules.
/// 4. `VoccaUI` imports only `VoccaCore` among Vocca modules.
/// 5. Only `VoccaNetworkProbe` imports `VoccaBootstrap`.
///
/// ## Why rule 3 exists, and why `VoccaHotkey` moved under it
///
/// `ARCHITECTURE.md` used to declare the graph as `VoccaCore → {leaves}` — the core depending on
/// the leaves — while ``CoreBoundaryTests`` enforces that `VoccaCore` imports **nothing at all**.
/// Those two were never consistent: the declared arrow could not be realised without an import the
/// other lint forbids, so it never was. Nobody noticed, because every leaf was a placeholder with
/// nothing to depend on and nothing to be depended upon.
///
/// `hotkey-source` is the first time a leaf has to *implement* a seam the core owns — the flag
/// translation returns a ``ModifierSet``, and `ModifierSet.swift` pins the founder's decision that
/// the translation belongs in `VoccaHotkey`. That made the contradiction load-bearing, and it was
/// resolved in favour of ports-and-adapters: the core owns the seams and imports nothing, adapters
/// depend on the core to implement them. `VoccaCore` importing an adapter would be the actual
/// architectural error — it is what would drag `CGEvent` and `AVAudioEngine` into the one module
/// that must have neither, and make every branch below them untestable forever.
///
/// So `VoccaHotkey` is no longer a leaf. It is not thereby *unconstrained*: rule 3 is rule 2 with
/// exactly one import added, so an adapter importing `VoccaAudio` is still caught — see
/// ``testTheAdapterRuleDetectsAnAdapterImportingALeafModule``, which proves it against a mutation
/// rather than asserting it.
///
/// `VoccaAudio` will need the same move when `SessionAudioSource` gets a real implementation. It
/// is deliberately still a leaf today: it imports nothing, so moving it now would loosen a rule
/// that currently holds for free.
final class ModuleBoundaryTests: XCTestCase {
    private static let leafModules: Set<String> = [
        "VoccaAudio", "VoccaText", "VoccaInject", "VoccaSpeech",
    ]

    /// Modules that implement a seam `VoccaCore` owns, and may therefore import it.
    ///
    /// Membership is a deliberate, reviewed edit — moving a module here is how a leaf stops being
    /// bound by rule 1, so it must be visible in a diff rather than inferred from what a module
    /// happens to import today.
    ///
    /// `VoccaASR` joined in the local-asr capability: it implements the `ASREngine` seam (the
    /// Parakeet adapter) and its model store. The move is what lets it import `VoccaCore` — the
    /// engine's types live there — while the H8b lint keeps the SDK confined to one file.
    private static let adapterModules: Set<String> = ["VoccaHotkey", "VoccaASR"]

    /// The app's composition root. Depends on modules; nothing in the package may depend on it.
    private static let compositionRoot = "VoccaBootstrap"

    /// The one module allowed to import ``compositionRoot``, and required to.
    ///
    /// The probe drives `AppBootstrap.configure(_:)` on the default-configuration path, which is
    /// what puts the app's real start-up code inside the zero-network invariant. That import is
    /// therefore a fixture, not a dependency.
    private static let permittedCompositionRootImporter = "VoccaNetworkProbe"

    /// Every module directory this task's `Package.swift` is expected to declare. Used to
    /// catch a deleted/renamed module directory passing a rule by absence rather than fact.
    private static let expectedModules: Set<String> = leafModules.union(adapterModules).union([
        "VoccaCore", "VoccaUI", compositionRoot, permittedCompositionRootImporter,
    ])

    /// The package's `Sources` subdirectory. Never hardcodes an absolute path.
    private func findSourcesRoot(from filePath: String) throws -> URL {
        try PackageRootLocator.find(from: filePath).appendingPathComponent("Sources")
    }

    /// Maps each module directory name under `Sources/` to the set of module names it imports.
    /// Fails loudly (rather than passing vacuously) if the scan found no modules, no `.swift`
    /// files, or is missing a module directory this task is expected to have created.
    private func moduleImportMap() throws -> [String: Set<String>] {
        let sourcesRoot = try findSourcesRoot(from: #filePath)
        let moduleDirs = try FileManager.default.contentsOfDirectory(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey])

        var map: [String: Set<String>] = [:]
        var scannedFileCount = 0
        for moduleDir in moduleDirs {
            let isDir =
                (try? moduleDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let moduleName = moduleDir.lastPathComponent
            let files = SwiftSourceScanner.swiftFiles(under: moduleDir)
            scannedFileCount += files.count
            var imports: Set<String> = []
            for file in files {
                imports.formUnion(try SwiftSourceScanner.importedModuleNames(in: file))
            }
            map[moduleName] = imports
        }

        guard !map.isEmpty else {
            throw ModuleBoundaryTestError.noModulesDiscovered(sourcesRoot: sourcesRoot.path)
        }
        guard scannedFileCount > 0 else {
            throw ModuleBoundaryTestError.noSwiftFilesScanned(sourcesRoot: sourcesRoot.path)
        }
        let missing = Self.expectedModules.subtracting(map.keys)
        guard missing.isEmpty else {
            throw ModuleBoundaryTestError.missingExpectedModules(missing)
        }

        return map
    }

    func testNoLeafModuleImportsVoccaCore() throws {
        let map = try moduleImportMap()
        for leaf in Self.leafModules {
            let imports = map[leaf] ?? []
            XCTAssertFalse(
                imports.contains("VoccaCore"),
                "\(leaf) must not import VoccaCore, found imports: \(imports)")
        }
    }

    func testNoLeafModuleImportsAnotherLeafModule() throws {
        let map = try moduleImportMap()
        for leaf in Self.leafModules {
            let imports = map[leaf] ?? []
            let violations = imports.intersection(Self.leafModules.subtracting([leaf]))
            XCTAssertTrue(
                violations.isEmpty,
                "\(leaf) must not import other leaf modules, found: \(violations)")
        }
    }

    /// `VoccaBootstrap` is the composition root: it may depend on modules, and nothing in the
    /// package may depend on it. The only import of it is the network probe's, which is a fixture.
    ///
    /// SwiftPM refuses a *declared* cycle, so this looks redundant — and is not. An `import
    /// VoccaBootstrap` added to `Sources/VoccaAudio/Placeholder.swift` **with no declared
    /// dependency** compiles clean, because every target in a package builds against a shared
    /// module search path, and it passed this suite 3/3: the existing rules only forbid a leaf
    /// importing `VoccaCore` or another leaf. So the manifest was not the guard anyone assumed it
    /// was.
    ///
    /// Direction is what makes this safe to state now, rather than policy invented for modules that
    /// do not exist yet: the root wires everything together, so nothing it wires can point back at
    /// it without creating a cycle.
    ///
    /// The assertion is equality, not "no unexpected importers", so it also fails if the probe
    /// *stops* importing it — which is the mechanism that keeps the app's start-up path inside the
    /// zero-network invariant. Deleting that import is not something to discover later.
    func testOnlyTheNetworkProbeImportsTheCompositionRoot() throws {
        let map = try moduleImportMap()
        let importers = map
            .filter { $0.key != Self.compositionRoot && $0.value.contains(Self.compositionRoot) }
            .keys.sorted()

        XCTAssertEqual(
            importers, [Self.permittedCompositionRootImporter],
            """
            \(Self.compositionRoot) must be imported by \
            \(Self.permittedCompositionRootImporter) and by nothing else. Found: \
            \(importers.isEmpty ? "no importers at all" : importers.joined(separator: ", ")).
            Too many: it is the composition root — it wires the other modules together, so a module \
            importing it points a dependency backwards and creates a cycle. Note that SwiftPM will \
            not catch this for you: an undeclared import of it compiles clean via the shared module \
            search path.
            Too few: \(Self.permittedCompositionRootImporter) driving \
            AppBootstrap.configure(_:) is what places Vocca's real start-up code inside the \
            zero-network invariant. Without that import there is no coverage of it at all.
            """)
    }

    /// The rule itself, as a pure function over an import map, so that it can be shown to reject a
    /// violation as well as to accept the tree as it stands.
    ///
    /// Returns the Vocca modules `imports` names that an adapter is not allowed to name. Only
    /// `VoccaCore` is permitted, so this is rule 2 with one exemption — not an absence of a rule.
    private static func adapterImportViolations(
        imports: Set<String>, amongVoccaModules voccaModules: Set<String>
    ) -> Set<String> {
        imports.intersection(voccaModules).subtracting(["VoccaCore"])
    }

    /// Rule 3 against the real tree.
    ///
    /// Asserts membership too. An adapter that imports nothing satisfies the violation check
    /// vacuously, and an adapter that no longer exists satisfies it even more vacuously — so the
    /// module directory is required to be present (via ``expectedModules``) and the set of adapters
    /// is required to be non-empty, or this test is measuring an empty loop.
    func testAdapterModulesImportOnlyVoccaCoreAmongVoccaModules() throws {
        let map = try moduleImportMap()
        let voccaModuleNames = Set(map.keys)

        XCTAssertFalse(
            Self.adapterModules.isEmpty,
            "The adapter list is empty, so this rule was evaluated against nothing.")

        for adapter in Self.adapterModules {
            let imports = map[adapter] ?? []
            let violations = Self.adapterImportViolations(
                imports: imports, amongVoccaModules: voccaModuleNames)
            XCTAssertTrue(
                violations.isEmpty,
                """
                \(adapter) is an adapter: it may import VoccaCore, to implement a seam VoccaCore \
                owns, and no other Vocca module. Found: \(violations.sorted().joined(separator: ", ")). \
                Being an adapter lifts rule 1 only — it does not lift rule 2.
                """)
        }
    }

    /// The positive control for rule 3, and the thing that makes moving `VoccaHotkey` out of
    /// ``leafModules`` a *replacement* of coverage rather than a removal of it.
    ///
    /// Rule 2 used to forbid `VoccaHotkey` from importing another leaf. Rule 3 has to still forbid
    /// it, and a rule that has only ever been run against a tree that satisfies it is a rule nobody
    /// has watched work. So it is run here against a map that violates it, in both shapes that
    /// matter: another leaf, and the composition root.
    func testTheAdapterRuleDetectsAnAdapterImportingALeafModule() {
        let voccaModules: Set<String> = [
            "VoccaCore", "VoccaHotkey", "VoccaAudio", "VoccaUI", "VoccaBootstrap",
        ]

        XCTAssertEqual(
            Self.adapterImportViolations(
                imports: ["VoccaCore", "VoccaAudio"], amongVoccaModules: voccaModules),
            ["VoccaAudio"],
            "An adapter importing a leaf module must be reported, exactly as rule 2 reported it.")

        XCTAssertEqual(
            Self.adapterImportViolations(
                imports: ["VoccaCore", "VoccaBootstrap"], amongVoccaModules: voccaModules),
            ["VoccaBootstrap"],
            "An adapter importing the composition root points a dependency backwards.")

        XCTAssertEqual(
            Self.adapterImportViolations(
                imports: ["VoccaCore", "Foundation", "CoreGraphics"],
                amongVoccaModules: voccaModules),
            [],
            """
            System frameworks are not Vocca modules and must not be reported. An adapter exists to \
            speak to the system; a rule that flagged CoreGraphics here would be deleted within a \
            week, and rule 3 would go with it.
            """)
    }

    func testVoccaUIImportsOnlyVoccaCoreAmongVoccaModules() throws {
        let map = try moduleImportMap()
        let voccaModuleNames = Set(map.keys)
        let uiImports = map["VoccaUI"] ?? []
        let voccaImportsFromUI = uiImports.intersection(voccaModuleNames)
        XCTAssertTrue(
            voccaImportsFromUI.isSubset(of: ["VoccaCore"]),
            "VoccaUI must import only VoccaCore among Vocca modules, found: \(voccaImportsFromUI)")
    }
}
