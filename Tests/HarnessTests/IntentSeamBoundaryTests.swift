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

import VoccaCore
import XCTest

/// Raised when the scan cannot be evaluated meaningfully, so that measuring nothing is a failure
/// rather than a pass.
private enum IntentSeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                The intent seam's scan root does not exist at \(expectedAt). The intent family \
                confinement is asserted by scanning the source tree; if the module has moved or \
                been renamed, this lint enforces nothing.
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

/// The intent-seam family lint (`intent-seam` plan Phase 3, `intent-layer` PRD R10): **within
/// `Sources/`, only the permitted files may name the intent families — and each implementation
/// name may appear in exactly its own file.**
///
/// The same shape as ``ReplySeamBoundaryTests`` and its siblings: the seam lives in Core,
/// everything *decided* about intent resolution lives above it in the seam's vocabulary, and
/// this lint is what keeps a caller from branching on an implementation it cannot name outside
/// the permitted files — a second file naming a family means a decision (or a resolution path)
/// has moved somewhere CI cannot see.
///
/// ## The reviewed widening (`action-round-trip`, 2026-09-22)
///
/// The scan root was `VoccaCore` alone when the seam shipped, and the families' permitted sets
/// were the `Intent/` files. The wiring that composes a resolver landed in `VoccaBootstrap`
/// (`IntentWiring.swift`), and the converse step had already carried the resolution vocabulary
/// into its driver, recipe and probe drive — so the confinement now covers **the whole
/// `Sources/` tree**, and the permitted sets name every file that genuinely names a family:
///
/// - the `VoccaCore/Intent/` seam files (the original jurisdiction);
/// - `VoccaBootstrap/IntentWiring.swift` (`action-round-trip`): the `resolve` closure returns
///   ``IntentResolution``, takes `any IntentResolver`, and builds the `[ToolReference]` catalog
///   from the enablement rows — it produces what the driver branches on, never branches itself;
/// - `VoccaBootstrap/ConverseLoopDriver.swift` and `VoccaBootstrap/ConverseWiring.swift`
///   (`converse-step`): the driver's `intentProvider` closure type and its `.ask`/`.toolCall`/
///   `.none` branch, plus the recipe's passthrough;
/// - `VoccaNetworkProbe/ConverseLoopDrive.swift` (`converse-step`): the probe's explicit
///   unwired closure.
///
/// ## The reviewed widening (`probe`, 2026-09-22)
///
/// The composition root and the probe drive landed and joined the permitted sets — the
/// `AppBootstrap.swift` row the `action-round-trip` note above anticipated:
///
/// - `VoccaBootstrap/AppBootstrap.swift` (`probe`): the root's `intentResolver` slot type (the
///   `IntentResolver` row) and the composed default's construction (`NullIntentResolver` — the
///   R7 unwired posture, wired deliberately);
/// - `VoccaNetworkProbe/IntentDrive.swift` (`probe`): the drive constructs the real
///   `KeywordIntentResolver` over a probe-seeded synonym table (both rows), and derives the
///   composed default's fact by naming the `NullIntentResolver` it checks the composed root's
///   slot for — the drive reads the implementations to observe the composition, never to branch
///   a resolution on one.
///
/// Widening the scan root is the deliberate reviewed edit this lint's mechanism exists for: the
/// permitted tables below are the only place a new naming file can appear, and every row is
/// read in review.
///
/// ## The families
///
/// The families are the identifier prefixes below — a prefix rule, so every member of each
/// family is covered by construction:
///
/// - `IntentResolver` (the seam itself): the protocol file and the files whose conformances or
///   consumers must name it;
/// - `IntentResolution` and `ToolReference` (the vocabulary): the seam files, the resolvers,
///   and the composition/branch files above;
/// - `KeywordIntentResolver`, `NullIntentResolver` and `KeywordSynonym`: exactly one file each.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the families to explain what
/// is confined. It is not string-literal aware (see ``SwiftSourceScanner``). Both are deliberate
/// trade-offs of a text scan; what matters is that a *type in code* cannot appear without a
/// reviewed edit to the permitted table below.
///
/// The **seed-table pin** lives here too (R8): the shipped synonym rows are code-level and
/// provisional until SMOKE 148-150 runs, so a retune is a reviewed edit — the pin makes that
/// reviewed edit necessary by asserting the rows verbatim.
final class IntentSeamBoundaryTests: XCTestCase {

