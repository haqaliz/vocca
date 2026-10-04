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

import CryptoKit
import Foundation
import XCTest

/// **The reply-text-rendering invariant suite** (`agent-pins` spec acceptances 1-5): the
/// composed default's promises, the lint tables and the digests re-asserted — deliberately, as
/// tests — with the reply carrier (`ConverseLoopDriver.converseReplySink`), the bounded state
/// (`WidgetStateStore.presentReply(_:)`, `WidgetReducerState.replyText`), the copy decision
/// (`WidgetCopy.shouldShowReplyBubble(_:)`) and the bubble (`WidgetView`'s CONVERSING branch)
/// in the tree.
///
/// ## What each leg is
///
/// This aspect is the invariant half: it asserts the *non-change*. The suite ships **no new
/// probe drive** (the post-condition is unchanged) and **modifies nothing** — if a pin fails,
/// the aspect that moved the thing it pins fixes it, never this file.
///
/// - Acceptance 1 runs the **real probe** in `defaultConfiguration` mode under the interposer
///   (the `ZeroNetworkTests` drive shape) and asserts the `PROBE-CODING-AGENT` line is
///   verbatim-unchanged — `agents=0 spawnsSubprocess=false` and the whole seeded round trip
///   still reported exactly as `ZeroNetworkTests.expectedCodingAgentLifecycle` pins it. The
///   reply path is a value folded through an existing wiring — the driver's sink, the store's
///   reducer, the view's render — so the composed default's facts are what they were.
/// - Acceptance 2 re-asserts the lint tables' **current state** — the transport permitted set
///   is still exactly the two reviewed entries, the FileManager seam table still names exactly
///   the eight seams, Family A's seven families and Family B's single minting file are
///   unchanged, the `policy:` parameter still has no default with every one of its 96 call
///   sites supplying one, the `ConversePhase` family is still confined to `WidgetProjection.swift`
///   in `VoccaCore`, and the M4a no-remember scans still run over the unit's own files. The
///   scans themselves are the lint suites' own tests (`ActionTransportProhibitionTests`,
///   `InjectionSeamBoundaryTests`, `ActionSeamBoundaryTests`, `WidgetConverseSeamBoundaryTests`,
///   `WidgetConfirmationStateTests`, `ActionsTabTests`), which run in this same full-suite run;
///   this leg pins the state they enforce so a change to either side fails here first, in review.
/// - Acceptance 3 recomputes the three G5 digests and asserts the dictation pair is unchanged
///   and `AppBootstrap.swift` holds the reply-wiring REFACTOR's re-anchored literal
///   (`4e50ab8d…` → `bc2ce1fd…`, computed with `shasum -a 256`, never edited-to-match) — and
///   that **every existing pin site carries the same literal**: the `reply-text-rendering`
///   wiring unit changed the composition root, so this suite's across-the-sites leg reads the
///   literal back out of the six sibling pin sites, and a site that drifted to a different
///   value fails here rather than silently.
/// - Acceptance 4 is the **module-coverage cross-check** read again: the exercised-module set
///   (the probe's `PROBE-MODULES` line) must equal the set the cross-check derives from the
///   manifest and the `Sources/` listing — the same twelve library modules. The unit added no
///   module files: its changes ride `VoccaUI` (the reducer, store, copy and view),
///   `VoccaBootstrap` (the driver, the wiring and the composition root) and the already-covered
///   `VoccaCore` reply seam, so the derived set is unchanged and this leg proves it.
/// - Acceptance 5 runs the zero-network default-configuration drive with the reply path
///   composed and asserts the interposer saw nothing: the reply text is a `String` folded
///   through the existing driver → store → reducer → view path, no new call exists for it to
///   make, and the composed default never reaches the carrier (the converse session is not
///   running).
///
/// ## What is honest about a pins suite
///
/// The tree is expected to be green on every leg the day this lands: the composed default did
/// not move, the lints did not widen, the digests did not change. A green run here is the
/// result, not a failure to be manufactured — the value is that a *future* edit to any of the
/// pinned things now fails in review with a named leg.
final class ReplyRenderingInvariantTests: XCTestCase {

    // MARK: - Acceptance 1: the PROBE-CODING-AGENT line is verbatim-unchanged

    /// The `ZeroNetworkTests.expectedCodingAgentLifecycle` literal, mirrored here because that
    /// constant is file-private. This mirror is the point, not a weakness: if the probe's line
    /// ever changes, the zero-network suite's own constant and this literal must both move in
    /// review — a change to one side alone fails here.
    private static let expectedCodingAgentLifecycle =
        "store=real store.location=temporary store.isDefaultLocation=false agents=0 "
        + "spawnsSubprocess=false seeded=1 card=yes invoked=1 "
        + "decisions=refused,confirmed,dryRun ordinals=1-3 binding=matched"

    /// Raised when the probe's report cannot be parsed meaningfully, so that reading nothing is
    /// a failure rather than a pass.
    private enum ProbeReportError: Error, CustomStringConvertible {
        case lineNotParseable(String)
        case repeatedField(String)
        case missingField(String, present: [String])

        var description: String {
            switch self {
            case .lineNotParseable(let fragment):
                return "the report line is not a sequence of `key=value` fields: '\(fragment)'"
            case .repeatedField(let key):
                return "the report line names '\(key)' twice — one of the two would be dropped"
            case .missingField(let key, let present):
                return "the report line no longer reports '\(key)'. Present: "
                    + present.joined(separator: ", ")
            }
        }
    }

    /// Raised when a pin file's literal cannot be extracted, so that a failed extraction is a
    /// failure rather than an empty table read as compliance.
    private enum PinFileError: Error, CustomStringConvertible {
        case markerMissing(marker: String, file: String)
        case openingBracketMissing(marker: String, file: String)
        case unbalancedBrackets(marker: String, file: String)
        case appBootstrapDigestMissing(file: String)
        case seamRootMissing(file: String)

