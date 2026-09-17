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
private enum ConverseSeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                The Core module's directory does not exist at \(expectedAt). The ConversePhase \
                confinement is asserted by scanning the source tree; if the module has moved or \
                been renamed, this lint enforces nothing.
                """
        case .noSwiftFilesScanned(let under):
            return """
                No .swift files were found under \(under) — the confinement was not evaluated \
                against anything. That is the vacuous green this check exists to prevent, so it \
                is a failure.
                """
        }
    }
}

/// The `ConversePhase` family lint (`dual-mode` widget-converse Phase 4): **within `VoccaCore`,
/// exactly one file may name the `ConversePhase` identifier family — `WidgetProjection.swift`.**
///
/// The same shape as the `KokoroSeamBoundaryTests`/`SpeechSeamBoundaryTests` family lints: a
/// second definition of the phase vocabulary, or a drifted use of it, means a decision about the
/// converse state has moved somewhere CI cannot see. `ConversePhase` lives beside
/// `WidgetState`/`WidgetProjection` in one file — the declaration, the `WidgetState.conversing`
/// case that names it, and the `project(turnState:)` leg that maps it — and nothing else in
/// `VoccaCore` may name it.
///
/// `converse-wiring` folds `project(turnState:)` in `VoccaBootstrap`, which is **outside this
/// scan root** — no amendment is needed from it. A future file *inside* `VoccaCore` naming the
/// family requires a reviewed row edit to the permitted list below; that is the point of the
/// lint (the `KokoroSeamBoundaryTests` doctrine).
final class WidgetConverseSeamBoundaryTests: XCTestCase {

    /// The module the seam lives in — the scan root.
    private static let seamModuleRoot = "VoccaCore"

    /// The one file allowed to name the `ConversePhase` family, relative to ``seamModuleRoot``.
    ///
    /// **One entry, and nothing else ever joins it.**
    private static let filesPermittedToNameTheFamily: Set<String> = [
        "WidgetProjection.swift"
    ]

    /// The identifier prefixes that constitute the family: the phase type itself — a prefix rule,
    /// so every member is covered by construction.
    private static let forbiddenIdentifierPrefixes = [
        "ConversePhase"
    ]

    /// Every occurrence of a forbidden identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedConversePhaseUse``.
    private static func familyIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + forbiddenIdentifierPrefixes.joined(separator: "|")
            + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    /// Every sighting under the seam's module root, honouring `permitted`.
    private func sightings(under root: URL) throws -> [String: [String]] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ConverseSeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var byFile: [String: [String]] = [:]
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            let identifiers = Self.familyIdentifiers(inSource: source)
            if !identifiers.isEmpty {
                byFile[relative] = identifiers
            }
        }
        return byFile
    }

    /// The whole of the confinement: every sighting sits in the permitted file, and the
    /// permitted file is the only one permitted.
    ///
    /// Two independent claims, because either one failing alone still passes a one-sided check:
    /// "no other file names the family" passes if the permitted file *also* lost its
    /// declaration (the family used everywhere else — vacuous), and "the permitted file names
    /// the family" passes if three files do (the seam has sprung a leak).
    func testExactlyOneFileInVoccaCoreMayNameTheConversePhaseFamily() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ConverseSeamTestError.seamDirectoryMissing(expectedAt: root.path)
        }
        let sightings = try sightings(under: root)

        let offenders = sightings.keys.filter { !Self.filesPermittedToNameTheFamily.contains($0) }
        XCTAssertTrue(
            offenders.isEmpty,
            "the ConversePhase family is named outside the permitted file: \(offenders.sorted())")

        let permitted = Self.filesPermittedToNameTheFamily
        XCTAssertFalse(
            permitted.isEmpty,
            "the permitted list must not be empty — an empty list passes 'no file names it' vacuously")
        for file in permitted {
            XCTAssertFalse(
                sightings[file]?.isEmpty ?? true,
                "the permitted file must actually name the family — a permitted file that does not "
                    + "means the family moved somewhere else and the lint cannot see it")
        }
        XCTAssertEqual(
            sightings.count, permitted.count,
            "exactly the permitted set may name the family, got \(sightings.keys.sorted())")
    }

    /// The lint's negative control: planted source is caught — the family, in the shapes a
    /// leaked declaration would actually use them.
    func testTheLintDetectsAPlantedConversePhaseUse() {
        let source = """
            import VoccaCore

            public enum Leak {
                public let phase: ConversePhase
                public func phaseName(_ phase: ConversePhase) -> String { "x" }
            }
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers,
            ["ConversePhase", "ConversePhase"],
            "the detector must find every planted family member")
    }

    /// A doc comment may name the family — the scanner strips comments, which is what lets the
    /// permitted file's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheFamilyDoesNotTripTheLint() {
        let source = """
            /// The converse vocabulary: ConversePhase is declared in this file and nowhere else
            /// in VoccaCore — the widget-converse seam lint pins the family to WidgetProjection.swift.
            import VoccaCore
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }
}