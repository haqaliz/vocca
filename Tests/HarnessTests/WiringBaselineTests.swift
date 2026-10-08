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
import VoccaActions
import VoccaCore
import VoccaUI
import XCTest

/// **The wiring-baseline invariant suite** (`wiring-baseline` spec acceptances 1-5, the
/// `agent-auth-baseline` unit): HOME wired into both providers at the composition root, the
/// auth hints + the D2 baseline line on the surface, the composed default facts unchanged,
/// and the deliberate G5 re-anchor.
///
/// ## What each leg is
///
/// - Acceptance 1 reads the **wiring's fact**: `AppBootstrap` passes
///   `baselineEnvironment: ["HOME": NSHomeDirectory()]` into both provider constructions
///   (the composition root may name Foundation; `VoccaActions` never computes home), and the
///   wired value reaches the configurations the providers build — driven through the gate,
///   the `ProviderBaselineTests` shape, with the composition's own value.
/// - Acceptance 2 runs the **real probe** in `defaultConfiguration` mode under the interposer
///   (the `ZeroNetworkTests` drive shape) and asserts the `PROBE-CODING-AGENT` line is
///   verbatim-unchanged — `agents=0 spawnsSubprocess=false` and the whole seeded round trip
///   still reported exactly as `ZeroNetworkTests.expectedCodingAgentLifecycle` pins it. The
///   probe's drives keep the DEFAULT `[:]` baseline (recorded in the drives): the composed
///   default facts are about the configuration, not the environment, and the seeded round
///   trips run `/bin/echo`, a child that needs no HOME.
/// - Acceptance 3 pins the **auth hints' render**: the editor shows the picked preset's hint
///   under the Environment field (only when non-nil), the root's mapping carries it across
///   the module boundary (`VoccaUI` cannot name `VoccaActions` types), and each preset's hint
///   is pinned verbatim in `KnownAgentPresetsTests`.
/// - Acceptance 4 pins the **D2 baseline line** — "the baseline hands the agent your home
///   directory; configure only agents you trust", exact-in-spirit with the existing D2
///   copies — and its placement in the agents section, the moment of arm.
/// - Acceptance 5 recomputes the three G5 digests and asserts the dictation pair is unchanged
///   and `AppBootstrap.swift` holds the wiring REFACTOR's re-anchored literal (computed with
///   `shasum -a 256`, never edited-to-match).
///
/// ## What is honest about a pins suite
///
/// The tree is expected to be green on every leg the day this lands — the composed default
/// did not move, the lints did not widen, the dictation digests did not change. A green run
/// here is the result, not a failure to be manufactured — the value is that a *future* edit
/// to any of the pinned things now fails in review with a named leg.
@MainActor
final class WiringBaselineTests: XCTestCase {

    // MARK: - Acceptance 1: the composed providers carry the wired baseline

