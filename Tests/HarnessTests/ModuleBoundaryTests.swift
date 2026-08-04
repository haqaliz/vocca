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
    case packageRootNotFound(startingFrom: String)
    case noModulesDiscovered(sourcesRoot: String)
    case noSwiftFilesScanned(sourcesRoot: String)
    case missingExpectedModules(Set<String>)

    var description: String {
        switch self {
        case .packageRootNotFound(let path):
            return "Could not locate Package.swift by walking up from \(path)"
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
/// 3. `VoccaUI` imports only `VoccaCore` among Vocca modules.
/// 4. Only `VoccaNetworkProbe` imports `VoccaBootstrap`.
final class ModuleBoundaryTests: XCTestCase {
    private static let leafModules: Set<String> = [
        "VoccaAudio", "VoccaHotkey", "VoccaASR", "VoccaText", "VoccaInject", "VoccaSpeech",
    ]

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
    private static let expectedModules: Set<String> = leafModules.union([
        "VoccaCore", "VoccaUI", compositionRoot, permittedCompositionRootImporter,
    ])

    /// Leading tokens that can precede the `import` keyword itself: the `@testable` attribute
    /// and the SE-0409 access-level import modifiers. Order between them isn't fixed, so this
    /// is stripped in a loop rather than checked positionally.
    private static let importPrefixModifiers: Set<String> = [
        "@testable", "public", "internal", "package", "private", "fileprivate",
    ]

    /// Kind qualifiers usable after `import` for a scoped import, e.g. `import struct Mod.Type`.
    private static let importKindQualifiers: Set<String> = [
        "struct", "class", "enum", "protocol", "typealias", "func", "var", "let",
    ]

    /// Walks up from `filePath` until it finds the directory containing `Package.swift`,
    /// then returns that directory's `Sources` subdirectory. Never hardcodes an absolute path.
    private func findSourcesRoot(from filePath: String) throws -> URL {
        var dir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir.appendingPathComponent("Sources")
            }
            dir = dir.deletingLastPathComponent()
        }
        throw ModuleBoundaryTestError.packageRootNotFound(startingFrom: filePath)
    }

    private func swiftFiles(under root: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            results.append(url)
        }
        return results
    }

    /// Removes `//` line comments and `/* ... */` block comments from Swift source text before
    /// it is scanned for `import` lines, so a commented-out import is never counted as real.
    /// Block comments are treated as non-nested, which matches every file this package writes.
    private func stripComments(from source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        var inBlockComment = false
        while i < chars.count {
            if inBlockComment {
                if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "/" {
                    inBlockComment = false
                    i += 2
                } else {
                    if chars[i] == "\n" { result.append("\n") }
                    i += 1
                }
                continue
            }
            if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" {
                inBlockComment = true
                i += 2
                continue
            }
            if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" {
                    i += 1
                }
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// Extracts the module name from every `import` line in `file`, tolerating:
    /// - leading `@testable` / access-level modifiers (`public import`, `internal import`, ...)
    /// - kind-qualified imports (`import struct Mod.Type`, `import func Mod.f`, ...)
    /// - submodule imports (`import Mod.Submodule`) — only the leading component is the module
    private func importedModuleNames(in file: URL) throws -> [String] {
        let content = try String(contentsOf: file, encoding: .utf8)
        let withoutComments = stripComments(from: content)
        var result: [String] = []
        for rawLine in withoutComments.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            var tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)

            while let first = tokens.first, Self.importPrefixModifiers.contains(first) {
                tokens.removeFirst()
            }
            guard tokens.first == "import" else { continue }
            tokens.removeFirst()

            if let first = tokens.first, Self.importKindQualifiers.contains(first) {
                tokens.removeFirst()
            }
            guard let modulePath = tokens.first else { continue }

            let moduleName = modulePath.split(separator: ".").first.map(String.init) ?? modulePath
            result.append(moduleName)
        }
        return result
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
            let files = swiftFiles(under: moduleDir)
            scannedFileCount += files.count
            var imports: Set<String> = []
            for file in files {
                imports.formUnion(try importedModuleNames(in: file))
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
