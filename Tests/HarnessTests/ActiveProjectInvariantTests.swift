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

/// **The active-project-detection invariant suite** (`agent-pins` spec acceptances 1-5): the
/// composed default's promises and the lint/digest immobilities re-asserted — deliberately, as
/// tests — with the cwd read (`WorkingDirectoryRead`), the invocation field
/// (`resolvedDirectory`) and the threaded wiring (`activeProjectDirectory`) in the tree.
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
/// - Acceptance 2 is the **module-coverage cross-check** read again: the exercised-module set
///   (the probe's `PROBE-MODULES` line) must equal the set the cross-check derives from the
///   manifest and the `Sources/` listing — the same twelve library modules, `VoccaContext`
///   among them (the new file's module is covered; the drive's witnesses already cover it via
///   `AccessibilityContext` — verified, no witness was needed).
/// - Acceptance 3 re-asserts the lint tables' **current state** — the transport permitted set
///   is still exactly the two reviewed entries, the FileManager seam table still names exactly
///   the eight seams, the AX family is still confined to the two one-file seams with the
///   context seam's entry still `AXContextSource.swift` (and the unit's new file names none of
///   the forbidden families), Family A's seven families and Family B's single minting file are
///   unchanged, and the `policy:` parameter still has no default. The scans themselves are the
///   lint suites' own tests (`ActionTransportProhibitionTests`, `InjectionSeamBoundaryTests`,
///   `ActionSeamBoundaryTests`), which run in this same full-suite run; this leg pins the state
///   they enforce so a change to either side fails here first, in review.
/// - Acceptance 4 recomputes the three G5 digests and asserts the dictation pair is unchanged
///   and `AppBootstrap.swift` still holds the wiring REFACTOR's re-anchored literal
///   (`c7d6767c…` → `641b6445…`, computed with `shasum -a 256`, never edited-to-match).
/// - Acceptance 5 runs the zero-network default-configuration drive with the cwd read composed
///   and asserts the interposer saw nothing: `proc_pidinfo` is not a network call, the read
///   happens only at arm time over the injected closure, and the probe's default run never
///   invokes the arm path.
///
/// ## What is honest about a pins suite
///
/// The tree is expected to be green on every leg the day this lands: the composed default did
/// not move, the lints did not widen, the digests did not change. A green run here is the
/// result, not a failure to be manufactured — the value is that a *future* edit to any of the
/// pinned things now fails in review with a named leg.
final class ActiveProjectInvariantTests: XCTestCase {

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
            The composed default's promises must not move with the cwd read, the invocation \
            carrier and the wiring in the tree — if the drive's report changed deliberately, \
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

    // MARK: - Acceptance 2: the module-coverage cross-check