    /// **The wiring's fact: `AppBootstrap` passes the HOME baseline into both provider
    /// constructions.** The composition root may name Foundation — and it does, exactly
    /// once per provider, spelled as the spec pins it: `baselineEnvironment: ["HOME":
    /// NSHomeDirectory()]`. Two occurrences, no more: the shell construction (which
    /// precedes this file's first occurrence) and the agent construction (which precedes
    /// the second). `VoccaActions` never computes home — the seam has no home accessor,
    /// the `AgentCLIDetection` precedent — so this literal is the one place the value
    /// enters the composition.
    func testAppBootstrapWiresTheHomeBaselineIntoBothProviderConstructions() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift"),
            encoding: .utf8)

        let wired = "baselineEnvironment: [\"HOME\": NSHomeDirectory()]"
        var occurrences: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while let found = source.range(of: wired, range: searchStart..<source.endIndex) {
            occurrences.append(found)
            searchStart = found.upperBound
        }

        XCTAssertEqual(
            occurrences.count, 2,
            """
            the HOME baseline must be wired into exactly the two provider constructions — the \
            shell provider and the coding-agent provider — and nowhere else. A third wired \
            baseline (or a dropped one) is a composition decision, not a typo. Found \(occurrences.count).
            """)
        XCTAssertTrue(
            source[..<occurrences[0].lowerBound].contains("ShellProvider("),
            "the first wired baseline must sit in the shell provider's construction")
        XCTAssertTrue(
            source[occurrences[0].upperBound..<occurrences[1].lowerBound]
                .contains("CodingAgentProvider("),
            "the second wired baseline must sit in the coding-agent provider's construction")
    }

    /// **The wired value reaches the coding agent's configuration** — the composition's own
    /// `["HOME": NSHomeDirectory()]`, carried into every configuration the provider builds.
    /// The counting engine asserts the ``ShellExecutor/Configuration/baselineEnvironment``
    /// value; the provider is constructed exactly as `configure` now constructs it (the
    /// init, never the `load` factory — the factories take no baseline).
    func testTheWiredBaselineReachesTheCodingAgentConfiguration() async throws {
        let runner = RecordingBaselineRunner()
        let provider = CodingAgentProvider(
            agents: [Self.commitHelper],
            run: { configuration in await runner.run(configuration) },
            baselineEnvironment: ["HOME": NSHomeDirectory()])
        let invocation = try XCTUnwrap(
            ActionInvocation(
                providerID: CodingAgentProvider.providerID, toolID: "commit-helper",
                arguments: nil))

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].baselineEnvironment, ["HOME": NSHomeDirectory()],
            "the configuration the agent engine receives carries the wired HOME baseline — "
                + "exactly the composition's value, in the provider's own field")
        XCTAssertEqual(
            calls[0].environment, ["VOCCA_TEST_KEY": "1"],
            "the row's own entries still flow alongside, never merged, never dropped")
    }

    /// **The wired value reaches the shell configuration too** — the same composition line,
    /// in the shell provider's constructions. Shell rows declare no environment of their
    /// own, so the wired HOME is the whole of what a shell child receives.
    func testTheWiredBaselineReachesTheShellConfiguration() async throws {
        let runner = RecordingBaselineRunner()
        let provider = ShellProvider(
            commands: [Self.printEnvironment],
            run: { configuration in await runner.run(configuration) },
            baselineEnvironment: ["HOME": NSHomeDirectory()])
        let invocation = try XCTUnwrap(
            ActionInvocation(
                providerID: ShellProvider.providerID, toolID: "print-env", arguments: nil))

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].baselineEnvironment, ["HOME": NSHomeDirectory()],
            "a shell row's configuration carries the wired HOME baseline — exactly as "
                + "composed, never beyond it")
        XCTAssertEqual(
            calls[0].environment, [:],
            "the shell configuration still carries no row environment — the baseline is "
                + "carried beside it, never in it")
    }

    // MARK: - Acceptance 2: the composed default facts unchanged

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

    /// **Acceptance 2 — the PROBE-CODING-AGENT line is verbatim-unchanged with the baseline
    /// wired and the hints on the surface.** Runs the real probe under the interposer (the
    /// `ZeroNetworkTests` drive shape — same three preconditions, same accessor), compares
    /// the whole line against the pinned literal, and reads the two composed-default facts
    /// back field by field: `agents=0` (an absent registry is the empty registry) and
    /// `spawnsSubprocess=false` (the D2 narrowed promise, declared for the configuration).
    ///
    /// The drives keep the DEFAULT `[:]` baseline (the recorded posture): the composed
    /// default's facts are about the configuration — zero agents, no spawn — and the seeded
    /// round trips run `/bin/echo`, a child that needs no HOME, so a temp HOME would change
    /// nothing the report observes.
    func testTheProbeCodingAgentLineIsVerbatimUnchangedWithTheBaselineWired() throws {
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
            The composed default's promises must not move with the baseline wired and the \
            hints on the surface — if the drive's report changed deliberately, re-anchor this \
            literal and ZeroNetworkTests' own constant in the same reviewed edit, never \
            edited-to-match.
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

    // MARK: - Acceptance 3: the auth hints render

    /// **Acceptance 3a — the editor renders the picked preset's auth hint under the
    /// Environment field, only when the hint is non-nil.** The `agentEditor()` body, from
    /// the Environment label to the Clause field, must carry the hint read (the preset's
    /// `authHint` through the state) behind an `if let` — the non-nil gate that keeps the
    /// editor silent for a preset without a hint or for a row whose id is no preset's.
    func testTheEditorRendersTheAuthHintUnderTheEnvironmentField() throws {
        let page = SwiftSourceScanner.stripComments(from: try pageSource())
        guard let environment = page.range(of: "ActionsTabCopy.agentEnvironmentLabel") else {
            return XCTFail("the editor must name its Environment field through the copy enum")
        }
        let after = page[environment.upperBound...]
        guard let clause = after.range(of: "ActionsTabCopy.agentClauseLabel") else {
            return XCTFail("the editor must name its Clause field through the copy enum")
        }
        let between = after[..<clause.lowerBound]

        XCTAssertTrue(
            between.contains("authHint"),
            "the editor must render the picked preset's auth hint between the Environment "
                + "field and the Clause field — the hint is the authoring surface's answer to "
                + "'which auth does this CLI use?'")
        XCTAssertTrue(
            between.contains("if let"),
            "the hint must be gated on non-nil — a preset without a hint (or a row whose id "
                + "is no preset's) must render nothing under the Environment field")
    }

    /// **Acceptance 3b — the root's mapping carries the hint across the module boundary.**
    /// `VoccaUI` cannot name `VoccaActions` types, so `AppBootstrap` maps the catalog's
    /// presets into the tab's plain spelling — and the mapping must carry `authHint` with
    /// the rest of the row, or the hint never reaches the editor.
    func testThePresetsMappingCarriesTheAuthHintToTheSurface() throws {
        let root = try PackageRootLocator.find(from: #filePath)
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            source.contains("authHint: $0.authHint"),
            "the root's preset mapping must carry the catalog's authHint into the tab's plain "
                + "spelling — a mapping that drops the hint leaves the editor silent even "
                + "though the catalog carries it")
    }

    // MARK: - Acceptance 4: the D2 baseline line

    /// **Acceptance 4a — the D2 baseline line is pinned.** The honest sentence the hard
    /// question earned: the baseline hands every agent child the user's home directory, so
    /// configuring an agent is trust extended to its author over the whole home folder —
    /// exact-in-spirit with the D2 copies beside it.
    func testTheBaselineD2LineIsPinned() {
        XCTAssertEqual(
            ActionsTabCopy.agentBaselineD2Copy,
            "the baseline hands the agent your home directory; configure only agents you trust")
    }

    /// **Acceptance 4b — the D2 baseline line sits in the agents section**, beside the
    /// agent D2 copy — the section where agents are configured and armed, the moment of
    /// trust.
    func testTheAgentsSectionCarriesTheBaselineD2Line() throws {
        let page = SwiftSourceScanner.stripComments(from: try pageSource())
        guard let sectionTitle = page.range(of: "ActionsTabCopy.agentsSectionTitle") else {
            return XCTFail("the page must name its agents section through the copy enum")
        }
        let after = page[sectionTitle.upperBound...]
        guard let brace = after.firstIndex(of: "{") else {
            return XCTFail("the section header must open a braced body")
        }
        let characters = Array(after)
        let offset = after.distance(from: after.startIndex, to: brace)
        guard let body = SwiftSourceScanner.bracedBody(in: characters, openingBraceIndex: offset)
        else {
            return XCTFail("the section body must balance")
        }
        XCTAssertTrue(
            body.body.contains("ActionsTabCopy.agentBaselineD2Copy"),
            "the agents section must carry the D2 baseline line — the moment of trust, where "
                + "the agent D2 copy already sits")
        XCTAssertTrue(
            body.body.contains("ActionsTabCopy.agentD2TrustCopy"),
            "the agents section still carries the agent D2 copy — the baseline line sits "
                + "beside it, never instead of it")
    }

    // MARK: - Acceptance 5: the G5 digests

    /// **Acceptance 5 — the dictation digests are unchanged and `AppBootstrap.swift` holds
    /// the wiring REFACTOR's re-anchored literal.** SHA-256 (CryptoKit, the house pattern)
    /// of the three files, asserted against the same literals
    /// `TurnTakingComposedAcceptanceTests.testTheDictationPathIsByteForByteUntouched` pins —
    /// the pin read again, deliberately, with the converse reply sink wired in the tree.
    /// The two dictation files are byte-for-byte untouched; the composition root carries the
    /// re-anchor `4e50ab8d…` → `bc2ce1fd…` (computed with `shasum -a 256` on 2026-10-03 by
    /// the `reply-text-rendering` wiring REFACTOR, never edited-to-match).
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
                dictation path must stay untouched by the reply-text-rendering wiring unit; \
                if the change is a deliberate edit, recompute the digest and re-anchor the \
                pin in review — it must never be edited to match a moved tree.
                """)
        }
    }

    // MARK: - Fixtures

    /// An agent row with its own environment — the configuration must carry the row's
    /// entries AND the wired baseline, side by side.
    private static let commitHelper = CodingAgentDefinition(
        id: "commit-helper",
        executablePath: "/usr/bin/true",
        arguments: [],
        projectDirectory: "/Users/aliz/dev/at/vocca",
        timeoutSeconds: 30,
        environment: ["VOCCA_TEST_KEY": "1"],
        clause: nil)!

    /// A shell row that declares no environment — the shell leg's witness: the wired
    /// baseline is the whole of a shell child's environment.
    private static let printEnvironment = ShellCommandDefinition(
        id: "print-env",
        command: ["/usr/bin/env"])

    /// Runs one probe mode under the interposer and returns what was observed, having already
    /// asserted the three things that must hold before any observation can be believed — the
    /// `ZeroNetworkTests.runProbe` shape, mirrored so this suite's one drive is guarded the
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

    /// The page's source, as the scan pins read it.
    private func pageSource() throws -> String {
        try String(
            contentsOf: try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/Actions/ActionsTabPage.swift"),
            encoding: .utf8)
    }
}

// MARK: - The call-logged engine

/// The providers' engine seam, recorded: every configuration it is asked to run is logged,
/// and the answer is the scripted success — the `ProviderBaselineTests` recording runner
/// shape. No row here spawns a child; the acceptance is about the configuration's
/// `baselineEnvironment` value, which a recorded call is exactly the right witness for.
private actor RecordingBaselineRunner {

    private var log: [ShellExecutor.Configuration] = []

    func run(_ configuration: ShellExecutor.Configuration) -> ShellExecutionResult {
        log.append(configuration)
        return ShellExecutionResult(
            status: .succeeded(exitCode: 0),
            standardOutput: Data(), standardError: Data(), outputWasTruncated: false)
    }

    /// Every configuration this runner was asked to run, in order.
    var calls: [ShellExecutor.Configuration] { log }
}