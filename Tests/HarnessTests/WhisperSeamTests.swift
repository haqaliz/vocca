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
private enum WhisperSeamTestError: Error, CustomStringConvertible {
    case sourcesDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .sourcesDirectoryMissing(let expectedAt):
            return """
                The Sources/ directory does not exist at \(expectedAt). The whisper C-ABI \
                confinement is asserted by scanning the source tree; if the repository layout has \
                changed, this lint enforces nothing.
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

/// The C3 seam lint for the second ASR engine (`whisper-engine` spec M6, `plan_20260810.md`
/// Phase 2): **exactly one file in `Sources/` may name the whisper.cpp C-ABI family — the
/// bridge, `WhisperCAPI.swift`.**
///
/// The same shape as H8b (`ParakeetSeamTests`): the Parakeet engine is the one file permitted to
/// speak FluidAudio, and the whisper bridge is the one file permitted to speak the whisper C ABI —
/// because everything *decided* about transcription lives above it, in `WhisperCoreTests`' types,
/// where CI can reach it. The bridge is thin translation with no decisions, and this lint is what
/// keeps it thin: a second file naming the family means a decision has moved somewhere CI cannot
/// see.
///
/// The family is exactly the three forms the C ABI can enter Swift as: the `whisper_` function
/// prefix, the `WHISPER_` constant/type prefix, and the module name `whisper` as an import
/// (`import whisper`) — the hard constraint stated in the brief: *"`import whisper` and every
/// `whisper_*`/`WHISPER_*` identifier may appear ONLY in `WhisperCAPI.swift`"*. The bare lowercase
/// word elsewhere (the engine-id string `"whisper-large-v3-turbo"`, or the *name*
/// `WhisperCppEngine` itself) is not the C ABI entering the codebase — it is the engine's own
/// vocabulary, which is why the permitted family deliberately does not include it: a lint that
/// fired on the shipped identity constant would be measuring the wrong thing.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the ABI to explain what is
/// confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *C call* cannot appear without a reviewed
/// edit to the permitted list below.
final class WhisperSeamTests: XCTestCase {

    /// Files allowed to name the whisper C-ABI family, relative to `Sources/`.
    ///
    /// **One entry, and nothing else ever joins it.**
    private static let filesPermittedToNameTheFamily: Set<String> = [
        "VoccaASR/Whisper/WhisperCAPI.swift"
    ]

    /// The identifier prefixes that constitute the seam: the C function family and the C constant
    /// family. The `import whisper` form is checked separately (see
    /// ``familyIdentifiers(inSource:)``), because it is a module name rather than an identifier.
    private static let forbiddenIdentifierPrefixes = [
        "whisper_", "WHISPER_",
    ]

    /// The module name as it appears in `import whisper`.
    private static let moduleName = "whisper"

    /// Every occurrence of a forbidden family member in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsPlantedFamilyIdentifiers``. An `import whisper` reports as
    /// `"import whisper"` so the sighting ledger reads like code.
    private static func familyIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(whisper_|WHISPER_)[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        var identifiers = regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
        let imports = SwiftSourceScanner.importStatements(inSource: source)
            .filter { $0.module == Self.moduleName }
            .map { "import \($0.module)" }
        identifiers.append(contentsOf: imports)
        return identifiers
    }

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    /// Every sighting under `root`, honouring `permitted`.
    private func sightings(under root: URL) throws -> [String: [String]] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var byFile: [String: [String]] = [:]
        var scanned = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            if url.path.contains("/.build/") { continue }
            scanned += 1
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: url, encoding: .utf8)
            let identifiers = Self.familyIdentifiers(inSource: source)
            if !identifiers.isEmpty {
                byFile[relative] = identifiers
            }
        }
        guard scanned > 0 else {
            throw WhisperSeamTestError.noSwiftFilesScanned(under: root.path)
        }
        return byFile
    }

    /// The whole of the confinement: every sighting sits in the permitted file, and the
    /// permitted file is the only one permitted.
    ///
    /// Two independent claims, because either one failing alone still passes a one-sided check:
    /// "no other file names the family" passes if the permitted file *also* lost its
    /// implementation (the ABI used everywhere else — vacuous), and "the permitted file names the
    /// family" passes if three files do (the seam has sprung a leak).
    func testExactlyOneFileInSourcesMayNameTheWhisperFamily() throws {
        let root = try sourcesRoot()
        let sightings = try sightings(under: root)

        let offenders = sightings.keys.filter { !Self.filesPermittedToNameTheFamily.contains($0) }
        XCTAssertTrue(
            offenders.isEmpty,
            "the whisper family is named outside the permitted bridge file: \(offenders.sorted())")

        let permitted = Self.filesPermittedToNameTheFamily
        XCTAssertFalse(
            permitted.isEmpty,
            "the permitted list must not be empty — an empty list passes 'no file names it' vacuously")
        for file in permitted {
            XCTAssertFalse(
                sightings[file]?.isEmpty ?? true,
                "the permitted file must actually name the family — a permitted file that does not "
                    + "means the ABI moved somewhere else and the lint cannot see it")
        }
        XCTAssertEqual(
            sightings.count, permitted.count,
            "exactly the permitted set may name the family, got \(sightings.keys.sorted())")
    }

    /// The lint's negative control: planted C-ABI members are caught — the function family, the
    /// constant family, and the import form.
    func testTheLintDetectsPlantedFamilyIdentifiers() {
        let source = """
            import Foundation
            import whisper

