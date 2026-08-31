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
private enum ParakeetSeamTestError: Error, CustomStringConvertible {
    case sourcesDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .sourcesDirectoryMissing(let expectedAt):
            return """
                The Sources/ directory does not exist at \(expectedAt). The SDK confinement is \
                asserted by scanning the source tree; if the repository layout has changed, this \
                lint enforces nothing.
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

/// Acceptance H8b (this capability's seam lint, `prd.md` M6/M14): **exactly one file in
/// `Sources/` may name the FluidAudio SDK's identifier family — the Parakeet adapter.**
///
/// The same shape as H7 (`HotkeySeamBoundaryTests`) and H8 (`ModelDownloaderSeamTests`): the
/// tap adapter is the one file permitted to speak CoreGraphics, the default transport is the one
/// file permitted to speak URLSession, and the Parakeet engine is the one file permitted to
/// speak FluidAudio — because everything *decided* about transcription lives above it, in
/// `ParakeetCoreTests`' types, where CI can reach it. The adapter is thin glue, and this lint is
/// what keeps it thin: a second file naming the SDK means a decision (or an egress path —
/// `ModelHub`'s downloaders are in the family) has moved somewhere CI cannot see.
///
/// The family is the identifier prefix list below: `AsrManager`, `AsrModels`, `ModelHub`,
/// `TdtDecoderState`, `ASRResult`, `FluidAudio` itself and `SlidingWindow` — a prefix rule, so
/// every member of each family is covered by construction. `ModelHub` is in the family because
/// its download machinery is exactly the egress the offline promise exists to prevent: naming it
/// outside the adapter would be the network decision escaping the one file that must hold it.
///
/// `SlidingWindow` joined the family with the streaming adapter, and it is the family member the
/// word-boundary rule almost missed: the scanner's regex matches a prefix at a word boundary, so
/// `\bAsrManager[A-Za-z0-9_]*` does **not** match `SlidingWindowAsrManager` — the `w` before the
/// `A` is a word character, so no boundary exists there, and the sliding-window names would have
/// escaped the lint entirely. A prefix on the *leading* word (`SlidingWindow`) is what catches
/// every member of the SDK's sliding-window surface.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the SDK to explain what is
/// confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *type in code* cannot appear without a
/// reviewed edit to the list below.
final class ParakeetSeamTests: XCTestCase {

    /// Files allowed to name the FluidAudio family, relative to `Sources/`.
    ///
    /// **One entry, and nothing else ever joins it.**
    private static let filesPermittedToNameTheSDK: Set<String> = [
        "VoccaASR/Parakeet/ParakeetEngine.swift"
    ]

    /// The identifier prefixes that constitute the seam.
    ///
    /// `SlidingWindow` joined the family with the streaming adapter — and it must be a prefix on
    /// the *leading* word: the scanner matches a prefix at a word boundary, so a prefix on
    /// `AsrManager` cannot see `SlidingWindowAsrManager` (no boundary between `w` and `A`), and
    /// the planted-violation test pins that the leading prefix is what catches it.
    private static let forbiddenIdentifierPrefixes = [
        "AsrManager", "AsrModels", "ModelHub", "TdtDecoderState", "ASRResult", "FluidAudio",
        "SlidingWindow",
    ]

    /// Every occurrence of a forbidden identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedSDKIdentifier``.
    private static func sdkIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + forbiddenIdentifierPrefixes.joined(separator: "|") + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
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
            let identifiers = Self.sdkIdentifiers(inSource: source)
            if !identifiers.isEmpty {
                byFile[relative] = identifiers
            }
        }
        guard scanned > 0 else {
            throw ParakeetSeamTestError.noSwiftFilesScanned(under: root.path)
        }
        return byFile
    }

    /// The whole of the confinement: every sighting sits in the permitted file, and the
    /// permitted file is the only one permitted.
    ///
    /// Two independent claims, because either one failing alone still passes a one-sided check:
    /// "no other file names the SDK" passes if the permitted file *also* lost its implementation
    /// (the SDK used everywhere else — vacuous), and "the permitted file names the SDK" passes
    /// if three files do (the seam has sprung a leak).
    func testExactlyOneFileInSourcesMayNameTheFluidAudioFamily() throws {
        let root = try sourcesRoot()
        let sightings = try sightings(under: root)

        let offenders = sightings.keys.filter { !Self.filesPermittedToNameTheSDK.contains($0) }
        XCTAssertTrue(
            offenders.isEmpty,
            "the FluidAudio family is named outside the permitted adapter file: \(offenders.sorted())")

        let permitted = Self.filesPermittedToNameTheSDK
        XCTAssertFalse(
            permitted.isEmpty,
            "the permitted list must not be empty — an empty list passes 'no file names it' vacuously")
        for file in permitted {
            XCTAssertFalse(
                sightings[file]?.isEmpty ?? true,
                "the permitted file must actually name the SDK — a permitted file that does not "
                    + "means the SDK moved somewhere else and the lint cannot see it")
        }
        XCTAssertEqual(
            sightings.count, permitted.count,
            "exactly the permitted set may name the SDK, got \(sightings.keys.sorted())")
    }

    /// The lint's negative control: planted source is caught — including the egress half of the
    /// family, `ModelHub`, whose presence outside the adapter is the privacy failure this lint
    /// exists to prevent, and `SlidingWindowAsrManager`, whose *leading* prefix is the one the
    /// word-boundary rule almost missed (a planted token that today's regex cannot see would make
    /// the guard a placebo — it must be here, in the planted proof, or the extension proves
    /// nothing).
    func testTheLintDetectsAPlantedSDKIdentifier() {
        let source = """
            import Foundation

            public struct Leak {
                public let models: AsrModels
                public var hub: ModelHub { .shared }
                public let window: SlidingWindowAsrManager
            }
            """
        let identifiers = Self.sdkIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers, ["AsrModels", "ModelHub", "SlidingWindowAsrManager"],
            "the detector must find the planted types, ModelHub and the sliding-window family "
                + "included")
    }

    /// A doc comment may name the SDK — the scanner strips comments, which is what lets the
    /// adapter's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheSDKDoesNotTripTheLint() {
        let source = """
            /// The one file in `Sources/` permitted to name FluidAudio — the adapter holds the
            /// AsrManager, and everything decided about it lives above it.
            import Foundation
            """
        let identifiers = Self.sdkIdentifiers(inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }
}