    /// The files allowed to name each family, relative to `Sources/` (the scan root — see the
    /// type documentation's reviewed widening).
    ///
    /// **One row per family, and nothing else ever joins a permitted set.** A future file
    /// naming a family requires a reviewed row edit here — which is the point.
    private static let families: [(name: String, permitted: Set<String>)] = [
        (
            name: "IntentResolver",
            permitted: [
                "VoccaCore/Intent/IntentResolver.swift",
                "VoccaCore/Intent/KeywordIntentResolver.swift",
                "VoccaCore/Intent/NullIntentResolver.swift",
                // `phrase-intent-resolver`'s reviewed widening — the second real classifier's
                // own file: it conforms to the seam, reads the catalog and returns the
                // resolution vocabulary, exactly as the keyword resolver's file does.
                "VoccaCore/Intent/PhraseIntentResolver.swift",
                // `action-round-trip`'s reviewed widening — the wiring's `resolve` closure is
                // the seam's consumer: it supplies the catalog and reads the resolution. It
                // names the protocol to call it, never to re-decide with it.
                "VoccaBootstrap/IntentWiring.swift",
                // `probe`'s reviewed widening — the root's `intentResolver` fact carrier slot
                // is typed with the seam. The composition root holds the resolver for the
                // probe to observe; it never resolves with it.
                "VoccaBootstrap/AppBootstrap.swift",
            ]
        ),
        (
            name: "IntentResolution",
            permitted: [
                "VoccaCore/Intent/IntentResolution.swift",
                "VoccaCore/Intent/IntentResolver.swift",
                "VoccaCore/Intent/KeywordIntentResolver.swift",
                "VoccaCore/Intent/NullIntentResolver.swift",
                // `phrase-intent-resolver`'s reviewed widening — the second real classifier's
                // own file: it conforms to the seam, reads the catalog and returns the
                // resolution vocabulary, exactly as the keyword resolver's file does.
                "VoccaCore/Intent/PhraseIntentResolver.swift",
                // `converse-step`'s reviewed widening — the driver's `intentProvider` closure
                // type and its `.ask`/`.toolCall`/`.none` branch, the recipe's passthrough,
                // and the probe drive's explicit unwired closure. All three read the
                // resolution, never resolve with it.
                "VoccaBootstrap/ConverseLoopDriver.swift",
                "VoccaBootstrap/ConverseWiring.swift",
                "VoccaNetworkProbe/ConverseLoopDrive.swift",
                // `action-round-trip`'s reviewed widening — the wiring's `resolve` closure
                // returns the resolution vocabulary (the closure type's signature). It
                // produces what the driver branches on; it never branches itself.
                "VoccaBootstrap/IntentWiring.swift",
            ]
        ),
        (
            name: "ToolReference",
            permitted: [
                "VoccaCore/Intent/IntentResolver.swift",
                "VoccaCore/Intent/KeywordIntentResolver.swift",
                "VoccaCore/Intent/NullIntentResolver.swift",
                // `phrase-intent-resolver`'s reviewed widening — the second real classifier's
                // own file: it conforms to the seam, reads the catalog and returns the
                // resolution vocabulary, exactly as the keyword resolver's file does.
                "VoccaCore/Intent/PhraseIntentResolver.swift",
                // `action-round-trip`'s reviewed widening — the wiring builds the catalog the
                // resolver resolves against, from the enablement rows (R3). It reads the
                // vocabulary to build the seam's input; it never decides with it.
                "VoccaBootstrap/IntentWiring.swift",
            ]
        ),
        (
            name: "KeywordIntentResolver",
            permitted: [
                "VoccaCore/Intent/KeywordIntentResolver.swift",
                // `probe`'s reviewed widening — the drive constructs the real classifier over
                // a probe-seeded synonym table. It runs the shipped machinery; it never
                // branches a resolution on the concrete type.
                "VoccaNetworkProbe/IntentDrive.swift",
            ]
        ),
        (
            name: "NullIntentResolver",
            permitted: [
                "VoccaCore/Intent/NullIntentResolver.swift",
                // `probe`'s reviewed widening — the composition constructs the composed
                // default (R7's unwired posture, a deliberate wiring), and the probe drive
                // names it to derive the composed root's fact. The drive checks which resolver
                // the root holds; it never resolves with the concrete type.
                "VoccaBootstrap/AppBootstrap.swift",
                "VoccaNetworkProbe/IntentDrive.swift",
            ]
        ),
        (
            name: "KeywordSynonym",
            permitted: [
                "VoccaCore/Intent/KeywordIntentResolver.swift",
                // `probe`'s reviewed widening — the drive seeds one row for the probe's own
                // tool, the table's injection point the resolver's initializer exposes.
                "VoccaNetworkProbe/IntentDrive.swift",
            ]
        ),
        (
            name: "PhraseIntentResolver",
            permitted: [
                // `phrase-intent-resolver`'s new family — confined to its own file until a
                // later aspect's reviewed widening composes it.
                "VoccaCore/Intent/PhraseIntentResolver.swift"
            ]
        ),
        (
            name: "PhraseIntentRow",
            permitted: [
                "VoccaCore/Intent/PhraseIntentResolver.swift"
            ]
        ),
    ]