            public struct Leak {
                public func run(_ ctx: OpaquePointer) {
                    whisper_full(ctx, params, samples, 1)
                    _ = WHISPER_SAMPLE_RATE
                }
            }
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers, ["whisper_full", "WHISPER_SAMPLE_RATE", "import whisper"],
            "the detector must find the planted import and both prefix families")
    }

    /// The negative control's other half: the engine's own vocabulary is *not* the C ABI. The
    /// name `WhisperCppEngine` is case-distinct from the lowercase module, the engine-id string
    /// is data, and neither is a `whisper_`/`WHISPER_` identifier — so neither may trip the lint.
    func testTheEnginesOwnVocabularyDoesNotTripTheLint() {
        let source = """
            import VoccaCore

            public enum WhisperCppEngineIdentity {
                public static let whisper = EngineIdentity(
                    id: "whisper-large-v3-turbo", displayName: "Whisper turbo", isLocal: true)
            }
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertTrue(
            identifiers.isEmpty,
            "the engine's own names and the engine-id string are not the C ABI: got \(identifiers)")
    }

    /// A doc comment may name the C ABI — the scanner strips comments, which is what lets the
    /// bridge's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheFamilyDoesNotTripTheLint() {
        let source = """
            /// The one file in `Sources/` permitted to name whisper_full and WHISPER_SAMPLE_RATE —
            /// the bridge holds the context, and everything decided about it lives above it.
            import Foundation
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }

    /// `VoccaASR`'s module boundary still holds with the bridge inside it (`plan_20260810.md`
    /// Phase 2): among Vocca modules it imports only `VoccaCore` — the engine types live there,
    /// and the C module `whisper` is not a Vocca module. Rule 3 of `ModuleBoundaryTests` asserts
    /// the same tree-wide; this keeps the claim in the seam's own suite, where the bridge file
    /// lives, and refuses the vacuous green of an empty module.
    func testVoccaASRImportsOnlyVoccaCoreAmongVoccaModules() throws {
        let root = try sourcesRoot().appendingPathComponent("VoccaASR", isDirectory: true)
        let files = SwiftSourceScanner.swiftFiles(under: root)
        XCTAssertFalse(files.isEmpty, "VoccaASR must contain Swift files for this check to mean anything")

        var violations: [String: [String]] = [:]
        for file in files {
            let imports = try SwiftSourceScanner.importedModuleNames(in: file)
            let nonCore = imports.filter { $0.hasPrefix("Vocca") && $0 != "VoccaCore" }
            if !nonCore.isEmpty {
                violations[file.lastPathComponent] = nonCore
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "VoccaASR may import VoccaCore among Vocca modules, and nothing else: \(violations)")
    }
}