        var description: String {
            switch self {
            case .markerMissing(let marker, let file):
                return "\(file) no longer declares '\(marker)' — the pin reads the literal "
                    + "this marker names; a renamed constant is a reviewed edit, never a "
                    + "silent rename"
            case .openingBracketMissing(let marker, let file):
                return "\(file) declares '\(marker)' without a bracket literal — the pin "
                    + "cannot read a table that is not spelled as one"
            case .unbalancedBrackets(let marker, let file):
                return "\(file)'s '\(marker)' literal does not balance within the file — a "
                    + "truncated table read as compliant is the one way this pin could lie"
            case .appBootstrapDigestMissing(let file):
                return "\(file) no longer pairs 'Sources/VoccaBootstrap/AppBootstrap.swift' "
                    + "with a 64-hex digest literal — the across-the-sites leg cannot read a "
                    + "site that stopped spelling its pin as a tuple"
            case .seamRootMissing(let file):
                return "\(file) no longer spells its `seamModuleRoot` as a string literal — "
                    + "the ConversePhase pin cannot read a scan root that is not named"
            }
        }
    }

    /// **Acceptance 1 — the PROBE-CODING-AGENT line is verbatim-unchanged with the unit's
    /// files in the tree.** Runs the real probe under the interposer (the
    /// `ZeroNetworkTests` drive shape — same three preconditions, same accessor), compares the
    /// whole line against the pinned literal, and reads the two composed-default facts back
    /// field by field: `agents=0` (an absent registry is the empty registry) and
    /// `spawnsSubprocess=false` (the D2 narrowed promise, declared for the configuration).
    ///
    /// The reply path rides the composed root's existing wiring: the carrier's sink is a
    /// closure in `composeConverseWiring`, the store's `presentReply(_:)` is the
    /// `presentPartial(_:)` shape, and the bubble is a view branch. Nothing in that path can
    /// reach the network or a child, and the default-configuration drive never starts a
    /// converse session — the line must read exactly as it did.
    func testTheProbeCodingAgentLineIsVerbatimUnchangedWithTheUnitInTheTree() throws {
        let observation = try runProbe(mode: .defaultConfiguration)

        let payload = try XCTUnwrap(
            agentPayload(of: observation),
            """
            The probe did not report the PROBE-CODING-AGENT line at all. Either \
            VoccaNetworkProbe.exerciseCodingAgent() was deleted from the default-configuration \
            path — which puts the agent composition's round trip outside the zero-network \
            invariant — or the drive never ran. Do not fix this by deleting the assertion; the \
            line must stay, verbatim.
            \(observation.diagnosticSummary)
            """)
        XCTAssertEqual(
            payload, Self.expectedCodingAgentLifecycle,
            """
            The PROBE-CODING-AGENT line is no longer verbatim-unchanged.
              expected: \(Self.expectedCodingAgentLifecycle)
              observed: \(payload)
            The composed default's promises must not move with the reply carrier, the bounded \
            state and the bubble in the tree — if the drive's report changed deliberately, \
            re-anchor this literal and ZeroNetworkTests' own constant in the same reviewed \
            edit, never edited-to-match.
            """)

        let fields = try parseFields(of: payload)
        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ProbeReportError.missingField(key, present: fields.keys.sorted())
            }
            return found
        }
        XCTAssertEqual(
            try value("agents"), "0",
            "the composed default still reads zero agents — an absent coding-agents.json is "
                + "the empty registry, and the D2 promise ('no child by default') is intact")
        XCTAssertEqual(
            try value("spawnsSubprocess"), "false",
            "the composed default still declares it spawns no child — the wiring's declared "
                + "fact, folded into the probe line, not commented")
    }

    // MARK: - Acceptance 2: the lint immobilities

    /// **Acceptance 2a — the transport permitted set is still exactly the two reviewed
    /// entries.** The `ActionTransportProhibitionTests` table, read as the **current state of
    /// the pin file itself**: the set literal is extracted from the suite's source and must
    /// hold exactly the stdio transport and the shell executor, nothing else. The scan itself
    /// is that suite's own test; this leg pins the state it enforces — a third entry, a
    /// retyped path or a renamed constant is now a reviewed edit that fails here first.
    func testTheTransportPermittedSetStillNamesExactlyTheTwoReviewedEntries() throws {
        let source = try pinFileSource("ActionTransportProhibitionTests.swift")
        let body = try bracketBody(
            of: source, after: "filesPermittedToNameATransport",
            file: "ActionTransportProhibitionTests.swift")
        let entries = Set(quotedStrings(in: body))
        XCTAssertEqual(
            entries,
            [
                "VoccaActions/MCP/StdioMCPTransport.swift",
                "VoccaActions/Execution/ShellExecutor.swift",
            ],
            """
            the transport prohibition's permitted set must be exactly the two reviewed entries \
            — the stdio transport and the shell executor. The reply-text-rendering changes ride \
            VoccaUI and VoccaBootstrap (a reducer field, a store entry point, a view branch, a \
            wiring closure) — none of them spawns, so nothing for this lint to see; a third \
            entry means a spawn moved somewhere this lint (and this pin) must name in review, \
            with the D2 answer the entry owes. Read off the pin file's own literal: \(body).
            """)
    }

    /// **Acceptance 2b — the FileManager seam table still names exactly the eight seams.**
    /// The `InjectionSeamBoundaryTests` table, read as the current state of the pin file
    /// itself: the dictionary literal's keys must be exactly the eight shipped seams. The
    /// per-module scans are that suite's own tests; this leg pins the exact set — a ninth
    /// seam, a renamed seam or a row that moved without its seam fails here first.
    func testTheFileManagerSeamTableStillNamesExactlyTheEightSeams() throws {
        let source = try pinFileSource("InjectionSeamBoundaryTests.swift")
        let body = try bracketBody(
            of: source, after: "filesPermittedToNameFileManagerIdentifiersBySeam",
            file: "InjectionSeamBoundaryTests.swift")
        let keys = Set(dictionaryKeys(in: body))
        XCTAssertEqual(
            keys,
            [
                "journal", "dictionary", "config", "strategy", "usage", "consent", "actions",
                "action-config",
            ],
            """
            the FileManager seam table must name exactly the eight shipped seams: journal, \
            dictionary, config, strategy, usage, consent, actions, action-config. The \
            reply-text-rendering changes name no file system at all — the carrier is a closure \
            on the driver, the state is a `String?` on the reducer, the bubble is a view — so a \
            ninth seam would be a widening, never a silent addition. Read off the pin file's \
            own literal: \(body).
            """)
    }

    /// **Acceptance 2c — Family A's seven families and Family B's single minting file are
    /// unchanged.** The `ActionSeamBoundaryTests` tables, read as the current state of the
    /// pin file itself: the families table's `name:` entries must be exactly the seven action
    /// families and the forgery guard's permitted set must hold exactly the one gate file
    /// under `Sources/` (never a `Tests/` file). The scans are that suite's own tests; this
    /// leg pins the state.
    func testTheActionFamiliesAndForgeryGuardAreUnchanged() throws {
        let seamSource = try pinFileSource("ActionSeamBoundaryTests.swift")

        let familiesBody = try bracketBody(
            of: seamSource, after: "families: [(name: String, permitted: Set<String>)]",
            file: "ActionSeamBoundaryTests.swift")
        let familyNames = Set(familyNameValues(in: familiesBody))
        XCTAssertEqual(
            familyNames,
            [
                "ActionProvider", "ActionInvocation", "ActionSummary", "ActionOutcome",
                "ActionConfirmation", "BlastRadius", "NullActionProvider",
            ],
            """
            Family A must confine exactly the seven action families. The reply-text-rendering \
            files decide nothing over the action vocabulary (the reply path reaches no \
            provider, no invocation and no gate — it is a text folded from the driver's sink \
            to the widget) — a new family or a renamed one is a reviewed widening, never a \
            silent addition. Read off the pin file's own literal: \(familiesBody).
            """)

        let constructionBody = try bracketBody(
            of: seamSource, after: "filesPermittedToConstructAConfirmation",
            file: "ActionSeamBoundaryTests.swift")
        let mintingFiles = Set(quotedStrings(in: constructionBody))
        XCTAssertEqual(
            mintingFiles,
            ["Sources/VoccaCore/Actions/ActionGate.swift"],
            """
            Family B must still permit exactly the one confirmation-minting file: the gate. A \
            second minting site is a second place that decides an action may act, and the \
            structural refusal is only structural while there is a single door. Read off the \
            pin file's own literal: \(constructionBody).
            """)
    }

    /// **Acceptance 2d — the `policy:` parameter still has no default, and the 96 call sites
    /// that submit to the gate are unchanged: every one of them supplies the argument.** The
    /// `ActionSeamBoundaryTests` scan shape, read as the current state of the tree itself:
    /// the gate's declaration spells `policy: ActionRadiusPolicy` with no `=` default (the F2
    /// fail-open default stays removed), and every `ActionGate.submit(` call under
    /// `Sources/` and `Tests/` — counted, exactly 96 — still names `policy:` explicitly. The
    /// scan itself is that suite's own test; this leg pins the count so a call site added
    /// without the argument — or a silent removal of the argument at a site — fails here
    /// first, in review. The reply unit submits nothing: it adds no call site.
    func testThePolicyParameterStillHasNoDefaultAndTheCallSitesAreUnchanged() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let gate = try String(
            contentsOf: root.appendingPathComponent("Sources/VoccaCore/Actions/ActionGate.swift"),
            encoding: .utf8)
        let declaration = SwiftSourceScanner.stripComments(from: gate)
        XCTAssertTrue(
            declaration.contains("policy: ActionRadiusPolicy"),
            "the gate must still spell the policy parameter this way, or this pin watches "
                + "nothing")
        XCTAssertNil(
            declaration.range(
                of: "policy:\\s*ActionRadiusPolicy\\s*=", options: .regularExpression),
            """
            the policy parameter has regained a default — the one argument whose default \
            would GRANT rather than withhold. It was removed because a caller who forgot to \
            ask was not asking; pass `.none` explicitly where trusting the provider is what \
            you mean.
            """)

        var scannedCalls = 0
        var offenders: [String] = []
        for scanRoot in [root.appendingPathComponent("Sources"), root.appendingPathComponent("Tests")]
        {
            let files = SwiftSourceScanner.swiftFiles(under: scanRoot)
            guard !files.isEmpty else {
                throw ProbeReportError.lineNotParseable(
                    "no Swift files under \(scanRoot.path) — the call-site scan is vacuous")
            }
            for file in files {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                let source = try String(contentsOf: file, encoding: .utf8)
                for call in Self.submitCalls(inSource: source) {
                    scannedCalls += 1
                    guard let call else {
                        offenders.append("\(relative): a call did not balance within the scan")
                        continue
                    }
                    guard !call.contains("policy:") else { continue }
                    offenders.append("\(relative): \(call.split(separator: "\n").first ?? "").")
                }
            }
        }

        XCTAssertGreaterThan(
            scannedCalls, 10,
            "vacuity guard: the scan must have found real call sites — a scan that found none "
                + "would report every call compliant forever")
        XCTAssertEqual(
            scannedCalls, 96,
            """
            the gate's call sites are no longer 96 — the count moved to \(scannedCalls). A \
            new submit site (or a removed one) is a reviewed edit; the reply-text-rendering \
            changes added none (the reply path reaches no gate — the widget's card rows are \
            untouched and the carrier folds text, never an invocation). This pin and \
            ActionSeamBoundaryTests' own scan must move together in review.
            """)
        XCTAssertTrue(
            offenders.isEmpty,
            """
            these call sites submit to the gate without naming a local radius policy: \
            \(offenders.sorted()).
            Supply one. `.none` is a legitimate answer and means the provider's claim stands \
            unraised; what is not legitimate is arriving at it by omission.
            """)
    }

    /// **Acceptance 2e — the `ConversePhase` family is still confined to
    /// `WidgetProjection.swift`.** The `WidgetConverseSeamBoundaryTests` table, read as the
    /// current state of the pin file itself — the module root and the permitted set must be
    /// exactly `VoccaCore` and `WidgetProjection.swift` — and then the confinement itself is
    /// re-run over the real tree: no other file under `Sources/VoccaCore` may name the family
    /// (the scan is the `WidgetConverseSeamBoundaryTests.familyIdentifiers` shape). The unit
    /// renders the phase in `VoccaUI` (`WidgetCopy.converseLabel(_:)`, the view), which is
    /// outside the lint's scan root by design; inside `VoccaCore` the phase vocabulary stays
    /// in one file. The lint suite's own test runs in this same full-suite run; this leg pins
    /// the state and re-asserts the claim with the bubble in the tree.
    func testTheConversePhaseFamilyIsStillConfinedToWidgetProjection() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let lintSource = try pinFileSource("WidgetConverseSeamBoundaryTests.swift")

        let rootLiteral = try stringLiteral(
            after: "seamModuleRoot", in: lintSource,
            file: "WidgetConverseSeamBoundaryTests.swift")
        XCTAssertEqual(
            rootLiteral, "VoccaCore",
            "the ConversePhase lint's scan root must still be VoccaCore — a moved root means "
                + "the confinement this pin re-asserts is aimed at the wrong module")

        let permittedBody = try bracketBody(
            of: lintSource, after: "filesPermittedToNameTheFamily",
            file: "WidgetConverseSeamBoundaryTests.swift")
        let permitted = Set(quotedStrings(in: permittedBody))
        XCTAssertEqual(
            permitted,
            ["WidgetProjection.swift"],
            """
            exactly one file in VoccaCore may name the ConversePhase family, and it is \
            WidgetProjection.swift — the declaration, the WidgetState.conversing case that \
            names it and the project(turnState:) leg all live there. The reply bubble renders \
            the phase in VoccaUI, outside this scan root; a second file inside VoccaCore is a \
            phase decision that moved somewhere CI cannot see. Read off the pin file's own \
            literal: \(permittedBody).
            """)

        // The confinement itself, re-run against the real tree.
        let moduleRoot = root.appendingPathComponent("Sources/\(rootLiteral)")
        let files = SwiftSourceScanner.swiftFiles(under: moduleRoot)
        XCTAssertFalse(
            files.isEmpty,
            "no Swift files under \(moduleRoot.path) — the confinement was not evaluated "
                + "against anything")
        var naming: Set<String> = []
        for file in files {
            let relative = String(file.path.dropFirst(moduleRoot.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            if !Self.conversePhaseIdentifiers(inSource: source).isEmpty {
                naming.insert(relative)
            }
        }
        XCTAssertEqual(
            naming, permitted,
            """
            the ConversePhase family is no longer confined to the permitted file in \
            \(rootLiteral): named by \(naming.sorted()). With the reply bubble in the tree the \
            phase is rendered from VoccaUI, but no file inside \(rootLiteral) beyond the \
            permitted one may name the family — a second sighting is a converse-state decision \
            outside the lint's reach. Do not fix this by widening the lint's permitted set \
            without the reviewed decision that widening owes.
            """)
        XCTAssertFalse(
            naming.isEmpty,
            "the permitted file must actually name the family — a scan that found nothing "
                + "would pass 'no other file names it' vacuously")
    }

    /// **Acceptance 2f — the M4a no-remember scans are still green with the unit's reply copy
    /// and reducer row in the tree.** The three scans are `WidgetConfirmationStateTests`'s two
    /// (the reducer/type rows and the copy pin) and `ActionsTabTests`' one (the actions
    /// folder). This leg reads each scan's forbidden-phrase table back out of the pin file's
    /// own source (the non-vacuous extractor pattern — a phrase silently dropped from a lint
    /// suite fails here), then re-runs the scans over the shipped files: the reply state
    /// (`WidgetReducerState.replyText`) and the reply copy
    /// (`WidgetCopy.shouldShowReplyBubble(_:)`/`replyBubbleLabel(_:)`) must carry no
    /// "remember"/"ask again" affordance. The non-vacuity rows prove the scans actually cover
    /// the unit's files.
    func testTheM4aNoRememberScansAreStillGreen() throws {
        let root = try PackageRootLocator.find(from: #filePath)

        // The pin files' own phrase tables, read back.
        let widgetLint = try pinFileSource("WidgetConfirmationStateTests.swift")
        let widgetPhrases = try phraseLists(
            in: widgetLint, loopVariable: "forbidden",
            file: "WidgetConfirmationStateTests.swift")
        XCTAssertEqual(
            widgetPhrases,
            ["askagain", "dontask", "remember", "don't ask", "don’t ask", "ask again"],
            """
            the widget M4a scans' forbidden-phrase tables moved. They are the whole strength \
            of those scans — a table that quietly shrank passes every file. Read off the pin \
            file's own literals: \(widgetPhrases.sorted()).
            """)

        let actionsLint = try pinFileSource("ActionsTabTests.swift")
        let actionsPhrases = try phraseLists(
            in: actionsLint, loopVariable: "phrase", file: "ActionsTabTests.swift")
        XCTAssertEqual(
            actionsPhrases,
            [
                "ask again", "don't ask", "always allow", "remember my choice",
                "don't show this again",
            ],
            """
            the actions-folder M4a scan's forbidden-phrase table moved — a confirmation that \
            can be switched off is a confirmation that quietly stops being asked, and this \
            table is what refuses the tab's words from selling that. Read off the pin file's \
            own literal: \(actionsPhrases.sorted()).
            """)

        // The scans, re-run over the shipped files — with the reply rows in the tree.
        for relativePath in [
            "Sources/VoccaUI/WidgetStateReducer.swift",
            "Sources/VoccaUI/WidgetConfirmationState.swift",
        ] {
            let stripped = SwiftSourceScanner.stripComments(
                from: try String(
                    contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8))
            let lower = stripped.lowercased()
            for forbidden in widgetPhrases {
                XCTAssertFalse(
                    lower.contains(forbidden),
                    "\(relativePath) must carry no \(forbidden) affordance row (M4a)")
            }
        }

        let copySource = try String(
            contentsOf: root.appendingPathComponent("Sources/VoccaUI/WidgetCopy.swift"),
            encoding: .utf8)
        let copyStripped = SwiftSourceScanner.stripComments(from: copySource)
        let copyLower = copyStripped.lowercased()
        for forbidden in widgetPhrases {
            XCTAssertFalse(
                copyLower.contains(forbidden),
                "WidgetCopy must contain no '\(forbidden)' string (M4a)")
        }

        let actionsFolder = root.appendingPathComponent("Sources/VoccaUI/Actions")
        let actionFiles = SwiftSourceScanner.swiftFiles(under: actionsFolder)
        XCTAssertFalse(actionFiles.isEmpty, "the actions-folder scan ran against nothing")
        for file in actionFiles {
            let text = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            for phrase in actionsPhrases {
                XCTAssertFalse(
                    text.contains(phrase),
                    "\(file.lastPathComponent) carries '\(phrase)' — M4a: a confirmation is "
                        + "never skippable, so no sentence may offer to skip it")
            }
        }

        // Non-vacuity: the scans must actually cover the unit's reply rows — the reducer's
        // field and the copy's predicate and label. A rename would take the new surface out
        // of the scans silently.
        let reducer = try String(
            contentsOf: root.appendingPathComponent("Sources/VoccaUI/WidgetStateReducer.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            reducer.contains("confirmation"),
            "the scan must find the card's reducer row — a rename would make this vacuous")
        XCTAssertTrue(
            reducer.contains("replyText"),
            "the reducer's reply row must exist under the scans — the M4a scan must cover the "
                + "unit's new state, not just the pre-existing card")
        XCTAssertTrue(
            copyStripped.contains("Confirm"),
            "the scan must find the card's pinned rows — a rename would make this vacuous")
        XCTAssertTrue(
            copyStripped.contains("shouldShowReplyBubble") && copyStripped.contains("replyBubbleLabel"),
            "the copy's reply rows must exist under the scan — the M4a copy pin must cover "
                + "the unit's new strings, not just the card's")
    }

    // MARK: - Acceptance 3: the G5 digests

    /// **Acceptance 3 — the dictation digests are unchanged, `AppBootstrap.swift` holds the
    /// reply-wiring REFACTOR's re-anchored literal, and every existing pin site carries the
    /// same literal.** SHA-256 (CryptoKit, the house pattern) of the three files, asserted
    /// against the same literals `TurnTakingComposedAcceptanceTests.testTheDictationPathIsByteForByteUntouched`,
    /// `AgentPresetsInvariantTests`, `SpokenTaskInvariantTests`, `ActiveProjectInvariantTests`,
    /// `WiringBaselineTests` and `AuthBaselineInvariantTests` pin — the pin read again,
    /// deliberately, with the reply carrier, the bounded state and the bubble in the tree.
    /// The two dictation files are byte-for-byte untouched; the composition root carries the
    /// re-anchor `4e50ab8d…` → `bc2ce1fd…` (computed with `shasum -a 256` on 2026-10-03 by the
    /// `reply-text-rendering` wiring REFACTOR, never edited-to-match), and the across-the-sites
    /// leg reads the AppBootstrap literal back out of all six pin sites — a site that drifted
    /// to a different value fails here rather than silently.
    ///
    /// Re-anchored once more, deliberately, on 2026-10-04 by `composite-intent-resolver`
    /// (`bc2ce1fd…` → `d46fd928…` → `a0dae00b…` — two re-anchors in one unit, the second
    /// when the keyword leg's exclusion widened to the coding-agent provider; each computed
    /// with `shasum -a 256` after the unit's last
    /// composition-root edit, never edited-to-match): the composition root composes the
    /// per-turn resolver provider over the `keywordFallback` switch. The two dictation
    /// digests are unchanged.
    func testTheDictationDigestsAreUnchangedAndEveryPinSiteCarriesTheReanchoredLiteral() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let pinned: [(file: String, digest: String)] = [
            (
                "Sources/VoccaCore/SessionMachine.swift",
                "1baeb2de2c45149746468bfef49862a08279008d3d2f305be892122d5727537e"
            ),
            (
                "Sources/VoccaCore/DictationPipeline.swift",
                "ce70ca10c15914d6960f07e53da8571a5fa9ec1fb58b8f0051ef051f16c07a84"
            ),
            (
                "Sources/VoccaBootstrap/AppBootstrap.swift",
                "a0dae00bf635ad9a6abd3ed45b5f019fc2c286a8636cf76beccb145d4420a9d7"
            ),
        ]
        XCTAssertFalse(pinned.isEmpty, "vacuity guard: the pin must name the files it pins")
        for (file, expected) in pinned {
            let data = try Data(contentsOf: root.appendingPathComponent(file))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(
                actual, expected,
                """
                \(file) changed byte-for-byte since the barge-in-loop aspect pinned it. The \
                dictation path must stay untouched by the reply-text-rendering unit; if the \
                change is a deliberate edit, recompute the digest and re-anchor the pin in \
                review — it must never be edited to match a moved tree.
                """)
        }

        // The across-the-sites leg: every existing pin site must carry the same AppBootstrap
        // literal this suite asserts — the composition root changed under the wiring REFACTOR,
        // and each site was re-anchored in that same reviewed edit. A site carrying a
        // different value means the re-anchor missed it.
        let appBootstrapDigest = pinned[2].digest
        for site in [
            "TurnTakingComposedAcceptanceTests.swift",
            "AgentPresetsInvariantTests.swift",
            "SpokenTaskInvariantTests.swift",
            "ActiveProjectInvariantTests.swift",
            "WiringBaselineTests.swift",
            "AuthBaselineInvariantTests.swift",
        ] {
            let extracted = try appBootstrapDigestLiteral(in: try pinFileSource(site), file: site)
            XCTAssertEqual(
                extracted, appBootstrapDigest,
                """
                \(site) pins a different AppBootstrap digest than the tree holds. All six \
                sites were re-anchored together by the wiring REFACTOR (\(appBootstrapDigest)); \
                a drifted site hides a drift in the composition root from half the pins. \
                Re-anchor it to the same reviewed literal — never edited-to-match.
                """)
        }
    }

    // MARK: - Acceptance 4: the module-coverage cross-check

    /// **Acceptance 4 — the module-coverage cross-check is green with the unit in the tree: no
    /// new module files.** The cross-check
    /// (`ZeroNetworkTests.testDefaultConfigurationMakesZeroNetworkConnections`'s final
    /// assertion) derives the required set from the manifest and the `Sources/` listing —
    /// every module directory ∪ every drivable target, minus the non-drivable kinds, minus
    /// only the exclusions the manifest justifies (`VoccaNetworkProbe`,
    /// `CVoccaNetworkInterposer` — each re-asserted to exist and not to ship). This leg
    /// recomputes that set the same way, pins it to the same twelve library modules (the set
    /// is unchanged — the unit added no module files, only edits inside covered modules: the
    /// reply state in `VoccaUI`, the carrier and wiring in `VoccaBootstrap`), and re-asserts
    /// the cross-check's own equality against what the probe actually reported driving.
    func testTheModuleCoverageCrossCheckStillCoversEveryModuleWithNoNewModuleFiles() throws {
        let observation = try runProbe(mode: .defaultConfiguration)
        let root = try PackageRootLocator.find(from: #filePath)
        let manifest = try PackageManifest.load(packageRoot: root)

        let candidates = try sourceDirectories().union(manifest.drivableTargetNames)
        let exclusions: Set<String> = ["VoccaNetworkProbe", "CVoccaNetworkInterposer"]
        for exclusion in exclusions.sorted() {
            XCTAssertNotNil(
                manifest.targets[exclusion],
                "coverage exclusion '\(exclusion)' is not a target in this package — a stale "
                    + "name here excludes nothing")
            XCTAssertFalse(
                manifest.shippingTargets.contains(exclusion),
                """
                coverage exclusion '\(exclusion)' is no longer justified: the manifest says it \
                is reachable from a product this package ships, so the probe must drive it. \
                Drive it from VoccaNetworkProbe.exerciseDefaultConfiguration() instead of \
                excluding it.
                """)
        }
        let required =
            candidates
            .subtracting(manifest.nonDrivableTargetNames)
            .subtracting(exclusions)
        XCTAssertFalse(
            required.isEmpty,
            "the required module set is empty — the cross-check would be asserting against "
                + "nothing")

        // The module set is unchanged: exactly the twelve library modules. The unit's edits
        // all landed inside covered modules, so a new module directory under Sources/ would
        // appear here — that is the "no new module files" claim, read off the tree.
        let shippedModules: Set<String> = [
            "VoccaCore", "VoccaAudio", "VoccaHotkey", "VoccaASR", "VoccaText",
            "VoccaInject", "VoccaSpeech", "VoccaContext", "VoccaActions", "VoccaUI",
            "VoccaUsage", "VoccaBootstrap",
        ]
        XCTAssertEqual(
            shippedModules.count, 12,
            "the pinned module set must be exactly the twelve library modules — the vacuity "
                + "guard that keeps this pin watching something")
        XCTAssertEqual(
            required, shippedModules,
            """
            The module set the cross-check derives is no longer the twelve library modules. \
            Got \(required.sorted()). A module added to this package must be driven by the \
            probe's default-configuration path (a reviewed edit to VoccaNetworkProbe), never \
            excluded silently — and one removed must be removed here too. The \
            reply-text-rendering unit added no module files; a change to this set is a \
            different unit's reviewed edit.
            """)

        // The cross-check's own equality, re-asserted: what the probe reported driving is
        // exactly the required set — the cross-check test itself stays green.
        XCTAssertEqual(
            observation.reportedModules, required,
            """
            The probe's default-configuration path does not cover every module in this package.
              never driven by the probe: \(required.subtracting(observation.reportedModules).sorted())
              reported but not a module: \(observation.reportedModules.subtracting(required).sorted())
            A module the probe never reaches is a module the zero-network invariant says \
            nothing about.
            \(observation.diagnosticSummary)
            """)
    }

    // MARK: - Acceptance 5: the zero-network default configuration with the unit composed

    /// **Acceptance 5 — the zero-network default-configuration test passes with the reply
    /// path composed.** The reply text is a `String` folded through the existing driver →
    /// store → reducer → view path: the carrier's sink is a closure in
    /// `composeConverseWiring`, the store's `presentReply(_:)` folds it, the reducer bounds
    /// it and the view draws a bubble. No new call exists for it to make, and the
    /// default-configuration drive never starts a converse session. This leg drives the real
    /// probe under the interposer and asserts the same two zeroes the release blocker asserts,
    /// plus the composed root actually ran (the observed `.accessory` activation policy —
    /// `configure(_:)` was called, so the composition that carries the reply wiring is the one
    /// being watched).
    func testTheZeroNetworkDefaultConfigurationStillMakesZeroCallsWithTheReplyRenderingInTheTree()
        throws
    {
        let observation = try runProbe(mode: .defaultConfiguration)

        XCTAssertEqual(
            observation.networkConnectionCount, 0,
            """
            Vocca's default configuration must make zero network calls with the reply carrier, \
            the bounded state and the bubble in the tree. The probe contacted:
            \(observation.networkConnectionDescriptions.joined(separator: "\n"))
            The reply is a string folded through the driver's sink, the store's reducer and \
            the view — there is no call for it to make. Fix the code. Do not weaken this test.
            \(observation.diagnosticSummary)
            """)
        XCTAssertEqual(
            observation.nameResolutionCount, 0,
            """
            Vocca's default configuration must resolve no hostnames with the reply rendering \
            in the tree. The probe resolved:
            \(observation.nameResolutionDescriptions.joined(separator: "\n"))
            Fix the code. Do not weaken this test.
            \(observation.diagnosticSummary)
            """)
        XCTAssertEqual(
            observation.reportedActivationPolicy, "accessory",
            """
            The probe did not observe Vocca's start-up leaving the application in the \
            .accessory activation policy (saw: \(observation.reportedActivationPolicy ?? "no report at all")).
            Either AppBootstrap.configure(_:) was not called on the default-configuration path \
            — in which case the composition that now carries the reply wiring was never \
            exercised under the interposer — or it no longer sets the policy.
            \(observation.diagnosticSummary)
            """)
    }

    // MARK: - Fixtures and plumbing

    /// Reads one pin file's source from `Tests/HarnessTests/`, comments stripped — the
    /// "read the existing pins" leg: acceptance 2 asserts the lint tables' current state by
    /// extracting the literals from the very files whose tests enforce them.
    private func pinFileSource(_ name: String) throws -> String {
        let root = try PackageRootLocator.find(from: #filePath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Tests/HarnessTests/\(name)"),
            encoding: .utf8)
        return SwiftSourceScanner.stripComments(from: source)
    }

    /// The body of the first bracket-delimited literal at or after `marker` in `source`.
    ///
    /// Balanced over `[`/`]` with quoted strings skipped, so a `]` inside a string cannot end
    /// the literal early. Fails loudly when the marker is absent or the brackets never
    /// balance — a renamed constant in a pin file is a reviewed edit, and a failed extraction
    /// must not read as an empty table.
    private func bracketBody(of source: String, after marker: String, file: String) throws
        -> String
    {
        guard let markerRange = source.range(of: marker) else {
            throw PinFileError.markerMissing(marker: marker, file: file)
        }
        guard let equals = source[markerRange.upperBound...].firstIndex(of: "=") else {
            throw PinFileError.openingBracketMissing(marker: marker, file: file)
        }
        guard let opening = source[source.index(after: equals)...].firstIndex(of: "[") else {
            throw PinFileError.openingBracketMissing(marker: marker, file: file)
        }
        return try balancedBody(of: source, from: opening, marker: marker, file: file)
    }

    /// The body of the first `"..."` string literal after `marker` in `source`, contents
    /// without the quotes — the shape the `seamModuleRoot` constant is spelled in.
    private func stringLiteral(after marker: String, in source: String, file: String) throws
        -> String
    {
        guard let markerRange = source.range(of: marker) else {
            throw PinFileError.markerMissing(marker: marker, file: file)
        }
        guard
            let opening = source[markerRange.upperBound...].firstIndex(of: "\""),
            let closing = source[source.index(after: opening)...].firstIndex(of: "\"")
        else {
            throw PinFileError.seamRootMissing(file: file)
        }
        return String(source[source.index(after: opening)..<closing])
    }

    /// The union of the quoted phrases in every `for <loopVariable> in [ ... ]` literal of
    /// `source` — the shape the M4a scans spell their forbidden tables in. Fails loudly when
    /// no such literal exists, so a renamed loop variable cannot read as an empty table.
    private func phraseLists(in source: String, loopVariable: String, file: String) throws
        -> Set<String>
    {
        let escaped = NSRegularExpression.escapedPattern(for: loopVariable)
        let pattern = #"for\s+"# + escaped + #"\s+in\s*\[([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw PinFileError.markerMissing(marker: "for \(loopVariable) in [", file: file)
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, range: range)
        guard !matches.isEmpty else {
            throw PinFileError.markerMissing(marker: "for \(loopVariable) in [", file: file)
        }
        var phrases: Set<String> = []
        for match in matches {
            guard let bodyRange = Range(match.range(at: 1), in: source) else { continue }
            phrases.formUnion(quotedStrings(in: String(source[bodyRange])))
        }
        return phrases
    }

    /// The balanced body of the bracket at `opening` (the `bracketBody` scan, split out so a
    /// caller that has already located the opening bracket can reuse it).
    private func balancedBody(of source: String, from opening: String.Index, marker: String,
        file: String) throws -> String
    {
        let characters = Array(source)
        let start = source.distance(from: source.startIndex, to: opening) + 1
        var depth = 1
        var cursor = start
        var inString = false
        while cursor < characters.count {
            let character = characters[cursor]
            if inString {
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    return String(characters[start..<cursor])
                }
            }
            cursor += 1
        }
        throw PinFileError.unbalancedBrackets(marker: marker, file: file)
    }

    /// Every quoted string in `body`, contents without the quotes, in order.
    private func quotedStrings(in body: String) -> [String] {
        let pattern = #""([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    /// The keys of a dictionary literal — every `"key":` spelling in `body`.
    private func dictionaryKeys(in body: String) -> [String] {
        let pattern = #""([^"]+)"\s*:"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    /// The family names of the action-seam table — every `name: "X"` spelling in `body`.
    private func familyNameValues(in body: String) -> [String] {
        let pattern = #"name:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        return regex.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    /// The AppBootstrap digest a pin site's `pinned` array carries — every
    /// `"Sources/VoccaBootstrap/AppBootstrap.swift", "<64 hex>"` pairing in `source`.
    ///
    /// Each of the six sites spells its G5 pin as a `(file: String, digest: String)` tuple
    /// array; this extraction reads the AppBootstrap row's digest out of that spelling. A
    /// site that stops spelling its pin as a tuple (or drops the AppBootstrap row) fails the
    /// extraction rather than passing the across-the-sites leg vacuously.
    private func appBootstrapDigestLiteral(in source: String, file: String) throws -> String {
        let pattern = #""Sources/VoccaBootstrap/AppBootstrap\.swift",\s*"([0-9a-f]{64})""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw PinFileError.appBootstrapDigestMissing(file: file)
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard
            let match = regex.firstMatch(in: source, range: range),
            let digestRange = Range(match.range(at: 1), in: source)
        else {
            throw PinFileError.appBootstrapDigestMissing(file: file)
        }
        return String(source[digestRange])
    }

    /// Every occurrence of a `ConversePhase` family identifier in `source`, comments removed
    /// first — the `WidgetConverseSeamBoundaryTests.familyIdentifiers(inSource:)` shape,
    /// spelled locally so the confinement leg reads the tree with the same scanner the lint
    /// suite trusts.
    private static func conversePhaseIdentifiers(inSource source: String) -> [String] {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = #"\b(ConversePhase)[A-Za-z0-9_]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
        }
    }

    /// The argument text of every `ActionGate.submit(` call in `source`, comments removed
    /// first — the `ActionSeamBoundaryTests.submitCalls(inSource:)` shape, spelled locally so
    /// the call-site count leg reads the tree with the same scanner the seam suite trusts.
    private static func submitCalls(inSource source: String) -> [String?] {
        let code = Array(SwiftSourceScanner.stripComments(from: source))
        let marker = Array("ActionGate" + ".submit(")
        var calls: [String?] = []
        var index = 0
        while index + marker.count <= code.count {
            guard code[index..<(index + marker.count)].elementsEqual(marker) else {
                index += 1
                continue
            }
            let argumentsBegin = index + marker.count
            var cursor = argumentsBegin
            var depth = 1
            var inString = false
            var escaped = false
            var captured: String?
            let limit = min(code.count, argumentsBegin + 2000)
            while cursor < limit {
                let character = code[cursor]
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else if character == "\"" {
                    inString = true
                } else if character == "(" || character == "[" {
                    depth += 1
                } else if character == ")" || character == "]" {
                    depth -= 1
                    if depth == 0 {
                        captured = String(code[argumentsBegin..<cursor])
                        break
                    }
                }
                cursor += 1
            }
            calls.append(captured)
            index = max(cursor, argumentsBegin)
        }
        return calls
    }

    /// Every directory directly under `Sources/`, whatever it is called — the cross-check's
    /// own enumeration (`ZeroNetworkTests.sourceDirectories()`), spelled locally.
    private func sourceDirectories() throws -> Set<String> {
        let sourcesRoot = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources")
        let entries = try FileManager.default.contentsOfDirectory(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey])
        var names: Set<String> = []
        for entry in entries {
            let isDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { names.insert(entry.lastPathComponent) }
        }
        return names
    }

    /// Runs one probe mode under the interposer and returns what was observed, having already
    /// asserted the three things that must hold before any observation can be believed — the
    /// `ZeroNetworkTests.runProbe` shape, mirrored so this suite's drives are guarded the
    /// same way.
    private func runProbe(mode: ProbeMode) throws -> NetworkObservation {
        let session = try NetworkInterposer.startObserving()
        let exitStatus = try session.runProbe(mode: mode)
        let observation = try session.stopObserving()

        XCTAssertEqual(
            exitStatus, 0, "Probe did not run cleanly:\n\(observation.diagnosticSummary)")
        XCTAssertTrue(
            observation.interposerDidLoad,
            """
            The interposer never loaded into the probe process, so it observed nothing. Zero \
            reported agents here would be the absence of evidence, not evidence of absence.
            \(observation.diagnosticSummary)
            """)
        XCTAssertTrue(
            observation.probeCompleted(mode: mode),
            """
            The probe never reported completing mode '\(mode.rawValue)'. Whatever it did, it \
            was not the work this test believes it was observing.
            \(observation.diagnosticSummary)
            """)
        return observation
    }

    /// The `PROBE-CODING-AGENT` line's payload — the `ZeroNetworkTests.agentPayload(of:)`
    /// accessor, mirrored. The line exists only when `exerciseCodingAgent()` ran on the
    /// default-configuration path, so its absence is a missing drive, not an empty report.
    private func agentPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-CODING-AGENT\t") {
            return String(line.dropFirst("PROBE-CODING-AGENT\t".count))
        }
        return nil
    }

    /// Splits a `key=value key=value` report, failing closed on a malformed field or a
    /// repeated key — the `ZeroNetworkTests.parseFields(of:)` shape.
    private func parseFields(of line: String) throws -> [String: String] {
        let parts = line.split(separator: " ")
        var fields: [String: String] = [:]
        for part in parts {
            guard let separator = part.firstIndex(of: "="), separator != part.startIndex else {
                throw ProbeReportError.lineNotParseable(String(part))
            }
            let key = String(part[part.startIndex..<separator])
            guard fields.updateValue(String(part[part.index(after: separator)...]), forKey: key)
                == nil
            else {
                throw ProbeReportError.repeatedField(key)
            }
        }
        return fields
    }
}
