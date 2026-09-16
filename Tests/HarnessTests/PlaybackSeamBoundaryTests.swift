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
private enum PlaybackSeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                The playback seam's module directory does not exist at \(expectedAt). The AVFAudio \
                confinement is asserted by scanning the source tree; if the directory has moved or \
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

/// The playback seam's family lint (the `SpeechSeamBoundaryTests` shape): **within
/// `Sources/VoccaAudio/Playback/`, exactly one file may name the AVFAudio surface — the
/// `SystemPlayback` adapter.**
///
/// The same shape as H8b (`ParakeetSeamTests`), the whisper seam (`WhisperSeamTests`) and the
/// speech seam (`SpeechSeamBoundaryTests`): the playback adapter is the one file permitted to
/// speak `AVAudioEngine`/`AVAudioSourceNode` — because everything *decided* about playback lives
/// above it, in the seam's vocabulary (`AudioChunk`, `PlaybackLevel`, the duck/halt state
/// machine), where CI can reach it. The adapter is thin translation plus the realtime render
/// block, and this lint is what keeps it thin: a second file naming the family inside `Playback/`
/// means a decision (or a rendering path) has moved somewhere CI cannot see.
///
/// ## Why the scan root is the `Playback/` directory, not all of `VoccaAudio`
///
/// The capture files' family use (`AudioCaptureGraph.swift`, `AudioFormatConverter.swift`,
/// `MicrophoneAuthorization.swift`) is bounded tree-wide by `AudioFormatConverterTests`'
/// expected-import set, and it predates this seam — a module-wide scan here would either
/// duplicate that reviewed list or silently permit the capture files' names. This lint bounds
/// **this seam's home**: `Sources/VoccaAudio/Playback/` is where the voice loop's output grows,
/// and a future second file there cannot move a playback decision into the untestable zone
/// without a reviewed edit to the permitted list below.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the family to explain what is
/// confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *type in code* cannot appear without a
/// reviewed edit to the permitted list below.
final class PlaybackSeamBoundaryTests: XCTestCase {

    /// The seam's home — the scan root.
    private static let seamDirectory = "VoccaAudio/Playback"

    /// The one file allowed to name the AVFAudio family, relative to ``seamDirectory``.
    ///
    /// **One entry, and nothing else ever joins it.**
    private static let filesPermittedToNameTheFamily: Set<String> = [
        "SystemPlayback.swift"
    ]

    /// The identifier prefixes that constitute the family: the audio-engine and audio-node types
    /// the output adapter speaks in.
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

    /// Every sighting under the seam's directory.
    private func sightings(under root: URL) throws -> [String: [String]] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw PlaybackSeamTestError.noSwiftFilesScanned(under: root.path)
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
    func testExactlyOneFileInVoccaAudioPlaybackMayNameTheAVFAudioFamily() throws {
        let root = try sourcesRoot().appendingPathComponent(Self.seamDirectory, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw PlaybackSeamTestError.seamDirectoryMissing(expectedAt: root.path)
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
    /// shapes a leaked playback file would actually use them.
    func testTheLintDetectsAPlantedAVFAudioUse() {
        let source = """
            import VoccaCore

            public struct Leak {
                public let engine: AVAudioEngine
                public func makeNode() -> AVAudioSourceNode? { nil }
            }
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers, ["AVAudioEngine", "AVAudioSourceNode"],
            "the detector must find the planted engine and the planted source node")
    }

    /// A doc comment may name the family — the scanner strips comments, which is what lets the
    /// adapter's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheFamilyDoesNotTripTheLint() {
        let source = """
            /// The one file in `Sources/VoccaAudio/Playback` permitted to name AVAudioEngine and
            /// AVAudioSourceNode — the adapter holds the engine, and everything decided about it
            /// lives above it.
            import VoccaCore
            """
        let identifiers = Self.familyIdentifiers(inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }
}