    /// **Acceptance 2 — the module-coverage cross-check is green with the unit's files in the
    /// tree.** The cross-check (`ZeroNetworkTests.testDefaultConfigurationMakesZeroNetworkConnections`'s
    /// final assertion) derives the required set from the manifest and the `Sources/` listing —
    /// every module directory ∪ every drivable target, minus the non-drivable kinds, minus
    /// only the exclusions the manifest justifies (`VoccaNetworkProbe`, `CVoccaNetworkInterposer`
    /// — each re-asserted to exist and not to ship). This leg recomputes that set the same way,
    /// pins it to the same twelve library modules (the set is unchanged — the unit added no
    /// module, only a file inside a covered one), and re-asserts the cross-check's own equality
    /// against what the probe actually reported driving.
    func testTheModuleCoverageCrossCheckStillCoversEveryModuleWithTheNewFileInTheTree() throws {
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

        // The module set is unchanged: exactly the twelve library modules, VoccaContext among
        // them — the unit's new file lives in a module the drive's witnesses already cover.
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
        XCTAssertTrue(
            shippedModules.contains("VoccaContext"),
            "the new file's module must be among the covered modules — the cross-check's "
                + "module-granular claim covers WorkingDirectoryRead through the "
                + "AccessibilityContext witness")

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

    // MARK: - Acceptance 3: the lint immobilities

    /// **Acceptance 3a — the transport permitted set is still exactly the two reviewed
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
            — the stdio transport and the shell executor. The cwd read, the invocation carrier \
            and the wiring added nothing for it to see; a third entry means a spawn moved \
            somewhere this lint (and this pin) must name in review, with the D2 answer the \
            entry owes. Read off the pin file's own literal: \(body).
            """)
    }

    /// **Acceptance 3b — the FileManager seam table still names exactly the eight seams.**
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
            active-project-detection files ride the existing seams (the cwd read is a libproc \
            call, not a FileManager one — a new file-system-naming file would be a widening, \
            never a silent addition). Read off the pin file's own literal: \(body).
            """)
    }

    /// **Acceptance 3c — the AX family is still confined to the two one-file seams, and the
    /// unit's new file names none of the forbidden families.** The
    /// `InjectionSeamBoundaryTests` accessibility table, read as the current state of the pin
    /// file itself: exactly the two seams, each with exactly one file, and the context seam's
    /// entry still `VoccaContext/Accessibility/AXContextSource.swift` — the unit's
    /// `WorkingDirectoryRead.swift` sits beside it and must not have become a second
    /// AX-naming file. The tree-wide scan is that suite's own test; this leg pins the state
    /// and then re-asserts the new file's own naming contract (the file's doc comment names
    /// it: no AX prefix, no FileManager, no `Process`-prefixed identifier) against a planted
    /// control so the clean result is not vacuous.
    func testTheAccessibilityFamilyIsStillConfinedAndTheNewFileNamesNoFamily() throws {
        let source = try pinFileSource("InjectionSeamBoundaryTests.swift")
        let body = try bracketBody(
            of: source, after: "filesPermittedToNameAccessibilityIdentifiersBySeam",
            file: "InjectionSeamBoundaryTests.swift")
        let entries = try seamTableEntries(of: body)
        XCTAssertFalse(
            entries.isEmpty,
            "the accessibility seam table must not be empty — an empty table passes 'no file "
                + "names the family' vacuously")
        XCTAssertEqual(
            Set(entries.keys), ["accessibility", "context"],
            """
            the accessibility family must still have exactly the two seams — the injection \
            rung's \(entries.keys.sorted()). A third seam is a widening, never a silent \
            addition.
            """)
        XCTAssertEqual(
            entries["accessibility"],
            ["VoccaInject/Accessibility/AXSource.swift"],
            "the injection seam's one AX-naming file must stay AXSource.swift")
        XCTAssertEqual(
            entries["context"],
            ["VoccaContext/Accessibility/AXContextSource.swift"],
            """
            the context seam's one AX-naming file must stay AXContextSource.swift — the \
            unit's WorkingDirectoryRead.swift sits in the same directory and must not have \
            become a second entry.
            """)

        // The new file's own naming contract, asserted against the file itself: no AX prefix,
        // no FileManager identifier, no Process-prefixed identifier — with a planted control
        // proving the detector would catch each family.
        let root = try PackageRootLocator.find(from: #filePath)
        let readFile = root.appendingPathComponent(
            "Sources/VoccaContext/Accessibility/WorkingDirectoryRead.swift")
        let readSource = try String(contentsOf: readFile, encoding: .utf8)
        XCTAssertTrue(
            readSource.contains("WorkingDirectoryRead"),
            "the pinned file must still declare the seam — otherwise this pin watches nothing")
        for (family, prefixes) in [
            ("AX", ["AXUIElement", "AXError", "kAX", "AXObserver"]),
            ("FileManager", ["FileManager"]),
            ("Process", ["Process"]),
        ] {
            XCTAssertEqual(
                Self.familyIdentifiers(prefixes, inSource: readSource), [],
                "WorkingDirectoryRead must name no \(family) family identifier — the seam's "
                    + "vocabulary is the pid and the path, and a naming file would be a "
                    + "decision that escaped the seams CI can reach")
        }
        XCTAssertEqual(
            Self.familyIdentifiers(
                ["AXUIElement", "AXError", "kAX", "AXObserver", "FileManager", "Process"],
                inSource: "let el: AXUIElement? = nil; _ = FileManager.default; _ = Process()"),
            ["AXUIElement", "FileManager", "Process"],
            "the planted control must catch each family — a clean result for the shipped file "
                + "is only meaningful if the detector can fail")
    }

    /// **Acceptance 3d — Family A's seven families and Family B's single minting file are
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
            Family A must confine exactly the seven action families. The active-project-detection \
            files decide nothing over the action vocabulary (the invocation gained a field, not \
            a file — the carrier rides a file already in the tables) — a new family or a renamed \
            one is a reviewed widening, never a silent addition. Read off the pin file's own \
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

    // MARK: - Acceptance 4: the G5 digests

    /// **Acceptance 4 — the dictation digests are unchanged and `AppBootstrap.swift` holds
    /// the wiring REFACTOR's re-anchored literal.** SHA-256 (CryptoKit, the house pattern) of
    /// the three files, asserted against the same literals
    /// `TurnTakingComposedAcceptanceTests.testTheDictationPathIsByteForByteUntouched` and
    /// `AgentPresetsInvariantTests` pin — the pin read again, deliberately, with the cwd read,
    /// the invocation carrier and the wiring in the tree. The two dictation files are
    /// byte-for-byte untouched; the composition root carries the re-anchor
    /// `4e50ab8d…` → `bc2ce1fd…` (computed with `shasum -a 256` on 2026-10-03 by the
    /// `reply-text-rendering` wiring REFACTOR, never edited-to-match — the REFACTOR wired
    /// the converse reply sink into the widget store's `presentReply(_:)` fold; the existing
    /// pin sites carry the same literal, and this suite is one of them).
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
                "bc2ce1fdf261819b8477b7951a6d506c7980c072a674ffc77311014c59b76bd6"
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
                dictation path must stay untouched by the active-project-detection unit; if \
                the change is a deliberate edit, recompute the digest and re-anchor the pin in \
                review — it must never be edited to match a moved tree.
                """)
        }
    }

    // MARK: - Acceptance 5: the zero-network default configuration with the cwd read composed

    /// **Acceptance 5 — the zero-network default-configuration test passes with the cwd read
    /// composed.** The composed root now builds the `activeProjectDirectory` closure over
    /// `AccessibilityContext.workingDirectory()` — a libproc `proc_pidinfo` syscall, which is
    /// not one of the interposer's eight hooks and not a network call; the read happens only
    /// at arm time over the injected closure, and the probe's default run never invokes the
    /// arm path. This leg drives the real probe under the interposer and asserts the same two
    /// zeroes the release blocker asserts, plus the composed root actually ran (the observed
    /// `.accessory` activation policy — `configure(_:)` was called, so the composition that
    /// carries the closure is the one being watched).
    func testTheZeroNetworkDefaultConfigurationStillMakesZeroCallsWithTheCwdReadComposed()
        throws
    {
        let observation = try runProbe(mode: .defaultConfiguration)

        XCTAssertEqual(
            observation.networkConnectionCount, 0,
            """
            Vocca's default configuration must make zero network calls with the cwd read \
            composed. The probe contacted:
            \(observation.networkConnectionDescriptions.joined(separator: "\n"))
            proc_pidinfo is not a network call; the arm-time closure is never reached by the \
            default run. Fix the code. Do not weaken this test.
            \(observation.diagnosticSummary)
            """)
        XCTAssertEqual(
            observation.nameResolutionCount, 0,
            """
            Vocca's default configuration must resolve no hostnames with the cwd read \
            composed. The probe resolved:
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
            — in which case the composition that now carries the activeProjectDirectory closure \
            was never exercised under the interposer — or it no longer sets the policy.
            \(observation.diagnosticSummary)
            """)
    }

    // MARK: - Fixtures and plumbing

    /// Reads one pin file's source from `Tests/HarnessTests/`, comments stripped — the
    /// "read the existing pins" leg: acceptance 3 asserts the lint tables' current state by
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

    /// A dictionary literal's entries — every `"key": ["…", …]` spelling in `body`, keyed by
    /// key. The per-seam form of ``dictionaryKeys``: the value sets the one-file-per-seam
    /// pins read.
    private func seamTableEntries(of body: String) throws -> [String: Set<String>] {
        let pattern = #""([^"]+)"\s*:\s*\[([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        var entries: [String: Set<String>] = [:]
        for match in regex.matches(in: body, range: range) {
            guard
                let keyRange = Range(match.range(at: 1), in: body),
                let valueRange = Range(match.range(at: 2), in: body)
            else { continue }
            let key = String(body[keyRange])
            let values = String(body[valueRange])
            guard entries.updateValue(Set(quotedStrings(in: values)), forKey: key) == nil else {
                throw PinFileError.unbalancedBrackets(marker: key, file: "InjectionSeamBoundaryTests.swift")
            }
        }
        return entries
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

    /// Every occurrence of any `prefix` in `source`, comments removed first — the lint
    /// suites' own detector shape, spelled locally for the new file's naming contract.
    private static func familyIdentifiers(_ prefixes: [String], inSource source: String)
        -> [String]
    {
        let code = SwiftSourceScanner.stripComments(from: source)
        let pattern = "\\b(" + prefixes.joined(separator: "|") + ")[A-Za-z0-9_]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return regex.matches(in: code, range: range).compactMap {
            Range($0.range, in: code).map { String(code[$0]) }
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