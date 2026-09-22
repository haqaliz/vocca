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
private enum ConverseWiringSeamTestError: Error, CustomStringConvertible {
    case sourcesDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .sourcesDirectoryMissing(let expectedAt):
            return """
                The Sources directory does not exist at \(expectedAt). The converse-family \
                confinement is asserted by scanning the source tree; if the package has moved, \
                this lint enforces nothing.
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

/// The converse-family lint (`converse-wiring` Phase 6): the two new names live only in the
/// files below — a second implementer, or a decision, cannot appear where CI cannot see it.
/// The `KokoroSeamBoundaryTests` shape exactly (comments stripped, permitted-file table keyed
/// by identifier-prefix family, the planted-violation and comment-strip controls, the
/// non-vacuous guards).
///
/// ## The families
///
/// - `ConverseLoopDriver` → its definition (`VoccaBootstrap/ConverseLoopDriver.swift`), the
///   recipe (`ConverseWiring.swift` — the composition's construction site), the root's slot
///   (`AppBootstrap.swift`), and the probe drive (`VoccaNetworkProbe/ConverseLoopDrive.swift`).
///   The **widget-converse** aspect consumes the root's two converse slots (`converseStateSink`,
///   `converseFailureSink`) — the driver's name must not leak into `VoccaUI`; the **mode
///   machine** consumes `start()`/`stop()` only — the converse slot the machine's effects route
///   into, never the driver's internals.
/// - `ConverseTurnFailure` → its definition (`VoccaCore/TurnTaking/ConverseTurnFailure.swift`),
///   the driver's sink signature (`ConverseLoopDriver.swift`), and the root's slot
///   (`AppBootstrap.swift`). (The plan's letter named "the same three consumers" as the
///   driver's — the recipe and the probe drive infer the type without naming it, and a
///   permitted file that does not name its family fails the non-vacuous guard; the honest set
///   is the files that actually name it.)
/// - `IntentResolution` (`converse-step`'s widening) → its four Core declarations/readers
///   (the intent-seam lint's own jurisdiction, `IntentSeamBoundaryTests`) plus the three
///   converse files the widened driver's signature carries it into: the driver's `intentProvider`
///   closure type, the recipe's passthrough parameter, and the probe drive's explicit unwired
///   closure. The driver reads the resolution to branch — `.ask` speaks, `.toolCall` acts,
///   `.none`/unwired falls through — it never resolves with it.
///
/// ## The `TextInjector` VoccaBootstrap leg (the recorded amendment obligation)
///
/// The `mode-machine` lint recorded: "the `converse-wiring` aspect must amend this row (or add
/// a `VoccaBootstrap` leg) when its converse files land". The converse files landed in
/// `VoccaBootstrap` (outside the mode lint's `VoccaCore` scan root), so this lint carries the
/// leg: code-level `TextInjector` sightings within `VoccaBootstrap` are confined to
/// `AppBootstrap.swift` — the dictation composition's two sites — and the converse files name
/// it nowhere (the roadmap acceptance's CI leg, `CAPABILITY_ROADMAP.md:319`).
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the family to explain what
/// is confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are
/// deliberate trade-offs of a text scan; what matters is that a *type in code* cannot appear
/// without a reviewed edit to the permitted lists below.
final class ConverseWiringSeamBoundaryTests: XCTestCase {

    /// The scan root — the whole package, because the converse family spans three modules.
    private static let seamModuleRoot = "Sources"

    /// The two families of the converse wiring's surface, each with the files permitted to name
    /// it (relative to ``seamModuleRoot``). **Each list is deliberate; nothing joins it without
    /// a reviewed edit.**
    private static let converseFamilies: [(name: String, permitted: Set<String>)] = [
        (
            "ConverseLoopDriver",
            [
                "VoccaBootstrap/ConverseLoopDriver.swift",
                "VoccaBootstrap/ConverseWiring.swift",
                "VoccaBootstrap/AppBootstrap.swift",
                "VoccaNetworkProbe/ConverseLoopDrive.swift",
            ]
        ),
        (
            "ConverseTurnFailure",
            [
                "VoccaCore/TurnTaking/ConverseTurnFailure.swift",
                "VoccaBootstrap/ConverseLoopDriver.swift",
                "VoccaBootstrap/AppBootstrap.swift",
            ]
        ),
        (
            "IntentResolution",
            [
                // The Core files are the intent-seam lint's own jurisdiction
                // (`IntentSeamBoundaryTests` within VoccaCore); they are listed here because
                // this lint's scan root is the whole package.
                "VoccaCore/Intent/IntentResolution.swift",
                "VoccaCore/Intent/IntentResolver.swift",
                "VoccaCore/Intent/KeywordIntentResolver.swift",
                "VoccaCore/Intent/NullIntentResolver.swift",
                // `converse-step`'s reviewed widening — the three converse files the widened
                // driver's signature carries the resolution vocabulary into. The driver
                // branches on it (`.ask`/`.toolCall`/`.none`), the recipe passes the closure
                // through, and the probe drive spells the unwired closure explicitly — all
                // three read it, never resolve with it.
                "VoccaBootstrap/ConverseLoopDriver.swift",
                "VoccaBootstrap/ConverseWiring.swift",
                "VoccaNetworkProbe/ConverseLoopDrive.swift",
            ]
        ),
    ]

    /// The `VoccaBootstrap` leg of the `TextInjector` prohibition — the converse files must not
    /// name the injection ladder (the mode-machine lint's recorded amendment obligation).
    private static let injectorLegModuleRoot = "VoccaBootstrap"
    private static let filesPermittedToNameTheInjector: Set<String> = [
        "AppBootstrap.swift"
    ]

    private func sourcesRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath).appendingPathComponent("Sources")
    }

    /// Every occurrence of a family identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedConverseFamilyUse``.
    private static func familyIdentifiers(inSource source: String, family: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b" + family + "[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// Every `TextInjector` occurrence in `source`, comments removed first.
    private static func injectorIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        guard let regex = try? NSRegularExpression(pattern: "\\bTextInjector\\b") else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// Every sighting of `family` under `root`, honouring `permitted`.
    private func sightings(
        of family: String, under root: URL
    ) throws -> [String: [String]] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ConverseWiringSeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var byFile: [String: [String]] = [:]
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            let identifiers = Self.familyIdentifiers(inSource: source, family: family)
            if !identifiers.isEmpty {
                byFile[relative] = identifiers
            }
        }
        return byFile
    }

    // MARK: - The converse families

    /// The whole of the confinement, per family: every sighting sits in the permitted files, and
    /// the permitted files are the only ones permitted.
    ///
    /// Two independent claims per family, because either one failing alone still passes a
    /// one-sided check: "no other file names the family" passes if the permitted files *also*
    /// lost their implementation (the family used everywhere else — vacuous), and "the permitted
    /// files name the family" passes if three files do (the seam has sprung a leak). The
    /// non-vacuous guards are the `KokoroSeamBoundaryTests` ones verbatim: the permitted set is
    /// never empty, each permitted file must actually name its family, and the sighting count
    /// equals the permitted count.
    func testTheConverseFamilyLivesOnlyInItsPermittedFiles() throws {
        let root = try sourcesRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ConverseWiringSeamTestError.sourcesDirectoryMissing(expectedAt: root.path)
        }

        for (name, permitted) in Self.converseFamilies {
            let sightings = try sightings(of: name, under: root)

            let offenders = sightings.keys.filter { !permitted.contains($0) }
            XCTAssertTrue(
                offenders.isEmpty,
                "family \(name) is named outside its permitted files: \(offenders.sorted())")

            XCTAssertFalse(
                permitted.isEmpty,
                "the permitted list for \(name) must not be empty — an empty list passes "
                    + "'no file names it' vacuously")
            for file in permitted {
                XCTAssertFalse(
                    sightings[file]?.isEmpty ?? true,
                    "the permitted file \(file) must actually name the family \(name) — a "
                        + "permitted file that does not means the family moved somewhere else "
                        + "and the lint cannot see it")
            }
            XCTAssertEqual(
                sightings.count, permitted.count,
                "exactly the permitted set may name \(name), got \(sightings.keys.sorted())")
        }
    }

    // MARK: - The `TextInjector` VoccaBootstrap leg

    /// **Code-level `TextInjector` sightings in `VoccaBootstrap` are confined to the dictation
    /// composition's file** — the `AppBootstrap.swift` two sites (the injector composition and
    /// the `DeferredLadder` forward). The converse files name it nowhere: in converse mode no
    /// `TextInjector` call is ever made (`CAPABILITY_ROADMAP.md:319`), and the converse driver
    /// has no injector seam to reach (the mode-machine lint's recorded amendment obligation,
    /// discharged as the "add a `VoccaBootstrap` leg" option).
    func testTextInjectorIsNamedOnlyInTheDictationCompositionFile() throws {
        let root = try sourcesRoot().appendingPathComponent(
            Self.injectorLegModuleRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ConverseWiringSeamTestError.sourcesDirectoryMissing(expectedAt: root.path)
        }
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ConverseWiringSeamTestError.noSwiftFilesScanned(under: root.path)
        }

        var sightings: [String: [String]] = [:]
        for file in files {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let code = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            let identifiers = Self.injectorIdentifiers(inSource: code)
            if !identifiers.isEmpty {
                sightings[relative] = identifiers
            }
        }

        XCTAssertFalse(
            Self.filesPermittedToNameTheInjector.isEmpty,
            "the permitted set must not be empty — an empty list passes 'no file names it' vacuously")
        for file in Self.filesPermittedToNameTheInjector {
            XCTAssertFalse(
                sightings[file]?.isEmpty ?? true,
                "the permitted file \(file) must actually name the injector — a permitted file "
                    + "that does not means the injector moved somewhere else and the lint cannot see it")
        }
        XCTAssertEqual(
            Set(sightings.keys), Self.filesPermittedToNameTheInjector,
            """
            The injector is named in code outside the dictation composition: \
            \(sightings.keys.sorted()). In converse mode no TextInjector call is ever made \
            (CAPABILITY_ROADMAP.md:319) — a converse-path file that names it is a conversation \
            reaching for the injection ladder. If the naming file is a deliberate dictate-path \
            change, amend the permitted set in review.
            """)
    }

    // MARK: - Controls

    /// The lint's negative control for the families: planted source is caught — every family
    /// member, in the shapes a leaked implementer would actually use them.
    func testTheLintDetectsAPlantedConverseFamilyUse() {
        let source = """
            import VoccaBootstrap

