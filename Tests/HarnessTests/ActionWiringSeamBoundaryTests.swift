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

/// **The wiring-family lint** (`wiring` aspect Phase 4 + `probe`'s intent leg, the
/// `ContextWiringSeamBoundaryTests` shape): the C13 compositions' own names are confined to the
/// files that compose them, per recipe — the action recipe (`VoccaBootstrap/ActionWiring.swift`),
/// the intent recipe (`VoccaBootstrap/IntentWiring.swift`), the composition root's calls
/// (`AppBootstrap.swift`), and the probe drives that run them — and never the pinned dictation
/// files, the action machinery, or `VoccaUI` (the surfaces consume the root's slots, never the
/// wiring's names).
///
/// Each family is one recipe's own vocabulary — the surface type (the prefix rule covers
/// `ActionWiringError` by construction) and the entry point (its own prefix, because `\b` cannot
/// see a boundary inside the `compose`-prefixed identifier):
///
/// - `ActionWiring` / `composeActionWiring` — the action surface's recipe, composed by
///   `configure` and driven by both probe drives (`ActionAuditDrive.swift`, and since `probe`
///   the intent drive whose round trip's human leg is the surface's own confirm/decline
///   closures, R5);
/// - `IntentWiring` / `composeIntentWiring` — the voice path's recipe, composed by `configure`
///   and driven by the intent drive.
///
/// The never-read guard's second half follows for both seams: no `ActionProvider` and no
/// intent-family name in the two digest-pinned dictation files — "the loop never depends on
/// actions or intent" as lint, not discipline.
final class ActionWiringSeamBoundaryTests: XCTestCase {

    /// The wiring families, each with the identifier prefixes that constitute it (the recipe's
    /// surface and the recipe's entry point) and the files permitted to name it, relative to
    /// `Sources/`.
    ///
    /// **These sets, and nothing else ever joins them.** The recipe is where the names live;
    /// the composition root names the recipe's call and the root's slots; the probe drive
    /// composes the recipe for the zero-network invariant. The surfaces (`VoccaUI`) consume the
    /// root's slots, never the wiring's names.
    ///
    /// `probe`'s reviewed widening, twice: the intent drive names the **action** recipe too
    /// (the voice round trip's human leg is the surface's own confirm/decline closures, R5),
    /// and the `IntentWiring` family gains its own row — the intent drive composes the intent
    /// recipe for the round trip, `configure` composes it over the shared executor, and the
    /// recipe file holds the names.
    private static let wiringFamilies: [(identifiers: [String], permitted: Set<String>)] = [
        (
            identifiers: ["ActionWiring", "composeActionWiring"],
            permitted: [
                "VoccaBootstrap/ActionWiring.swift",
                "VoccaBootstrap/AppBootstrap.swift",
                "VoccaNetworkProbe/ActionAuditDrive.swift",
                "VoccaNetworkProbe/IntentDrive.swift",
            ]
        ),
        (
            identifiers: ["IntentWiring", "composeIntentWiring"],
            permitted: [
                "VoccaBootstrap/IntentWiring.swift",
                "VoccaBootstrap/AppBootstrap.swift",
                "VoccaNetworkProbe/IntentDrive.swift",
            ]
        ),
    ]

    /// The identifier prefix of the never-read guard's action-family leg: the seam itself.
    private static let providerFamilyIdentifier = "ActionProvider"

    /// The intent families the never-read guard's intent leg scans for — the same six the
    /// `IntentSeamBoundaryTests` tables confine.
    private static let intentFamilyIdentifiers = [
        "IntentResolver", "IntentResolution", "ToolReference",
        "KeywordIntentResolver", "NullIntentResolver", "KeywordSynonym",
    ]

    /// The two digest-pinned dictation files neither family must reach.
    private static let pinnedDictationFiles = [
        "Sources/VoccaCore/SessionMachine.swift",
        "Sources/VoccaCore/DictationPipeline.swift",
    ]

