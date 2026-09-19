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
private enum ActionSeamTestError: Error, CustomStringConvertible {
    case seamDirectoryMissing(expectedAt: String)
    case noSwiftFilesScanned(under: String)

    var description: String {
        switch self {
        case .seamDirectoryMissing(let expectedAt):
            return """
                The action seam's directory does not exist at \(expectedAt). The action family \
                confinement is asserted by scanning the source tree; if the seam has moved or \
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

/// The action-seam family lint (`action-seam` plan Phase 3), in two families.
///
/// **Family A — the vocabulary.** Within `Sources/`, only the eight files of
/// `VoccaCore/Actions/` may name the action families. The same shape as
/// ``ContextSeamBoundaryTests``: the seam lives in Core, everything *decided* about acting lives
/// above it in the seam's vocabulary, and this lint is what keeps a caller from branching on a
/// type it should not be able to name — a second file naming a family means a decision has moved
/// somewhere CI cannot see. Tests legitimately name the vocabulary (``ActionSeamTests`` does), so
/// Family A's scan root is `Sources/` alone.
///
/// **Family B — the forgery guard, and the load-bearing half.** ``ActionConfirmation``'s
/// initializer is `internal`, so a test written with a plain `import VoccaCore` — the convention
/// in 201 of this target's files — structurally cannot mint one. The residual hole is a test that
/// adds `@testable import VoccaCore`: that compiles, and access control cannot reach it. So it is
/// closed the other way, by confining *construction of the token* and scanning `Sources/` **and**
/// `Tests/` alike. A forging test fails this lint even though it would compile. The two
/// mechanisms are complementary and neither is sufficient alone — which is exactly what
/// `ActionConfirmation.swift`'s own doc comment says, and this suite is the half of that claim
/// that CI executes.
///
/// ## The permitted construction set holds exactly one file, by a reviewed edit
///
/// It was empty until `confirmation-gate` landed, because nothing in the tree legitimately minted a
/// token. `ActionGate.swift` is the first site that does, and it joined
/// ``filesPermittedToConstructAConfirmation`` here rather than by working around the lint — which
/// is the guard doing its job, not being defeated. The whole purpose of confining construction is
/// that every minting site costs a deliberate edit to this file and is read in review; a guard that
/// admitted the second one silently would have protected nothing.
///
/// **Exactly one, and a second is a design problem rather than a lint problem.** More than one file
/// minting means more than one place decides that an action may act, and the structural refusal is
/// only structural while there is a single door. So the count is asserted below, and raising it
/// requires answering why the gate is no longer the only decision point.
///
/// **No file under `Tests/` may ever join the set.** The whole of Family B's value is that a test
/// with `@testable import VoccaCore` compiles and still fails this lint; admitting one would close
/// the loop the other way and let a forging test authorise itself. That is asserted rather than
/// remembered.
///
/// The permitted set would still pass "no other file names it" vacuously if the type itself were
/// renamed away or its initializer quietly made `public` — so it is anchored, not assumed, by
/// ``testTheConfirmationInitializerStaysUnforgeableOutsideTheModule``.
///
/// ## Family A grows by **five rows per real provider**, and that is expected
///
/// A provider implementing ``ActionProvider`` from outside `VoccaCore/Actions/` costs **five**
/// permitted-set rows, not one — and the seam's own signatures are what force it. The conformance
/// names `ActionProvider`; `describe` names `ActionInvocation` and returns `ActionSummary`;
/// `invoke` takes an `ActionConfirmation` and returns an `ActionOutcome`. Swift has no spelling
/// that omits a parameter or a return type, so there is no way to write a conformance that names
/// fewer. The `ActionInvocation` row below already anticipated this in its note about the probe's
/// audit drive, which deliberately stops short of conforming for exactly this reason.
///
/// So five rows naming **one new file** is one reviewed widening, not five decisions, and it is
/// the lint working rather than being worked around. `audit-provider`'s `AuditActionProvider` is
/// the first of them. **A later provider author should add their five rows and carry on** rather
/// than stopping to ask whether the count means something has gone wrong.
///
/// **The known next move, recorded and deliberately not taken:** if a third provider makes the
/// enumerated sets unwieldy, the alternative is to permit a blessed directory —
/// `Sources/VoccaActions/Providers/` — by rule instead of enumerating files. The trade is the
/// reason it is not taken now: a directory rule permits **any** file dropped into it, so the
/// per-file review that is the whole mechanism here would be replaced by a per-directory one. Two
/// providers do not yet justify that, and the decision should be made in review when a third
/// arrives, not inherited from a tidying edit.
///
/// ## What this lint does and does not see
///
/// It reads text with comments stripped, so a doc comment may name the families — and describe the
/// forgery it forbids — to explain what is confined. It is **not** string-literal aware (see
/// ``SwiftSourceScanner``): a construction inside a string literal would be reported, and this
/// file is itself inside Family B's scan root, which is why its planted samples are assembled from
/// ``constructionMarker`` rather than written out verbatim. Both are deliberate trade-offs of a
/// text scan; what matters is that a *construction in code* cannot appear without a reviewed edit
/// to the tables below.
///
/// **It also under-reports, and `audit-provider` is where that first became load-bearing.**
/// `AuditActionProvider` classifies both of its tools by blast radius — one read-only, one
/// destructive — and yet has **no `BlastRadius` row**, because it writes the radii as leading-dot
/// literals (`blastRadius: .destructive`) and the scan sees only spelled identifiers. That is
/// idiomatic Swift and was left as it is; what must not happen is the absence of the row being
/// read as evidence that the provider does not use radii. It uses them; the lint cannot see it.
///
/// The general form: **a permitted set is a list of files that *name* a family, never a list of
/// the files that *use* one.** Every text-scan lint in this repository has that gap, and inferring
/// "no row, therefore no use" from any of them is unsound. What the tables do enforce — a
/// *declaration or a spelled reference* cannot move somewhere CI cannot see — is unaffected, and
/// is the claim these tests actually make.
final class ActionSeamBoundaryTests: XCTestCase {

    // MARK: - Family A: the action vocabulary

    /// The files allowed to name each family, relative to `Sources/`.
    ///
    /// **One row per family, and nothing else ever joins a permitted set.** The `VoccaActions`
    /// target that `audit-log` reserves is outside `VoccaCore` but inside this scan root, so its
    /// arrival is a reviewed row edit here — which is the point.
    private static let families: [(name: String, permitted: Set<String>)] = [
        (
            name: "ActionProvider",
            permitted: [
                "VoccaCore/Actions/ActionGate.swift",
                "VoccaCore/Actions/ActionProvider.swift",
                "VoccaCore/Actions/NullActionProvider.swift",
                // `audit-provider`'s reviewed widening — the second real implementation
                // behind the seam, and one of the five rows the conformance costs. See the
                // type documentation for why a provider outside VoccaCore/Actions/ names
                // five families and why that is one widening rather than five.
                "VoccaActions/Providers/AuditActionProvider.swift",
            ]
        ),
        (
            name: "ActionInvocation",
            permitted: [
                "VoccaCore/Actions/ActionGate.swift",
                "VoccaCore/Actions/ActionInvocation.swift",
                "VoccaCore/Actions/ActionProvider.swift",
                "VoccaCore/Actions/NullActionProvider.swift",
                // The `audit-log` aspect's reviewed widening — the arrival this table's header
                // anticipated. The entry is attributed to the invocation that produced it, and
                // the store's `record` takes one; both are the audit log reading the vocabulary,
                // never a second place deciding with it.
                "VoccaActions/Audit/ActionAuditEntry.swift",
                "VoccaActions/Audit/FileSystemActionAuditStore.swift",
                // The probe's audit drive, which must name an invocation to record one. It is
                // the narrowest widening available: the drive deliberately does NOT conform to
                // `ActionProvider`, which would have put four more families — `ActionConfirmation`
                // among them — into a file whose subject is the file system, not the seam.
                "VoccaNetworkProbe/ActionAuditDrive.swift",
                // `audit-provider`'s reviewed widening — the second real implementation
                // behind the seam, and one of the five rows the conformance costs. See the
                // type documentation for why a provider outside VoccaCore/Actions/ names
                // five families and why that is one widening rather than five.
                "VoccaActions/Providers/AuditActionProvider.swift",
            ]
        ),
        (
            name: "ActionSummary",
            permitted: [
                "VoccaCore/Actions/ActionGate.swift",
                "VoccaCore/Actions/ActionSummary.swift",
                "VoccaCore/Actions/ActionProvider.swift",
                "VoccaCore/Actions/NullActionProvider.swift",
                // The probe's audit drive again, for the same reason: the decisions it records
                // carry a summary, and a decision without one cannot be built. See the
                // ActionInvocation row for why the drive stops short of the seam itself.
                "VoccaNetworkProbe/ActionAuditDrive.swift",
                // `audit-provider`'s reviewed widening — the second real implementation
                // behind the seam, and one of the five rows the conformance costs. See the
                // type documentation for why a provider outside VoccaCore/Actions/ names
                // five families and why that is one widening rather than five.
                "VoccaActions/Providers/AuditActionProvider.swift",
            ]
        ),
        (
            name: "ActionOutcome",
            permitted: [
                "VoccaCore/Actions/ActionGate.swift",
                "VoccaCore/Actions/ActionOutcome.swift",
                "VoccaCore/Actions/ActionProvider.swift",
                "VoccaCore/Actions/NullActionProvider.swift",
                // The `audit-log` aspect's reviewed widening: the entry records the outcome and
                // owns its persisted vocabulary, which is why the mapping is in the module that
                // owns the file rather than as a conformance on the core's enum.
                "VoccaActions/Audit/ActionAuditEntry.swift",
                // `audit-provider`'s reviewed widening — the second real implementation
                // behind the seam, and one of the five rows the conformance costs. See the
                // type documentation for why a provider outside VoccaCore/Actions/ names
                // five families and why that is one widening rather than five.
                "VoccaActions/Providers/AuditActionProvider.swift",
            ]
        ),
        (
            name: "ActionConfirmation",
            permitted: [
                "VoccaCore/Actions/ActionGate.swift",
                "VoccaCore/Actions/ActionConfirmation.swift",
                "VoccaCore/Actions/ActionProvider.swift",
                "VoccaCore/Actions/NullActionProvider.swift",
                // `audit-provider`: the provider NAMES the token in `invoke`'s signature and
                // never constructs one — Family B below is the check that says so, and it is
                // unchanged by this widening.
                "VoccaActions/Providers/AuditActionProvider.swift",
            ]
        ),
        (
            name: "BlastRadius",
            permitted: [
                "VoccaCore/Actions/ActionGate.swift",
                "VoccaCore/Actions/BlastRadius.swift",
                "VoccaCore/Actions/ActionSummary.swift",
                // The `audit-log` aspect's reviewed widening: the entry records the **effective**
                // radius and maps it to the persisted vocabulary. It reads
                // `requiresConfirmation` — the core's single branch point — rather than
                // re-deriving the rule, so this row admits a reader of the classification, never
                // a second classifier.
                "VoccaActions/Audit/ActionAuditEntry.swift",
            ]
        ),
        (name: "NullActionProvider", permitted: ["VoccaCore/Actions/NullActionProvider.swift"]),
    ]

    /// Every occurrence of a family identifier in `source`, comments removed first.
    ///
    /// A pure function over a string, so it can be run against source that violates the rule —
    /// which is the only way to know it would catch one. See
    /// ``testTheLintDetectsAPlantedActionProviderUse``.
    ///
    /// The prefix rule covers every member of a family by construction. Note that it is a *word*
    /// prefix: `NullActionProvider` is not an `ActionProvider` sighting, because there is no word
    /// boundary inside it — the two families are counted separately and deliberately.
    private static func familyIdentifiers(_ family: String, inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + family + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    // MARK: - Family B: construction of the confirmation token

    /// The name of the token, and the two texts that construct one, assembled rather than written.
    ///
    /// This file is inside Family B's scan root and the scanner is not string-literal aware, so a
    /// planted sample containing the construction verbatim would make this suite its own first
    /// offender. Assembling the marker keeps the detector honest about the tree *and* about
    /// itself: nothing here is exempted from the scan.
    private static let confirmationType = "ActionConfirmation"
    private static let constructionMarker = confirmationType + "("
    private static let initConstructionMarker = confirmationType + ".init("

    /// The file permitted to construct an ``ActionConfirmation``, relative to the package root.
    ///
    /// **Exactly one: the confirmation gate** — see the type-level documentation for why it joined
    /// and why nothing else may. `confirmation-gate` made this the first reviewed widening; a second
    /// entry means the gate has stopped being the single decision point, which is a design question
    /// to answer before it is an edit to make.
    private static let filesPermittedToConstructAConfirmation: Set<String> = [
        "Sources/VoccaCore/Actions/ActionGate.swift"
    ]

    /// The file that declares the token — the anchor that stops the empty permitted set above
    /// from passing vacuously.
    private static let confirmationDeclarationFile =
        "Sources/VoccaCore/Actions/ActionConfirmation.swift"

    /// Every construction of the confirmation token in `source`, comments removed first,
    /// whitespace normalised out of the match so `Type ()` and `Type .init ()` report as the two
    /// canonical markers.
    ///
    /// A pure function over a string, for the same reason as ``familyIdentifiers(_:inSource:)``:
    /// it is run against a deliberately forging test in
    /// ``testTheLintDetectsAPlantedConfirmationForgeryInATest``, which is the only way to know it
    /// would catch one.
    ///
    /// **Known limit:** it cannot see a construction written as `Self()` or through a `typealias`.
    /// Both are only reachable from inside `VoccaCore`, where the `internal` initializer is the
    /// first line of defence and this lint is the second.
    private static func confirmationConstructions(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b" + confirmationType + "\\s*(?:\\.init)?\\s*\\("
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map {
                String(code[$0]).filter { !$0.isWhitespace }
            }
        }
    }

    // MARK: - Roots

    private func packageRoot() throws -> URL {
        try PackageRootLocator.find(from: #filePath)
    }

    private func sourcesRoot() throws -> URL {
        try packageRoot().appendingPathComponent("Sources")
    }

    /// Every sighting of `family` under `root`, keyed by path relative to `root`.
    ///
    /// Throws rather than returning an empty dictionary when nothing was scanned: "no file names
    /// the family" and "no file was read" are the same green and must not be.
    private func sightings(of family: String, under root: URL) throws -> [String: [String]] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else {
            throw ActionSeamTestError.noSwiftFilesScanned(under: root.path)
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

    /// Every construction sighting across `Sources/` and `Tests/`, keyed by path relative to the
    /// package root.
    ///
    /// Both roots are scanned and each must yield files of its own — a `Tests/` tree that was
    /// silently not reached would turn the whole forgery guard into decoration.
    private func confirmationConstructionSightings() throws -> [String: [String]] {
        let root = try packageRoot()
        var byFile: [String: [String]] = [:]
        for directory in ["Sources", "Tests"] {
            let subtree = root.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: subtree.path) else {
                throw ActionSeamTestError.seamDirectoryMissing(expectedAt: subtree.path)
            }
            let files = SwiftSourceScanner.swiftFiles(under: subtree)
            guard !files.isEmpty else {
                throw ActionSeamTestError.noSwiftFilesScanned(under: subtree.path)
            }
            for file in files {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                let source = try String(contentsOf: file, encoding: .utf8)
                let constructions = Self.confirmationConstructions(inSource: source)
                if !constructions.isEmpty {
                    byFile[relative] = constructions
                }
            }
        }
        return byFile
    }

    // MARK: - Family A: the confinement

    /// The whole of the vocabulary's confinement, per family: every sighting sits in the permitted
    /// set, every permitted file exists and names the family, and the permitted set is the only
    /// one permitted.
    ///
    /// Three independent claims, because any one failing alone still passes a one-sided check:
    /// "no other file names the family" passes if the permitted file *also* lost its
    /// implementation (the family used everywhere else — vacuous), and "the permitted file names
    /// the family" passes if three files do (the seam has sprung a leak). The `sightings.count`
    /// equality is the third leg: exactly the permitted set may name the family.
    func testOnlyTheActionsFilesInSourcesMayNameTheActionFamilies() throws {
        let root = try sourcesRoot()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ActionSeamTestError.seamDirectoryMissing(expectedAt: root.path)
        }

        for family in Self.families {
            let sightings = try sightings(of: family.name, under: root)

            let offenders = sightings.keys.filter { !family.permitted.contains($0) }
            XCTAssertTrue(
                offenders.isEmpty,
                "the \(family.name) family is named outside the permitted files: \(offenders.sorted())"
            )

            XCTAssertFalse(
                family.permitted.isEmpty,
                "a permitted set must not be empty — an empty set passes 'no file names it' vacuously"
            )
            for file in family.permitted {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(file).path),
                    "every permitted file must exist — a renamed-away file passes vacuously: \(file)")
                XCTAssertFalse(
                    sightings[file]?.isEmpty ?? true,
                    "a permitted file must actually name the family — a permitted file that does "
                        + "not means the family moved somewhere else and the lint cannot see it: "
                        + "\(file)")
            }
            XCTAssertEqual(
                sightings.count, family.permitted.count,
                "exactly the permitted set may name \(family.name), got \(sightings.keys.sorted())")
        }
    }

    // MARK: - Family B: the forgery guard

    /// The forgery guard itself: across `Sources/` **and** `Tests/`, only the permitted set may
    /// construct an ``ActionConfirmation`` — and the permitted set is the confirmation gate alone.
    ///
    /// The same three legs as Family A, for the same reason, and two more that the widening turned
    /// on. The middle leg stopped being vacuous the day `ActionGate.swift` joined the set: a
    /// permitted file that has *stopped* minting now fails here, which is what catches a mint that
    /// moved somewhere this lint cannot see rather than disappeared.
    func testNoFileInSourcesOrTestsMayConstructAnActionConfirmation() throws {
        let sightings = try confirmationConstructionSightings()
        let permitted = Self.filesPermittedToConstructAConfirmation

        XCTAssertEqual(
            permitted.count, 1,
            """
            exactly one file may mint a confirmation, and it is the gate: \(permitted.sorted()).
            A second minting site means a second place decides that an action may act, and the \
            refusal is only structural while there is a single door — raise this number only \
            after answering that, in review.
            """)
        for file in permitted {
            XCTAssertFalse(
                file.hasPrefix("Tests/"),
                """
                no file under Tests/ may ever be permitted to mint: \(file). Family B's whole \
                value is that a forging test compiles and still fails this lint, and admitting \
                one would let a test authorise itself.
                """)
        }

        let offenders = sightings.keys.filter { !permitted.contains($0) }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            the confirmation token is constructed outside the permitted set: \(offenders.sorted()).
            Only the confirmation gate may mint one; a test that reaches the initializer through \
            `@testable import VoccaCore` compiles, and this is the check that refuses it.
            """)

        let root = try packageRoot()
        for file in permitted {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path),
                "every permitted file must exist — a renamed-away file passes vacuously: \(file)")
            XCTAssertFalse(
                sightings[file]?.isEmpty ?? true,
                "a permitted file must actually construct the token — one that does not means the "
                    + "mint moved somewhere this lint cannot see it: \(file)")
        }

        XCTAssertEqual(
            sightings.count, permitted.count,
            "exactly the permitted set may construct the token, got \(sightings.keys.sorted())")
    }

    /// The anchor under the empty permitted set: the token still exists, is still a `public`
    /// type, and its initializer is still **not** `public`.
    ///
    /// Without this, "no file constructs one" would go on passing after the type was renamed away,
    /// deleted, or — the dangerous one — had its initializer made `public`, at which point every
    /// module in the package could mint a confirmation and this lint, which only watches
    /// `Sources/` and `Tests/`, would still be green.
    func testTheConfirmationInitializerStaysUnforgeableOutsideTheModule() throws {
        let url = try packageRoot().appendingPathComponent(Self.confirmationDeclarationFile)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "the declaring file must exist — without it the empty permitted set means nothing")

        let code = SwiftSourceScanner.stripComments(
            from: try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(
            code.contains("public struct " + Self.confirmationType),
            "the token must still be the public struct the seam's signatures name")
        XCTAssertTrue(
            code.contains("init()"),
            "the token must still declare the initializer this lint confines")
        for leak in ["public init", "package init", "open init"] {
            XCTAssertFalse(
                code.contains(leak),
                "the token's initializer must not be \(leak) — that opens the forgery hole outside "
                    + "the reach of any text lint")
        }
    }

    // MARK: - Planted controls

    /// Family A's negative control: planted source is caught — in the shape a leaked use would
    /// actually take.
    ///
    /// A scan that has only ever seen a clean tree is a scan nobody has watched work.
    func testTheLintDetectsAPlantedActionProviderUse() {
        let source = """
            public struct Leak {
                public var provider: ActionProvider?
                public func run(_ invocation: ActionInvocation) -> ActionOutcome {
                    let summary: ActionSummary? = provider?.describe(invocation)
                    guard summary?.blastRadius == BlastRadius.readOnly else { return .notInvoked }
                    return .notInvoked
                }
            }
            """
        XCTAssertEqual(
            Self.familyIdentifiers("ActionProvider", inSource: source), ["ActionProvider"],
            "the detector must find the planted seam type")
        XCTAssertEqual(
            Self.familyIdentifiers("ActionInvocation", inSource: source), ["ActionInvocation"],
            "the detector must find the planted vocabulary type")
        XCTAssertEqual(
            Self.familyIdentifiers("BlastRadius", inSource: source), ["BlastRadius"],
            "the detector must find the planted radius — the gate's one branch point")
    }

    /// Family A's negative control for the shipped default — a second file branching on
    /// `NullActionProvider` is a decision CI cannot see.
    func testTheLintDetectsAPlantedNullActionProviderUse() {
        let source = """
            public struct Leak {
                public let provider = NullActionProvider()
                public func isTheDefault(_ other: some ActionProvider) -> Bool {
                    other is NullActionProvider
                }
            }
            """
        XCTAssertEqual(
            Self.familyIdentifiers("NullActionProvider", inSource: source),
            ["NullActionProvider", "NullActionProvider"],
            "the detector must find every planted use — the construction and the decision point")
        XCTAssertEqual(
            Self.familyIdentifiers("ActionProvider", inSource: source), ["ActionProvider"],
            "the word-prefix rule must count NullActionProvider separately from ActionProvider")
    }

    /// Family B's negative control, and the one this aspect turns on: the forging test that the
    /// `internal` initializer cannot stop.
    ///
    /// This is exactly the file `ActionConfirmation.swift`'s doc comment describes — a test that
    /// adds `@testable import VoccaCore` and mints a token, which **compiles**. The detector must
    /// find it in both spellings, or the guard is words.
    func testTheLintDetectsAPlantedConfirmationForgeryInATest() {
        let source = """
            @testable import VoccaCore
            import XCTest

            final class ForgingTests: XCTestCase {
                func testBypassesTheGate() {
                    let forged = \(Self.constructionMarker))
                    let alsoForged = \(Self.initConstructionMarker))
                    _ = NullActionProvider().invoke(invocation, confirmation: forged)
                    _ = alsoForged
                }
            }
            """
        XCTAssertEqual(
            Self.confirmationConstructions(inSource: source),
            [Self.constructionMarker, Self.initConstructionMarker],
            "the detector must find both spellings of a forged token")
    }

    // MARK: - Comment-strip controls

    /// A doc comment may name the families — the scanner strips comments, which is what lets the
    /// seam's documentation explain what it confines without tripping the lint that confines it.
    func testADocCommentNamingTheActionFamiliesDoesNotTripTheLint() {
        let source = """
            /// The seven files in `Sources/VoccaCore/Actions` permitted to name ActionProvider,
            /// ActionInvocation, ActionSummary, ActionOutcome, ActionConfirmation, BlastRadius and
            /// NullActionProvider — the seam holds the slot, and everything decided about acting
            /// lives above it.
            /* A block comment naming BlastRadius and ActionOutcome must not trip it either. */
            import VoccaCore
            """
        for family in Self.families {
            XCTAssertTrue(
                Self.familyIdentifiers(family.name, inSource: source).isEmpty,
                "comments must be stripped before the scan — \(family.name) was seen in one")
        }
    }

    /// The forgery guard's comment-strip control: documentation may spell out the construction it
    /// forbids, including the `@testable` import that makes it possible.
    ///
    /// This is not hypothetical — it is a paraphrase of what
    /// `Sources/VoccaCore/Actions/ActionConfirmation.swift` actually says, which is why the
    /// comment strip is load-bearing here rather than a nicety. See
    /// ``testTheShippedTokenFileIsReadAsCodeNotAsItsDocComment`` for the same claim made against
    /// the real bytes.
    func testADocCommentDescribingTheForgeryGuardDoesNotTripIt() {
        let source = """
            /// A test that wrote `@testable import VoccaCore` could call \(Self.constructionMarker))
            /// or \(Self.initConstructionMarker)) and mint a token, which is what the family lint
            /// refuses across `Sources/` and `Tests/` alike.
            import VoccaCore
            """
        XCTAssertTrue(
            Self.confirmationConstructions(inSource: source).isEmpty,
            "comments must be stripped before the construction scan")
        XCTAssertEqual(
            Self.familyIdentifiers("ActionConfirmation", inSource: source), [],
            "comments must be stripped before the family scan")
    }

    /// The comment strip, exercised against the real shipped file rather than a sample.
    ///
    /// `ActionConfirmation.swift`'s doc comment contains the literal phrase
    /// `@testable import VoccaCore` and names ``ActionProvider`` and the token itself repeatedly
    /// while explaining why the initializer is `internal`. Read as text, that file would look like
    /// several offences at once; read as code, it is one declaration and no construction. The
    /// phrase's presence is asserted first, because a control that no longer watches anything is
    /// worse than no control.
    func testTheShippedTokenFileIsReadAsCodeNotAsItsDocComment() throws {
        let url = try packageRoot().appendingPathComponent(Self.confirmationDeclarationFile)
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            source.contains("@testable import VoccaCore"),
            "the shipped doc comment must still carry the phrase this control exists to survive — "
                + "if it was removed, this test is watching nothing")
        XCTAssertTrue(
            source.contains("ActionProvider"),
            "the shipped doc comment must still name ActionProvider in prose")

        let code = SwiftSourceScanner.stripComments(from: source)
        XCTAssertFalse(
            code.contains("@testable"),
            "the phrase lives in a comment and must not survive the strip")
        XCTAssertEqual(
            Self.familyIdentifiers("ActionProvider", inSource: source), [],
            "the prose mentions of ActionProvider must not be sightings — the file is not "
                + "permitted to name that family")
        XCTAssertEqual(
            Self.familyIdentifiers("ActionConfirmation", inSource: source),
            ["ActionConfirmation"],
            "exactly one sighting must survive: the declaration itself")
        XCTAssertEqual(
            Self.confirmationConstructions(inSource: source), [],
            "the declaring file declares the token; it does not construct one")
    }

    // MARK: - Vacuity guard

    /// Scanning nothing must **fail**, not pass.
    ///
    /// Every leg above is a statement about files that were read. A scan root that has moved, been
    /// renamed, or holds no Swift files would satisfy "no file names the family" perfectly, and
    /// that is the single most likely way this suite quietly stops enforcing anything.
    func testScanningNoSwiftFilesIsAFailureNotAPass() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-action-seam-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertThrowsError(try sightings(of: "ActionProvider", under: empty)) { error in
            guard case ActionSeamTestError.noSwiftFilesScanned = error else {
                return XCTFail("scanning an empty tree must report that nothing was scanned")
            }
        }

        let missing = empty.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertThrowsError(try sightings(of: "ActionProvider", under: missing)) { error in
            guard case ActionSeamTestError.noSwiftFilesScanned = error else {
                return XCTFail("scanning a missing tree must report that nothing was scanned")
            }
        }
    }
}
