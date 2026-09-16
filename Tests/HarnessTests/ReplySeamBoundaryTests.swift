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
private enum ReplySeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                The reply seam's module directory does not exist at \(expectedAt). The reply \
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

/// The reply-seam family lint (`reply-seam` plan Phase 3): **within `VoccaCore`, only the three
/// files of `Reply/` may name the reply families — and each implementation name may appear in
/// exactly its own file.**
///
/// The same shape as the Kokoro runtime confinement (`KokoroSeamBoundaryTests`) and its AVFAudio
/// sibling (`SpeechSeamBoundaryTests`): the seam lives in Core, everything *decided* about reply
/// generation lives above it in the seam's vocabulary, and this lint is what keeps a caller from
/// branching on an implementation it cannot name outside the permitted files — a second file
/// naming a family means a decision (or a reply path) has moved somewhere CI cannot see.
///
/// The families are the identifier prefixes below — a prefix rule, so every member of each
/// family is covered by construction:
///
/// - `ReplyGenerator` (the seam itself): the protocol file and the two files whose
///   conformances must name it;
/// - `EchoReplyGenerator` (the shipped default): exactly one file;
/// - `AcknowledgmentReplyGenerator` (the second implementation): exactly one file.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the families to explain what
/// is confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *type in code* cannot appear without a
/// reviewed edit to the permitted table below.
///
/// `converse-wiring` composes the generator in `VoccaBootstrap`, which is **not** in this scan
/// root — no amendment is needed from it; only a future file *inside VoccaCore* naming a family
/// requires a reviewed row edit.
final class ReplySeamBoundaryTests: XCTestCase {

    /// The module the seam lives in — the scan root.
    private static let seamModuleRoot = "VoccaCore"

    /// The files allowed to name each family, relative to ``seamModuleRoot``.
    ///
    /// **One row per family, and nothing else ever joins a permitted set.**
    private static let families: [(name: String, permitted: Set<String>)] = [
        (
            name: "ReplyGenerator",
            permitted: [
                "Reply/ReplyGenerator.swift",
                "Reply/EchoReplyGenerator.swift",
                "Reply/AcknowledgmentReplyGenerator.swift",
            ]
        ),
        (name: "EchoReplyGenerator", permitted: ["Reply/EchoReplyGenerator.swift"]),
        (name: "AcknowledgmentReplyGenerator", permitted: ["Reply/AcknowledgmentReplyGenerator.swift"]),
    ]

    /// Every occurrence of a family identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedEchoReplyGeneratorUse``.
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
            throw ReplySeamTestError.noSwiftFilesScanned(under: root.path)
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
    func testOnlyTheReplyFilesInVoccaCoreMayNameTheReplyFamilies() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ReplySeamTestError.seamDirectoryMissing(expectedAt: root.path)
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

    /// The lint's negative control for the shipped default: planted source is caught — in the
    /// shapes a leaked use would actually take.
    func testTheLintDetectsAPlantedEchoReplyGeneratorUse() {
        let source = """
            public struct Leak {
                public let generator = EchoReplyGenerator()
                public func reply(to text: String) -> String {
                    EchoReplyGenerator().reply(to: text)
                }
            }
            """
        let identifiers = Self.familyIdentifiers("EchoReplyGenerator", inSource: source)
        XCTAssertEqual(
            identifiers, ["EchoReplyGenerator", "EchoReplyGenerator"],
            "the detector must find every planted use — the construction and the decision point")
    }

    /// The lint's negative control for the second implementation — the twin of the planted
    /// `EchoReplyGenerator` test.
    func testTheLintDetectsAPlantedAcknowledgmentReplyGeneratorUse() {
        let source = """
            public struct Leak {
                public var generator: AcknowledgmentReplyGenerator?
            }
            """
        let identifiers = Self.familyIdentifiers("AcknowledgmentReplyGenerator", inSource: source)
        XCTAssertEqual(
            identifiers, ["AcknowledgmentReplyGenerator"],
            "the detector must find the planted type")
    }

    /// A doc comment may name the families — the scanner strips comments, which is what lets the
    /// seam's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheFamiliesDoesNotTripTheLint() {
        let source = """
            /// The three files in `Sources/VoccaCore/Reply` permitted to name ReplyGenerator,
            /// EchoReplyGenerator and AcknowledgmentReplyGenerator — the seam holds the slot, and
            /// everything decided about reply generation lives above it.
            import VoccaCore
            """
        for family in Self.families {
            XCTAssertTrue(
                Self.familyIdentifiers(family.name, inSource: source).isEmpty,
                "comments must be stripped before the scan")
        }
    }
}