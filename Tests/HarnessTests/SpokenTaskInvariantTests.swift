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

/// **The spoken-task-seeding invariant suite** (`agent-pins` spec acceptances 1-5): the
/// composed default's promises and the lint/digest immobilities re-asserted — deliberately, as
/// tests — with the task carrier (`ActionInvocation.taskText`), the one-render substitution
/// (`CodingAgentSentences.substitutedArguments` + the refusal keys) and the threading (the
/// widened intent-action handler, the intent enrichment and the placeholder-arm refusal) in
/// the tree.
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
///   still reported exactly as `ZeroNetworkTests.expectedCodingAgentLifecycle` pins it.
/// - Acceptance 2 re-asserts the lint tables' **current state** — the transport permitted set
///   is still exactly the two reviewed entries, the FileManager seam table still names exactly
///   the eight seams, Family A's seven families and Family B's single minting file are
///   unchanged, and the `policy:` parameter still has no default. The scans themselves are the
///   lint suites' own tests (`ActionTransportProhibitionTests`, `InjectionSeamBoundaryTests`,
///   `ActionSeamBoundaryTests`), which run in this same full-suite run; this leg pins the state
///   they enforce so a change to either side fails here first, in review.
/// - Acceptance 3 recomputes the three G5 digests and asserts the dictation pair is unchanged
///   and `AppBootstrap.swift` holds the wiring REFACTOR's re-anchored literal (`bc2ce1fd…`) —
///   the `reply-text-rendering` wiring REFACTOR re-anchored it deliberately (computed, never
///   edited-to-match), and this asserts the honest actual: the composition root's digest,
///   exactly as the tree holds it.
/// - Acceptance 4 pins the **driver's compile pins**: the widened intent-action handler's
///   signature and its silent default (`= { _, _ in nil }` — the unwired driver stays
///   byte-identical), the recipe's passthrough default, the pipeline's utterance-passing call
///   site, and the constructible pins in the compile-pin suites (`ConverseLoopDriverTests`,
///   `ConverseIntentStepTests`, `IntentDriverIntegrationTests`) all carrying the widened
///   signature — read from each file's own source, so a reverted or re-widened signature
///   fails here first.
/// - Acceptance 5 runs the zero-network default-configuration drive with the carrier and the
///   threading composed, asserts the interposer saw nothing (the substitution happens only in
///   the provider over an invocation field — no new call), and re-asserts the module-coverage
///   cross-check's set: unchanged at the twelve library modules (the unit added a field and
///   wiring, no module files).
///
/// ## What is honest about a pins suite
///
/// The tree is expected to be green on every leg the day this lands: the composed default did
/// not move, the lints did not widen, the digests did not change. A green run here is the
/// result, not a failure to be manufactured — the value is that a *future* edit to any of the
/// pinned things now fails in review with a named leg.
final class SpokenTaskInvariantTests: XCTestCase {

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
            }
        }
    }

    /// **Acceptance 1 — the PROBE-CODING-AGENT line is verbatim-unchanged with the unit's
    /// files in the tree.** Runs the real probe under the interposer (the
    /// `ZeroNetworkTests` drive shape — same three preconditions, same accessor), compares the
    /// whole line against the pinned literal, and reads the two composed-default facts back
    /// field by field: `agents=0` (an absent registry is the empty registry) and
    /// `spawnsSubprocess=false` (the D2 narrowed promise, declared for the configuration).
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
            The composed default's promises must not move with the task carrier, the \
            one-render substitution and the threading in the tree — if the drive's report \
            changed deliberately, re-anchor this literal and ZeroNetworkTests' own constant in \
            the same reviewed edit, never edited-to-match.
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
            — the stdio transport and the shell executor. The task carrier, the substitution \
            and the threading added nothing for it to see; a third entry means a spawn moved \
            somewhere this lint (and this pin) must name in review, with the D2 answer the \
            entry owes. Read off the pin file's own literal: \(body).
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
            spoken-task-seeding files ride the existing seams — the substitution is a pure \
            string rule (no file-system naming) and the carrier is a field on a file already \
            in the tables — so a ninth seam would be a widening, never a silent addition. \
            Read off the pin file's own literal: \(body).
            """)
    }

    /// **Acceptance 2c — Family A's seven families and Family B's single minting file are
    /// unchanged, and the `policy:` parameter still has no default.** The
    /// `ActionSeamBoundaryTests` tables, read as the current state of the pin file itself:
    /// the families table's `name:` entries must be exactly the seven action families, the
    /// forgery guard's permitted set must hold exactly the one gate file under `Sources/`
    /// (never a `Tests/` file), and the gate's declaration still spells
    /// `policy: ActionRadiusPolicy` with no `=` default — the F2 fail-open default stays
    /// removed. The scans are that suite's own tests; this leg pins the state.
    func testTheActionFamiliesAndForgeryGuardAreUnchanged() throws {
        let root = try PackageRootLocator.find(from: #filePath)
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
            Family A must confine exactly the seven action families. The spoken-task-seeding \
            files decide nothing new over the action vocabulary (the invocation gained a \
            field, not a file — the carrier rides a file already in the tables; the provider \
            and the wirings are rows the tables already name) — a new family or a renamed one \
            is a reviewed widening, never a silent addition. Read off the pin file's own \
            literal: \(familiesBody).
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
    }

    // MARK: - Acceptance 3: the G5 digests

    /// **Acceptance 3 — the dictation digests are unchanged and `AppBootstrap.swift` holds
    /// the prior unit's re-anchored literal.** SHA-256 (CryptoKit, the house pattern) of the
    /// three files, asserted against the same literals
    /// `TurnTakingComposedAcceptanceTests.testTheDictationPathIsByteForByteUntouched`,
    /// `AgentPresetsInvariantTests` and `ActiveProjectInvariantTests` pin — the pin read
    /// again, deliberately, with the task carrier, the substitution and the threading in the
    /// tree. The two dictation files are byte-for-byte untouched; the composition root
    /// carries the wiring REFACTOR's re-anchor `bc2ce1fd…` — the `reply-text-rendering`
    /// wiring REFACTOR (2026-10-03, computed with `shasum -a 256`, never edited-to-match)
    /// wired the converse reply sink into the widget store's `presentReply(_:)` fold, so the
    /// G5 pin was re-anchored deliberately and this asserts the honest actual: the value the
    /// tree holds.
    ///
    /// Re-anchored once more, deliberately, on 2026-10-04 by `composite-intent-resolver`
    /// (`bc2ce1fd…` → `d46fd928…` → `a0dae00b…` — two re-anchors in one unit, the second
    /// when the keyword leg's exclusion widened to the coding-agent provider; each computed
    /// with `shasum -a 256` after the unit's last
    /// composition-root edit, never edited-to-match): the composition root composes the
    /// per-turn resolver provider over the `keywordFallback` switch. The two dictation
    /// digests are unchanged.
    ///
    /// Re-anchored once more, deliberately, on 2026-10-08 by `converse-intent-wiring`
    /// (`a0dae00b…` → `bfeed81f…` — one re-anchor, computed with `shasum -a 256` after the
    /// unit's only composition-root edit, never edited-to-match): `configure` passes the
    /// intent provider and action handler, built by `composeConverseIntentClosures`, to
    /// `composeConverseWiring`. The two dictation digests are unchanged.
    func testTheDictationDigestsAreUnchangedAndAppBootstrapHoldsTheReanchoredLiteral() throws {
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
                "bfeed81f8cd53cb3190425a48e072e3f316eba5884e7290563fc0b9e16676eba"
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
                dictation path must stay untouched by the spoken-task-seeding unit; if the \
                change is a deliberate edit, recompute the digest and re-anchor the pin in \
                review — it must never be edited to match a moved tree.
                """)
        }
    }

    // MARK: - Acceptance 4: the driver's compile pins

    /// **Acceptance 4 — the widened handler's signature, its silent default, the recipe's
    /// passthrough, the pipeline's utterance-passing call site and the constructible pins
    /// all still hold.** The threading widened the driver's intent-action handler to carry
    /// the cleaned utterance (`utterance-threading` — a deliberate pin update, never a
    /// widening). This leg reads each pin's own file: the driver's parameter and its
    /// `= { _, _ in nil }` default (the unwired driver is byte-identical to today), the
    /// recipe's passthrough with the same default, the pipeline's call site passing the
    /// utterance verbatim, and the compile-pin suites' constructible pins (`ConverseLoopDriverTests`
    /// constructing with the silent closure, `ConverseIntentStepTests` and
    /// `IntentDriverIntegrationTests` declaring the widened signature) — a reverted or
    /// re-widened signature fails here first, in review.
    func testTheDriversWidenedHandlerAndItsCompilePinsStillHold() throws {
        let root = try PackageRootLocator.find(from: #filePath)

        let driverSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/VoccaBootstrap/ConverseLoopDriver.swift"),
            encoding: .utf8)
        let driverCode = SwiftSourceScanner.stripComments(from: driverSource)
        XCTAssertTrue(
            driverCode.contains(
                "intentActionHandler: @escaping @Sendable (ActionInvocation, String) async -> String?"
            ),
            """
            the driver must still declare the widened intent-action handler — the threading's \
            deliberate pin update, carrying the cleaned utterance. A reverted signature takes \
            the enrichment's task text with it, and this pin watches nothing.
            """)
        XCTAssertTrue(
            driverCode.contains("= { _, _ in nil }"),
            """
            the widened handler must still default to silence — the unwired driver is \
            byte-identical to today (the composed default composes the same unwired closures \
            the pre-threading driver had). A removed default would be a compile break for \
            every construction site, never a silent edit.
            """)
        XCTAssertTrue(
            driverCode.contains("intentActionHandler(invocation, raw)"),
            """
            the driver's pipeline must still pass the cleaned utterance to the handler at the \
            `.toolCall` site — the words the wiring fills an agent row's `<task>` placeholder \
            with. A call site that stopped passing the utterance would make the threading \
            a no-op while every pin above stayed green.
            """)

        let recipeCode = SwiftSourceScanner.stripComments(
            from: try String(
                contentsOf: root.appendingPathComponent(
                    "Sources/VoccaBootstrap/ConverseWiring.swift"),
                encoding: .utf8))
        XCTAssertTrue(
            recipeCode.contains(
                "intentActionHandler: @escaping @Sendable (ActionInvocation, String) async -> String?"
            ),
            "the converse recipe must still pass the widened handler through — the composition's "
                + "own compile pin")
        XCTAssertTrue(
            recipeCode.contains("= { _, _ in nil }"),
            "the recipe's passthrough must keep the silent default — an unwired composition "
                + "is byte-identical to today")

        let loopPins = try String(
            contentsOf: root.appendingPathComponent(
                "Tests/HarnessTests/ConverseLoopDriverTests.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            loopPins.contains("intentActionHandler: { _, _ in nil }"),
            "the constructible pin in ConverseLoopDriverTests must construct the widened "
                + "handler with the silent closure — its compile is the driver's own pin")

        for file in ["ConverseIntentStepTests.swift", "IntentDriverIntegrationTests.swift"] {
            let pinSource = try String(
                contentsOf: root.appendingPathComponent("Tests/HarnessTests/\(file)"),
                encoding: .utf8)
            XCTAssertTrue(
                pinSource.contains(
                    "intentActionHandler: @escaping @Sendable (ActionInvocation, String) async -> String?"
                ),
                "\(file)'s makeDriver must still declare the widened signature — the compile "
                    + "pin the threading updated deliberately")
        }
    }

    // MARK: - Acceptance 5: the zero-network default configuration with the unit composed

    /// **Acceptance 5a — the zero-network default-configuration test passes with the carrier
    /// and the threading composed.** The substitution happens only in the provider over an
    /// invocation field — no new call, no new module file — and the probe's default run never
    /// reaches the substitution (zero agents). This leg drives the real probe under the
    /// interposer and asserts the same two zeroes the release blocker asserts, plus the
    /// composed root actually ran (the observed `.accessory` activation policy — `configure(_:)`
    /// was called, so the composition that carries the threading is the one being watched).
    func testTheZeroNetworkDefaultConfigurationStillMakesZeroCallsWithTheUnitComposed()
        throws
    {
        let observation = try runProbe(mode: .defaultConfiguration)

        XCTAssertEqual(
            observation.networkConnectionCount, 0,
            """
            Vocca's default configuration must make zero network calls with the task carrier \
            and the threading composed. The probe contacted:
            \(observation.networkConnectionDescriptions.joined(separator: "\n"))
            The substitution is a pure string rule in the provider over an invocation field — \
            no new call exists for it to make. Fix the code. Do not weaken this test.
            \(observation.diagnosticSummary)
            """)
        XCTAssertEqual(
            observation.nameResolutionCount, 0,
            """
            Vocca's default configuration must resolve no hostnames with the task carrier and \
            the threading composed. The probe resolved:
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
            — in which case the composition that now carries the threading was never exercised \
            under the interposer — or it no longer sets the policy.
            \(observation.diagnosticSummary)
            """)
    }

    /// **Acceptance 5b — the module-coverage cross-check is green with the unit's files in
    /// the tree.** The cross-check (`ZeroNetworkTests.testDefaultConfigurationMakesZeroNetworkConnections`'s
    /// final assertion) derives the required set from the manifest and the `Sources/` listing —
    /// every module directory ∪ every drivable target, minus the non-drivable kinds, minus
    /// only the exclusions the manifest justifies (`VoccaNetworkProbe`, `CVoccaNetworkInterposer`
    /// — each re-asserted to exist and not to ship). This leg recomputes that set the same way,
    /// pins it to the same twelve library modules (the set is unchanged — the unit added a
    /// field and wiring, no module files), and re-asserts the cross-check's own equality
    /// against what the probe actually reported driving.
    func testTheModuleCoverageCrossCheckStillCoversEveryModuleWithTheUnitInTheTree() throws {
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

        // The module set is unchanged: exactly the twelve library modules — the unit's files
        // all live in modules the drive's witnesses already cover (the carrier rides
        // VoccaCore's invocation, the substitution VoccaActions', the threading the
        // VoccaBootstrap wirings the probe drives).
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
            excluded silently — and one removed must be removed here too.
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