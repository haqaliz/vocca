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
private enum KokoroSeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                The speech seam's module directory does not exist at \(expectedAt). The Kokoro \
                runtime confinement is asserted by scanning the source tree; if the module has \
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

/// The Kokoro-runtime family lint (`kokoro-binding`/`engine-binding` spec acceptance 2): **within
/// `VoccaSpeech`, exactly one file may name the port's identifier family — the Kokoro adapter.**
///
/// The same shape as the AVFAudio confinement (`SpeechSeamBoundaryTests`) and H8b
/// (`ParakeetSeamTests`): the Parakeet engine is the one file permitted to speak FluidAudio, the
/// system synthesizer is the one file permitted to speak `AVSpeechSynthesizer`/`AVAudioPCMBuffer`,
/// and the Kokoro engine is the one file permitted to speak the port — because everything *decided*
/// about speech rendering lives above it, in the seam's vocabulary (`AudioChunk`, `VoiceIdentity`,
/// `SentenceChunker`), where CI can reach it. The adapter is thin translation, and this lint is
/// what keeps it thin: a second file naming the family means a decision (or a rendering path) has
/// moved somewhere CI cannot see.
///
/// The family is the identifier prefix list below: the port's own type surface (`KokoroCoreML`,
/// `KokoroEngine`, `SynthesisResult`, `SpeakEvent`), its G2P/VoiceStore internals (`VoiceStore`,
/// `EnglishG2P`, `BARTG2P`, `Phonemizer`) — a prefix rule, so every member of each family is
/// covered by construction. `SpeakEvent` is in the family because its `.audio(AVAudioPCMBuffer)`
/// surface is exactly the AVFAudio leak this binding exists to avoid: naming it outside the
/// adapter would be an AVFAudio import escaping the one file that must hold it.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the family to explain what is
/// confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *type in code* cannot appear without a
/// reviewed edit to the permitted list below.
final class KokoroSeamBoundaryTests: XCTestCase {

    /// The module the seam's adapter lives in — the scan root.
    private static let seamModuleRoot = "VoccaSpeech"

    /// The one file allowed to name the Kokoro runtime family, relative to ``seamModuleRoot``.
    ///
    /// **One entry, and nothing else ever joins it.**
    private static let filesPermittedToNameTheFamily: Set<String> = [
        "Kokoro/KokoroEngine.swift"
    ]

    /// The identifier prefixes that constitute the family: the port's types and the internal
    /// surfaces the port speaks in.
    private static let forbiddenIdentifierPrefixes = [
        "Kokoro", "SpeakEvent", "SynthesisResult", "VoiceStore", "EnglishG2P", "BARTG2P",
        "Phonemizer",
    ]

    /// Every occurrence of a forbidden identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedKokoroRuntimeUse``.
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

    /// Every `URLSession` occurrence in `source`, comments removed first.
    private static func urlSessionOccurrences(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        guard let regex = try? NSRegularExpression(pattern: "\\bURLSession\\b") else { return [] }
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
            throw KokoroSeamTestError.noSwiftFilesScanned(under: root.path)
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
    /// implementation (the family used everywhere else — vacuous), and "the permitted file names
    /// the family" passes if three files do (the seam has sprung a leak).
    func testExactlyOneFileInVoccaSpeechMayNameTheKokoroRuntimeFamily() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw KokoroSeamTestError.seamDirectoryMissing(expectedAt: root.path)
        }
        let sightings = try sightings(under: root)

        let offenders = sightings.keys.filter { !Self.filesPermittedToNameTheFamily.contains($0) }
        XCTAssertTrue(
            offenders.isEmpty,
            "the Kokoro runtime family is named outside the permitted adapter file: \(offenders.sorted())")

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

    /// The lint's negative control: planted source is caught — every family member, in the shapes
    /// a leaked adapter would actually use them.
    func testTheLintDetectsAPlantedKokoroRuntimeUse() {
        let source = """
            import KokoroCoreML

            public struct Leak {
                public let engine: KokoroEngine
                public var result: SynthesisResult? { nil }
                public var event: SpeakEvent? { nil }
                public let voices = VoiceStore.self
                public let g2p = EnglishG2P.self
                public let bart = BARTG2P.self
                public let phonemizer: Phonemizer? = nil
            }
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers,
            ["KokoroCoreML", "KokoroEngine", "SynthesisResult", "SpeakEvent", "VoiceStore",
                "EnglishG2P", "BARTG2P", "Phonemizer"],
            "the detector must find every planted family member — the egress half (`SpeakEvent`) "
                + "included")
    }

    /// A doc comment may name the family — the scanner strips comments, which is what lets the
    /// adapter's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheKokoroRuntimeDoesNotTripTheLint() {
        let source = """
            /// The one file in `Sources/VoccaSpeech` permitted to name KokoroCoreML and
            /// SynthesisResult — the adapter holds the KokoroEngine, and everything decided about
            /// it lives above it.
            import VoccaCore
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }

    /// The binding stays AVFAudio-free: the permitted file imports no `AVFAudio`/`AVFoundation`
    /// (the tree-wide expected-import set is unchanged — no row amendment) and names no
    /// `URLSession` (the port's downloader is never reached from the seam file).
    ///
    /// A missing permitted file fails this test loudly rather than passing it: a lint that cannot
    /// read its own permitted file is a lint that enforces nothing.
    func testThePermittedFileDoesNotImportAVFoundationAndDoesNotNameURLSession() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard let permitted = Self.filesPermittedToNameTheFamily.first else {
            throw KokoroSeamTestError.seamDirectoryMissing(expectedAt: root.path)
        }
        let file = root.appendingPathComponent(permitted)

        let imports = try SwiftSourceScanner.importedModuleNames(in: file)
        XCTAssertFalse(
            imports.contains("AVFAudio") || imports.contains("AVFoundation"),
            "the Kokoro binding must stay AVFAudio-free — it converts \(imports) samples, never "
                + "PCM buffers: \(imports)")

        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(
            Self.urlSessionOccurrences(inSource: source).isEmpty,
            "the binding must not name URLSession — the port's downloader is never reached from "
                + "the seam file")
    }
}