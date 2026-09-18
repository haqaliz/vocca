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

/// Raised when the scan cannot be evaluated meaningfully, so that measuring nothing is a failure
/// rather than a pass.
private enum ContextSeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                The context seam's module directory does not exist at \(expectedAt). The context \
                family confinement is asserted by scanning the source tree; if the module has \
                moved or been renamed, this lint enforces nothing.
                """
        case .noSwiftFilesScanned(let under):
            return """
                No .swift files were found under \(under) — the confinement was not evaluated \
                against anything. That is the vacuous green this check exists to prevent, so it is \
                a failure.
                """
        }
    }
}

/// The context-seam family lint (`context-seam` plan Phase 3): **within `VoccaCore`, only the
/// three files of `Context/` may name the context families — and each implementation name may
/// appear in exactly its own file.**
///
/// The same shape as the reply confinement (`ReplySeamBoundaryTests`): the seam lives in Core,
/// everything *decided* about context resolution lives above it in the seam's vocabulary, and
/// this lint is what keeps a caller from branching on an implementation it cannot name outside
/// the permitted files — a second file naming a family means a decision (or a context path) has
/// moved somewhere CI cannot see.
///
/// The families are the identifier prefixes below — a prefix rule, so every member of each
/// family is covered by construction:
///
/// - `ContextProvider` (the seam itself): the protocol file and the file whose conformance
///   must name it;
/// - `ContextSnapshot` (the vocabulary): the vocabulary file, the seam's method signature, the
///   default's construction, and the two `byok-context-grant` files that type against it — the
///   ``GrantedContextSource`` seam's signature and the gate's truncation;
/// - `NullContext` (the shipped default): exactly one file.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the families to explain what
/// is confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *type in code* cannot appear without a
/// reviewed edit to the permitted table below.
///
/// The seam's second implementation, `AccessibilityContext`, is **expected** in the
/// `VoccaContext` module (`accessibility-context`'s aspect, `ARCHITECTURE.md:151,281`) —
/// outside this scan root, so its arrival needs no amendment here; `bootstrap-wiring` composes
/// the provider in `VoccaBootstrap`, also outside. Only a future file *inside `VoccaCore`*
/// naming a family requires a reviewed row edit.
final class ContextSeamBoundaryTests: XCTestCase {

    /// The module the seam lives in — the scan root.
    private static let seamModuleRoot = "VoccaCore"

    /// The files allowed to name each family, relative to ``seamModuleRoot``.
    ///
    /// **One row per family, and nothing else ever joins a permitted set.**
    private static let families: [(name: String, permitted: Set<String>)] = [
        (
            name: "ContextProvider",
            permitted: [
                "Context/ContextProvider.swift",
                "Context/NullContext.swift",
            ]
        ),
        (
            name: "ContextSnapshot",
            permitted: [
                "Context/ContextSnapshot.swift",
                "Context/ContextProvider.swift",
                "Context/NullContext.swift",
                "Context/GrantedContextSource.swift",
                "Context/ContextGrantGate.swift",
            ]
        ),
        (name: "NullContext", permitted: ["Context/NullContext.swift"]),
    ]

    /// Every occurrence of a family identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedContextProviderUse``.
    private static func familyIdentifiers(_ family: String, inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + family + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    /// Every sighting of `family` under the seam's module root, honouring `permitted`.
    private func sightings(of family: String, under root: URL) throws -> [String: [String]] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ContextSeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var byFile: [String: [String]] = [:]
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            let identifiers = Self.familyIdentifiers(family, inSource: source)
            if !identifiers.isEmpty {
                byFile[relative] = identifiers
            }
        }
        return byFile
    }

    /// The whole of the confinement, per family: every sighting sits in the permitted set, and
    /// the permitted set is the only one permitted.
    ///
    /// Two independent claims, because either one failing alone still passes a one-sided check:
    /// "no other file names the family" passes if the permitted file *also* lost its
    /// implementation (the family used everywhere else — vacuous), and "the permitted file names
    /// the family" passes if three files do (the seam has sprung a leak). The `sightings.count`
    /// equality is the third leg: exactly the permitted set may name the family.
    func testOnlyTheContextFilesInVoccaCoreMayNameTheContextFamilies() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ContextSeamTestError.seamDirectoryMissing(expectedAt: root.path)
        }

        for family in Self.families {
            let sightings = try sightings(of: family.name, under: root)

            let offenders = sightings.keys.filter { !family.permitted.contains($0) }
            XCTAssertTrue(
                offenders.isEmpty,
                "the \(family.name) family is named outside the permitted files: \(offenders.sorted())")

            XCTAssertFalse(
                family.permitted.isEmpty,
                "a permitted set must not be empty — an empty set passes 'no file names it' vacuously")
            for file in family.permitted {
                XCTAssertFalse(
                    sightings[file]?.isEmpty ?? true,
                    "a permitted file must actually name the family — a permitted file that does "
                        + "not means the family moved somewhere else and the lint cannot see it")
            }
            XCTAssertEqual(
                sightings.count, family.permitted.count,
                "exactly the permitted set may name the family, got \(sightings.keys.sorted())")
        }
    }

    /// The lint's negative control for the seam: planted source is caught — in the shapes a
    /// leaked use would actually take.
    func testTheLintDetectsAPlantedContextProviderUse() {
        let source = """
            public struct Leak {
                public var provider: ContextProvider?
                public func resolve() -> ContextSnapshot? {
                    provider?.resolveCurrent()
                }
            }
            """
        let identifiers = Self.familyIdentifiers("ContextProvider", inSource: source)
        XCTAssertEqual(
            identifiers, ["ContextProvider"],
            "the detector must find the planted type")
    }

    /// The lint's negative control for the shipped default — a second file branching on
    /// `NullContext` is a decision CI cannot see.
    func testTheLintDetectsAPlantedNullContextUse() {
        let source = """
            public struct Leak {
                public let provider = NullContext()
                public func resolve() -> ContextSnapshot {
                    NullContext().resolveCurrent()
                }
            }
            """
        let identifiers = Self.familyIdentifiers("NullContext", inSource: source)
        XCTAssertEqual(
            identifiers, ["NullContext", "NullContext"],
            "the detector must find every planted use — the construction and the decision point")
    }

    /// The lint's negative control for the vocabulary — a file that builds its own snapshot
    /// outside the seam's files is caught.
    func testTheLintDetectsAPlantedContextSnapshotUse() {
        let source = """
            public struct Leak {
                public let snapshot = ContextSnapshot(
                    bundleID: "com.example.App", windowTitle: nil, selectedText: nil)
            }
            """
        let identifiers = Self.familyIdentifiers("ContextSnapshot", inSource: source)
        XCTAssertEqual(
            identifiers, ["ContextSnapshot"],
            "the detector must find the planted type")
    }

    /// A doc comment may name the families — the scanner strips comments, which is what lets the
    /// seam's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheFamiliesDoesNotTripTheLint() {
        let source = """
            /// The three files in `Sources/VoccaCore/Context` permitted to name ContextProvider,
            /// ContextSnapshot and NullContext — the seam holds the slot, and everything decided
            /// about context resolution lives above it. AccessibilityContext is expected in the
            /// VoccaContext module, outside this scan root.
            import VoccaCore
            """
        for family in Self.families {
            XCTAssertTrue(
                Self.familyIdentifiers(family.name, inSource: source).isEmpty,
                "comments must be stripped before the scan")
        }
    }
}