            public struct Leak {
                public let driver: ConverseLoopDriver?
                public let failure: ConverseTurnFailure?
                public let resolution: IntentResolution?
            }
            """
        for (name, _) in Self.converseFamilies {
            let identifiers = Self.familyIdentifiers(inSource: source, family: name)
            XCTAssertEqual(
                identifiers, [name],
                "the detector must find every planted \(name) member")
        }
    }

    /// The prohibition leg's negative control: a converse-shaped file naming the injector is
    /// caught — the detector that proves the CI leg can see a violation.
    func testTheLintDetectsAPlantedInjectorInAConverseFile() {
        let source = """
            import VoccaCore

            public struct ConverseDriver {
                public let injector: any TextInjector
            }
            """
        let identifiers = Self.injectorIdentifiers(inSource: source)
        XCTAssertEqual(
            identifiers, ["TextInjector"],
            "the prohibition detector cannot see an injector it was shown, so it permits one")
    }

    /// A doc comment may name the family and the injector — the scanner strips comments, which
    /// is what lets the wiring's documentation explain what it confines without tripping the
    /// lint.
    func testADocCommentNamingTheFamilyDoesNotTripTheLint() {
        let source = """
            /// The one place ConverseLoopDriver and ConverseTurnFailure may meet the root — the
            /// recipe's delivery. The converse path never names TextInjector.
            import VoccaCore
            """
        for (name, _) in Self.converseFamilies {
            XCTAssertTrue(
                Self.familyIdentifiers(inSource: source, family: name).isEmpty,
                "comments must be stripped before the scan")
        }
        XCTAssertTrue(
            Self.injectorIdentifiers(inSource: source).isEmpty,
            "comments must be stripped before the scan")
    }
}