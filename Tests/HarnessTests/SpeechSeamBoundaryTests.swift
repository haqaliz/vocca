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
private enum SpeechSeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                The speech seam's module directory does not exist at \(expectedAt). The AVFAudio \
                confinement is asserted by scanning the source tree; if the module has moved or \
                been renamed, this lint enforces nothing.
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

/// The speech seam's family lint (`system-synthesizer/spec.md` R7, the
/// `kokoro-voice-output` aspect's H8b-shaped row): **within `VoccaSpeech`, exactly one file may
/// name the AVFAudio surface — the system synthesizer adapter.**
///
/// The same shape as H8b (`ParakeetSeamTests`) and the whisper seam (`WhisperSeamTests`): the
/// Parakeet engine is the one file permitted to speak FluidAudio, the whisper bridge is the one
/// file permitted to speak the C ABI, and the system synthesizer is the one file permitted to
/// speak `AVSpeechSynthesizer`/`AVAudioPCMBuffer` — because everything *decided* about speech
/// rendering lives above it, in the seam's vocabulary (`AudioChunk`, `VoiceIdentity`,
/// `SentenceChunker`), where CI can reach it. The adapter is thin translation, and this lint is
/// what keeps it thin: a second file naming the family means a decision (or a rendering path)
/// has moved somewhere CI cannot see.
///
/// The family is the `AVSpeech` and `AVAudio` identifier prefixes — a prefix rule, so every
/// member of each family (`AVSpeechSynthesizer`, `AVSpeechUtterance`, `AVSpeechSynthesisVoice`,
/// `AVAudioPCMBuffer`, `AVAudioFormat`, …) is covered by construction. The claim is **per-module**
/// (the `NSWorkspace` family's shape): the tree-wide `import AVFoundation` confinement already
/// lives in `AudioFormatConverterTests`' expected-import set, and this lint confines the *type
/// names* to the adapter inside the module that owns the seam.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the family to explain what is
/// confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *type in code* cannot appear without a
/// reviewed edit to the permitted list below.
final class SpeechSeamBoundaryTests: XCTestCase {

    /// The module the seam's adapter lives in — the scan root.
    private static let seamModuleRoot = "VoccaSpeech"

    /// The one file allowed to name the AVFAudio family, relative to ``seamModuleRoot``.
    ///
    /// **One entry, and nothing else ever joins it.**
    private static let filesPermittedToNameTheFamily: Set<String> = [
        "System/SystemSynthesizer.swift"
    ]

    /// The identifier prefixes that constitute the family: the speech types and the audio types
    /// the system renderer speaks in.
    private static let forbiddenIdentifierPrefixes = [
        "AVSpeech", "AVAudio",
    ]

    /// Every occurrence of a forbidden identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedAVFAudioUse``.
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
            throw SpeechSeamTestError.noSwiftFilesScanned(under: root.path)
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
    func testExactlyOneFileInVoccaSpeechMayNameTheAVFAudioFamily() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw SpeechSeamTestError.seamDirectoryMissing(expectedAt: root.path)
        }
        let sightings = try sightings(under: root)

        let offenders = sightings.keys.filter { !Self.filesPermittedToNameTheFamily.contains($0) }
        XCTAssertTrue(
            offenders.isEmpty,
            "the AVFAudio family is named outside the permitted adapter file: \(offenders.sorted())")

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

    /// The lint's negative control: planted source is caught — both family prefixes, in the
    /// shapes a leaked adapter would actually use them.
    func testTheLintDetectsAPlantedAVFAudioUse() {
        let source = """
            import VoccaCore

            public struct Leak {
                public let synth: AVSpeechSynthesizer
                public func render() -> AVAudioPCMBuffer? { nil }
            }
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers, ["AVSpeechSynthesizer", "AVAudioPCMBuffer"],
            "the detector must find the planted speech type and the planted audio type")
    }

    /// A doc comment may name the family — the scanner strips comments, which is what lets the
    /// adapter's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheFamilyDoesNotTripTheLint() {
        let source = """
            /// The one file in `Sources/VoccaSpeech` permitted to name AVSpeechSynthesizer and
            /// AVAudioPCMBuffer — the adapter holds the renderer, and everything decided about it
            /// lives above it.
            import VoccaCore
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }
}