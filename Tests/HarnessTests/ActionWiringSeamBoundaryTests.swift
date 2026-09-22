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

import Foundation
import XCTest

/// **The action-wiring family lint** (`wiring` aspect Phase 4, the
/// `ContextWiringSeamBoundaryTests` shape): the C13 composition's own names are confined to the
/// files that compose it — the recipe (`VoccaBootstrap/ActionWiring.swift`), the
/// composition root's call (`AppBootstrap.swift`), and the two probe drives that run the
/// recipe (`ActionAuditDrive.swift` and, since `probe`, the intent drive whose round trip's
/// human leg is the surface's own confirm/decline closures) — and never the pinned dictation
/// files, the action machinery, or `VoccaUI` (the surfaces consume the root's slots, never the
/// wiring's names).
///
/// The family is the wiring's own vocabulary — `ActionWiring` (the recipe's surface; the prefix
/// rule covers `ActionWiringError` by construction) and `composeActionWiring` (the recipe's
/// entry point — its own prefix, because `\b` cannot see a boundary inside the
/// `compose`-prefixed identifier). The never-read guard's second half follows: no
/// `ActionProvider` family name in the two digest-pinned dictation files — "the loop never
/// depends on actions" as lint, not discipline.
final class ActionWiringSeamBoundaryTests: XCTestCase {

    /// The identifier prefixes that constitute the wiring family: the recipe's surface and the
    /// recipe's entry point.
    private static let wiringFamilyIdentifiers = [
        "ActionWiring", "composeActionWiring",
    ]

    /// The files allowed to name the wiring family, relative to `Sources/`.
    ///
    /// **These three, and nothing else ever joins them.** The recipe is where the names live;
    /// the composition root names the recipe's call and the root's slots; the probe drive
    /// composes the recipe for the zero-network invariant. The surfaces (`VoccaUI`) consume the
    /// root's slots, never the wiring's names.
    ///
    /// `probe`'s reviewed widening — the intent drive names the **action** recipe too: the
    /// voice round trip's human leg is the surface's own confirm/decline closures (R5), so the
    /// drive composes `composeActionWiring` alongside `composeIntentWiring`.
    private static let filesPermittedToNameTheWiringFamily: Set<String> = [
        "VoccaBootstrap/ActionWiring.swift",
        "VoccaBootstrap/AppBootstrap.swift",
        "VoccaNetworkProbe/ActionAuditDrive.swift",
        "VoccaNetworkProbe/IntentDrive.swift",
    ]

    /// The identifier prefix of the never-read guard's family: the seam itself.
    private static let providerFamilyIdentifier = "ActionProvider"

    /// The two digest-pinned dictation files the provider family must never reach.
    private static let pinnedDictationFiles = [
        "Sources/VoccaCore/SessionMachine.swift",
        "Sources/VoccaCore/DictationPipeline.swift",
    ]

    /// Every occurrence of a forbidden wiring-family identifier in `source`, comments removed
    /// first.
    private static func wiringFamilyIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + wiringFamilyIdentifiers.joined(separator: "|")
            + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// Every `ActionProvider` occurrence in `source`, comments removed first — the never-read
    /// guard's detector.
    private static func providerFamilyIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b" + providerFamilyIdentifier + "[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    /// Every wiring-family sighting under the sources root, honouring `permitted`.
    private func sightings(under root: URL) throws -> [String: [String]] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ActionWiringLintError.noSwiftFilesScanned(under: root.path)
        }

        var byFile: [String: [String]] = [:]
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            let identifiers = Self.wiringFamilyIdentifiers(inSource: source)
            if !identifiers.isEmpty {
                byFile[relative] = identifiers
            }
        }
        return byFile
    }

    /// The whole of the confinement: every sighting sits in a permitted file, and every
    /// permitted file names the family.
    ///
    /// Two independent claims, because either one failing alone still passes a one-sided
    /// check: "no other file names the family" passes if the permitted files *also* lost
    /// their implementation (the family used everywhere else — vacuous), and "the permitted
    /// files name the family" passes if four files do (the seam has sprung a leak).
    func testOnlyTheCompositionFilesMayNameTheActionWiringFamily() throws {
        let root = try sourcesRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ActionWiringLintError.sourcesDirectoryMissing(expectedAt: root.path)
        }
        let sightings = try sightings(under: root)

        let offenders = sightings.keys.filter {
            !Self.filesPermittedToNameTheWiringFamily.contains($0)
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "the action-wiring family is named outside the composition files: "
                + "\(offenders.sorted())")

        let permitted = Self.filesPermittedToNameTheWiringFamily
        XCTAssertFalse(
            permitted.isEmpty,
            "the permitted list must not be empty — an empty list passes 'no file names it' "
                + "vacuously")
        for file in permitted {
            XCTAssertFalse(
                sightings[file]?.isEmpty ?? true,
                "the permitted file must actually name the family — a permitted file that "
                    + "does not means the family moved somewhere else and the lint cannot see it")
        }
        XCTAssertEqual(
            sightings.count, permitted.count,
            "exactly the permitted set may name the family, got \(sightings.keys.sorted())")
    }

    /// The lint's negative control: planted source is caught — every family member, in the
    /// shapes a leaked composition would actually use them.
    func testTheLintDetectsAPlantedActionWiringUse() {
        let source = """
            import VoccaCore

            public struct Leak {
                public var wiring: ActionWiring? { nil }
                public var error: ActionWiringError? { nil }
                public func composeActionWiring() {}
            }
            """
        let identifiers = Self.wiringFamilyIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers,
            ["ActionWiring", "ActionWiringError", "composeActionWiring"],
            "the detector must find every planted family member — the compose-prefixed call "
                + "included")
    }

    /// A doc comment may name the family — the scanner strips comments, which is what lets the
    /// composition's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheActionWiringDoesNotTripTheLint() {
        let source = """
            /// The one file in `Sources/VoccaBootstrap` permitted to name ActionWiring and
            /// its recipe — the wiring holds the composition, and everything decided about it
            /// lives above it.
            import VoccaCore
            """
        let identifiers = Self.wiringFamilyIdentifiers(inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }

    // MARK: - The never-read guard's second half

    /// **No `ActionProvider` family name in the pinned dictation path** — "the loop never
    /// depends on actions" as lint, not discipline: the two digest-pinned files name no
    /// member of the seam's family, so a future action dependency there cannot compile into
    /// the dictation path silently. (`ActionWiring` reaching these files would already trip
    /// the wiring-family scan above; this is the seam's own family, guarding the boundary
    /// from the other direction.)
    func testThePinnedDictationFilesNeverNameTheActionProviderFamily() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        for relative in Self.pinnedDictationFiles {
            let url = root.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            let identifiers = Self.providerFamilyIdentifiers(inSource: source)
            XCTAssertTrue(
                identifiers.isEmpty,
                "\(relative) names the ActionProvider family: \(identifiers) — the dictation "
                    + "path must never depend on actions (C13)")
        }
    }
}

/// The lint's own failure vocabulary.
private enum ActionWiringLintError: Error {
    case sourcesDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)
}