    /// Every occurrence of a family identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedKeywordIntentResolverUse``.
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
            throw IntentSeamTestError.noSwiftFilesScanned(under: root.path)
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
    func testOnlyThePermittedFilesInSourcesMayNameTheIntentFamilies() throws {
        let root = try sourcesRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw IntentSeamTestError.seamDirectoryMissing(expectedAt: root.path)
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

    /// The lint's negative control for the keyword resolver: planted source is caught — in the
    /// shapes a leaked use would actually take.
    func testTheLintDetectsAPlantedKeywordIntentResolverUse() {
        let source = """
            public struct Leak {
                public var resolver: KeywordIntentResolver?
                public func resolve(_ utterance: String, against catalog: [ToolReference])
                    -> IntentResolution
                {
                    KeywordIntentResolver().resolve(utterance, against: catalog)
                }
            }
            """
        XCTAssertEqual(
            Self.familyIdentifiers("KeywordIntentResolver", inSource: source),
            ["KeywordIntentResolver", "KeywordIntentResolver"],
            "the detector must find every planted use — the declaration and the decision point")
    }

    /// The lint's negative control for the composed default — the twin of the planted
    /// `KeywordIntentResolver` test.
    func testTheLintDetectsAPlantedNullIntentResolverUse() {
        let source = """
            public struct Leak {
                public var resolver: NullIntentResolver?
            }
            """
        XCTAssertEqual(
            Self.familyIdentifiers("NullIntentResolver", inSource: source),
            ["NullIntentResolver"],
            "the detector must find the planted type")
    }

    /// The lint's negative control for the vocabulary: a decision point naming a
    /// ``ToolReference`` (or the resolution type) outside the seam files is a decision CI cannot
    /// see.
    func testTheLintDetectsAPlantedVocabularyUseOutsideTheSeam() {
        let source = """
            public struct Leak {
                public func isEnabled(_ tool: ToolReference) -> Bool {
                    tool.displayName.isEmpty
                }
                public var kind: IntentResolution = .none
            }
            """
        XCTAssertEqual(
            Self.familyIdentifiers("ToolReference", inSource: source),
            ["ToolReference"],
            "the detector must find the planted catalog type")
        XCTAssertEqual(
            Self.familyIdentifiers("IntentResolution", inSource: source),
            ["IntentResolution"],
            "the detector must find the planted resolution type")
    }

    /// A doc comment may name the families — the scanner strips comments, which is what lets the
    /// seam's documentation explain what it confines without tripping the lint.
    func testADocCommentNamingTheIntentFamiliesDoesNotTripTheLint() {
        let source = """
            /// The six families confined to `Sources/VoccaCore/Intent`: IntentResolver,
            /// IntentResolution, ToolReference, KeywordIntentResolver, NullIntentResolver and
            /// KeywordSynonym — the seam holds the slot, and everything decided about intent
            /// resolution lives above it.
            import VoccaCore
            """
        for family in Self.families {
            XCTAssertTrue(
                Self.familyIdentifiers(family.name, inSource: source).isEmpty,
                "comments must be stripped before the scan — \(family.name) was seen in one")
        }
    }

    /// Scanning nothing must **fail**, not pass — the vacuity guard every leg above depends on.
    func testScanningNoSwiftFilesIsAFailureNotAPass() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-intent-seam-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertThrowsError(try sightings(of: "IntentResolver", under: empty)) { error in
            guard case IntentSeamTestError.noSwiftFilesScanned = error else {
                return XCTFail("scanning an empty tree must report that nothing was scanned")
            }
        }
    }

    // MARK: - The seed-table pin (R8)

    /// The shipped synonym rows, pinned **verbatim** — so a retune of a wrong seed is a reviewed
    /// edit to ``KeywordIntentResolver/shippedSynonyms``, exactly as R8 records, rather than a
    /// silent change.
    func testTheShippedSynonymRowsArePinnedVerbatim() {
        let expected: [KeywordSynonym] = [
            KeywordSynonym(
                phrase: "clear the audit log", providerID: "dev.vocca.audit",
                toolID: "audit.clear"),
            KeywordSynonym(
                phrase: "count the audit log", providerID: "dev.vocca.audit",
                toolID: "audit.count"),
            KeywordSynonym(
                phrase: "post a message", providerID: "dev.vocca.mcp.chat",
                toolID: "post_message", arguments: #"{"text": "{{utterance}}"}"#),
        ]

        XCTAssertEqual(
            KeywordIntentResolver.shippedSynonyms, expected,
            "the shipped synonym table must match its pin — retuning a wrong seed is a reviewed "
                + "edit, and the pin is what makes it one")
        XCTAssertEqual(
            KeywordIntentResolver.shippedSynonyms.count, 3,
            "a fourth row is a reviewed widening, not a silent addition")
    }

    /// The seeded threshold and the utterance placeholder, pinned — the two numbers a retune
    /// would reach for first.
    func testTheNotConfidentThresholdAndPlaceholderArePinned() {
        XCTAssertEqual(
            KeywordIntentResolver.notConfidentThreshold, 0.75,
            "the not-confident threshold is seeded (R2); moving it changes what resolves and "
                + "what asks, so the move is a reviewed edit")
        XCTAssertEqual(
            KeywordIntentResolver.utterancePlaceholder, "{{utterance}}",
            "the placeholder is part of the seeded table's contract — the shipped rows spell it")
    }
}