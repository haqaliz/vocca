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
private enum ModelDownloaderSeamTestError: Error, CustomStringConvertible {
    case sourcesDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .sourcesDirectoryMissing(let expectedAt):
            return """
                The Sources/ directory does not exist at \(expectedAt). The network confinement is \
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

/// Acceptance H8 (this capability's seam lint, `prd.md` M14): **exactly one file in `Sources/`
/// may name `URLSession` — the model downloader's transport.**
///
/// The zero-network claim (`ARCHITECTURE.md:16`, amended by this capability to name
/// ``ModelDownloader`` as the first of the two network-permitted types) is only as strong as its
/// enforcement: a wrong code path that opens a socket anywhere else fails *this test*, not an
/// audit. The H7 pattern is the template (`HotkeySeamBoundaryTests`): the tap adapter is the one
/// file permitted to speak CoreGraphics because everything decided about taps lives above it; the
/// default transport is the one file permitted to speak URLSession because everything decided
/// about downloads lives above *it* — in ``ModelDownloader``, where the tests can drive it.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name `URLSession` to explain what
/// is confined — ``ModelTransport``'s does, at length, and should. It is not string-literal aware
/// (see ``SwiftSourceScanner``), so the identifier inside a literal would be missed. Both are
/// deliberate trade-offs of a text scan; what matters is that a *type in code* cannot appear
/// without a reviewed edit to the list below.
final class ModelDownloaderSeamTests: XCTestCase {

    /// Files allowed to name `URLSession`, relative to `Sources/`.
    ///
    /// **One entry, and nothing else ever joins it.** A second means the zero-network claim has
    /// sprung a leak and the network decision that leaked with it is now somewhere CI cannot reach.
    /// The prefix rule covers `URLSessionConfiguration`, `URLSessionTask` and every other member of
    /// the family by construction.
    private static let filesPermittedToNameURLSession: Set<String> = [
        "VoccaASR/Models/DefaultModelTransport.swift"
    ]

    /// The identifier prefix that constitutes the seam.
    private static let forbiddenIdentifierPrefixes = ["URLSession"]

    /// Every occurrence of a forbidden identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedURLSession``.
    private static func urlSessionIdentifiers(inSource source: String) -> [String] {
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
    ///
    /// The permitted file's own sighting is removed from its entry: the lint's claim is that the
    /// *rest* of the tree names nothing, and a report of the permitted file "violating" its own
    /// permission would obscure that.
    private func sightings(under root: URL, permitted: Set<String>) throws -> [String: [String]] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var byFile: [String: [String]] = [:]
        var scanned = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: url, encoding: .utf8)
            let identifiers = Self.urlSessionIdentifiers(inSource: source)
            if !identifiers.isEmpty {
                byFile[relative] = identifiers
            }
        }
        guard scanned > 0 else {
            throw ModelDownloaderSeamTestError.noSwiftFilesScanned(under: root.path)
        }
        return byFile
    }

    /// The whole of the confinement: every sighting sits in the permitted file, and the permitted
    /// file is the only one permitted.
    ///
    /// Two independent claims, because either one failing alone still passes a one-sided check:
    /// "no other file names URLSession" passes if the permitted file *also* lost its implementation
    /// (network everywhere else — vacuous), and "the permitted file names URLSession" passes if
    /// three files do (the seam has sprung a leak — the same vacuous green the test floor exists
    /// to prevent).
    func testExactlyOneFileInSourcesMayNameURLSession() throws {
        let root = try sourcesRoot()
        let sightings = try sightings(under: root, permitted: Self.filesPermittedToNameURLSession)

        let offenders = sightings.keys.filter { !Self.filesPermittedToNameURLSession.contains($0) }
        XCTAssertTrue(
            offenders.isEmpty,
            "URLSession is named outside the permitted transport file: \(offenders.sorted())")

        let permitted = Self.filesPermittedToNameURLSession
        XCTAssertFalse(
            permitted.isEmpty,
            "the permitted list must not be empty — an empty list passes 'no file names it' vacuously")
        for file in permitted {
            XCTAssertFalse(
                sightings[file]?.isEmpty ?? true,
                "the permitted file must actually name URLSession — a permitted file that does not "
                    + "means the network moved somewhere else and the lint cannot see it")
        }
        XCTAssertEqual(
            sightings.count, permitted.count,
            "exactly the permitted set may name URLSession, got \(sightings.keys.sorted())")
    }

    /// The lint's negative control: planted source is caught.
    ///
    /// A scan that cannot fail when violated is decoration, so the detector is run against a
    /// deliberately violating sample and must find it — including the family members the prefix
    /// rule exists to cover.
    func testTheLintDetectsAPlantedURLSession() {
        let source = """
            import Foundation

            public struct Leak {
                public let session: URLSession
                public var config: URLSessionConfiguration { .default }
            }
            """
        let identifiers = Self.urlSessionIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers, ["URLSession", "URLSessionConfiguration"],
            "the detector must find the planted type and its prefix family")
    }

    /// A doc comment may name the seam — the scanner strips comments, which is what lets
    /// ``ModelTransport``'s documentation say "permitted to name `URLSession`" without tripping
    /// the lint that exists to confine it.
    func testADocCommentNamingURLSessionDoesNotTripTheLint() {
        let source = """
            /// The one file in `Sources/` permitted to name `URLSession` — the network half of
            /// the zero-network claim.
            import Foundation
            """
        let identifiers = Self.urlSessionIdentifiers(inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }

    /// The cleanup eval-harness family may not name `URLSession` anywhere — the scorer, the
    /// loader, the runs and their tests (B3): the harness is part of the default
    /// configuration's CI surface, and the default configuration makes zero network calls. The
    /// permitted set is **empty** — unlike the transport lint's one-file set, nothing in this
    /// family may speak the network half of the zero-network claim, ever.
    ///
    /// The vacuity guards run in both directions: the fixed file list is non-empty, and every
    /// listed file exists — a renamed-away eval file would pass "nothing names URLSession"
    /// vacuously, so the list's existence is asserted, not assumed.
    func testNoEvalHarnessFileNamesURLSession() throws {
        let evalFiles = [
            "CleanupPairwiseScorer.swift",
            "CleanupPairSuite.swift",
            "ProvisionalCleanupTargets.swift",
            "CleanupPairwiseScorerTests.swift",
            "CleanupEvalHarnessTests.swift",
            "CleanupProvisioningScriptTests.swift",
        ]
        XCTAssertFalse(
            evalFiles.isEmpty,
            "the eval-file list must not be empty — an empty list passes 'no file names it' "
                + "vacuously")

        let root = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Tests/HarnessTests")
        for fileName in evalFiles {
            let url = root.appendingPathComponent(fileName)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "every listed eval file must exist — a renamed-away file passes vacuously: "
                    + "\(fileName)")
            let source = try String(contentsOf: url, encoding: .utf8)
            let identifiers = Self.urlSessionIdentifiers(inSource: source)
            XCTAssertTrue(
                identifiers.isEmpty,
                "\(fileName) must not name URLSession, got: \(identifiers)")
        }
    }
}