    /// Every occurrence of a forbidden wiring-family identifier in `source`, comments removed
    /// first.
    private static func wiringFamilyIdentifiers(
        _ identifiers: [String], inSource source: String
    ) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + identifiers.joined(separator: "|") + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// Every occurrence of one identifier prefix in `source`, comments removed first — the
    /// never-read guards' detector.
    private static func familyOccurrences(_ family: String, inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b" + family + "[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// Every `ActionProvider` occurrence in `source`, comments removed first — the action
    /// never-read guard's detector.
    private static func providerFamilyIdentifiers(inSource source: String) -> [String] {
        familyOccurrences(providerFamilyIdentifier, inSource: source)
    }

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    /// Every sighting of one family's identifiers under the sources root.
    private func sightings(
        of identifiers: [String], under root: URL
    ) throws -> [String: [String]] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ActionWiringLintError.noSwiftFilesScanned(under: root.path)
        }

        var byFile: [String: [String]] = [:]
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            let found = Self.wiringFamilyIdentifiers(identifiers, inSource: source)
            if !found.isEmpty {
                byFile[relative] = found
            }
        }
        return byFile
    }

    /// The whole of the confinement, per family: every sighting sits in a permitted file, and
    /// every permitted file names the family.
    ///
    /// Two independent claims, because either one failing alone still passes a one-sided
    /// check: "no other file names the family" passes if the permitted files *also* lost
    /// their implementation (the family used everywhere else — vacuous), and "the permitted
    /// files name the family" passes if four files do (the seam has sprung a leak). The
    /// `sightings.count` equality is the third leg: exactly the permitted set may name the
    /// family.
    func testOnlyTheCompositionFilesMayNameTheWiringFamilies() throws {
        let root = try sourcesRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ActionWiringLintError.sourcesDirectoryMissing(expectedAt: root.path)
        }

        for family in Self.wiringFamilies {
            let sightings = try sightings(of: family.identifiers, under: root)

            let offenders = sightings.keys.filter {
                !family.permitted.contains($0)
            }
            XCTAssertTrue(
                offenders.isEmpty,
                "the \(family.identifiers[0]) family is named outside the composition files: "
                    + "\(offenders.sorted())")

            let permitted = family.permitted
            XCTAssertFalse(
                permitted.isEmpty,
                "the permitted list for \(family.identifiers[0]) must not be empty — an "
                    + "empty list passes 'no file names it' vacuously")
            for file in permitted {
                XCTAssertFalse(
                    sightings[file]?.isEmpty ?? true,
                    "the permitted file must actually name the \(family.identifiers[0]) family "
                        + "— a permitted file that does not means the family moved somewhere "
                        + "else and the lint cannot see it: \(file)")
            }
            XCTAssertEqual(
                sightings.count, permitted.count,
                "exactly the permitted set may name \(family.identifiers[0]), got "
                    + "\(sightings.keys.sorted())")
        }
    }

    /// The action family's negative control: planted source is caught — every family member,
    /// in the shapes a leaked composition would actually use them.
    func testTheLintDetectsAPlantedActionWiringUse() {
        let source = """
            import VoccaCore

            public struct Leak {
                public var wiring: ActionWiring? { nil }
                public var error: ActionWiringError? { nil }
                public func composeActionWiring() {}
            }
            """
        let identifiers = Self.wiringFamilyIdentifiers(
            ["ActionWiring", "composeActionWiring"], inSource: source)
        XCTAssertEqual(
            identifiers,
            ["ActionWiring", "ActionWiringError", "composeActionWiring"],
            "the detector must find every planted action-family member — the compose-prefixed "
                + "call included")
    }

    /// The intent family's negative control: planted source is caught — the intent recipe's
    /// surface and its entry point, in the shapes a leaked composition would actually use them.
    func testTheLintDetectsAPlantedIntentWiringUse() {
        let source = """
            import VoccaCore

            public struct Leak {
                public var wiring: IntentWiring? { nil }
                public func composeIntentWiring() {}
            }
            """
        let identifiers = Self.wiringFamilyIdentifiers(
            ["IntentWiring", "composeIntentWiring"], inSource: source)
        XCTAssertEqual(
            identifiers,
            ["IntentWiring", "composeIntentWiring"],
            "the detector must find every planted intent-family member — the compose-prefixed "
                + "call included")
    }

    /// A doc comment may name the action family — the scanner strips comments, which is what
    /// lets the composition's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheActionWiringDoesNotTripTheLint() {
        let source = """
            /// The one file in `Sources/VoccaBootstrap` permitted to name ActionWiring and
            /// its recipe — the wiring holds the composition, and everything decided about it
            /// lives above it.
            import VoccaCore
            """
        let identifiers = Self.wiringFamilyIdentifiers(
            ["ActionWiring", "composeActionWiring"], inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }

    /// The same comment-strip control for the intent family.
    func testADocCommentNamingTheIntentWiringDoesNotTripTheLint() {
        let source = """
            /// The three files permitted to name IntentWiring and its recipe — the wiring
            /// holds the composition, and everything decided about it lives above it.
            import VoccaCore
            """
        let identifiers = Self.wiringFamilyIdentifiers(
            ["IntentWiring", "composeIntentWiring"], inSource: source)
        XCTAssertTrue(identifiers.isEmpty, "comments must be stripped before the scan")
    }

    // MARK: - The never-read guards' second half

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

    /// **No intent-family name in the pinned dictation path** — the intent seam's six families
    /// never reach the two digest-pinned files, so a future voice-action dependency there
    /// cannot compile into the dictation path silently. The `IntentSeamBoundaryTests`
    /// confinement already scans the whole `Sources/` tree; this is the same direct guard the
    /// `ActionProvider` leg gives the action seam, asserted against the pinned bytes.
    func testThePinnedDictationFilesNeverNameTheIntentFamilies() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        for relative in Self.pinnedDictationFiles {
            let url = root.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)
            for family in Self.intentFamilyIdentifiers {
                let identifiers = Self.familyOccurrences(family, inSource: source)
                XCTAssertTrue(
                    identifiers.isEmpty,
                    "\(relative) names the \(family) family: \(identifiers) — the dictation "
                        + "path must never depend on intent (C13)")
            }
        }
    }
}

/// The lint's own failure vocabulary.
private enum ActionWiringLintError: Error {
    case sourcesDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)
}