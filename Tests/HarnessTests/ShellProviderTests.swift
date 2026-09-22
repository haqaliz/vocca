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
import VoccaActions
import VoccaCore
import XCTest

/// ``ShellProvider`` — the **third real ``ActionProvider``**, and the one with the highest
/// blast radius in the roadmap (`shell-provider` PRD): a configured shell command can do
/// anything the user can do, so the confirmation surface is the only mitigation, and this
/// suite is where the spine meets that maximum radius.
///
/// ## The sentence is derived from the argv, never authored prose
///
/// The founder decision the whole aspect turns on: ``ActionProvider/describe(_:)`` renders
/// the configured argv itself — the command name, the argv with supplied parameter values
/// substituted in place, the `key = value` value renderings, and the author's optional
/// clause appended last. A planted argv must appear verbatim in the sentence, and a
/// misleading clause cannot hide it: the card confirms what actually runs. The clause is
/// untrusted prose rendered into a safety dialog, so it is sanitised exactly like a
/// parameter value — a control character inside it must not be able to forge a new line of
/// the dialog it appears in (the `MCPProvider` sanitisation discipline, carried over whole).
///
/// ## Every engine call below is recorded, never real
///
/// The provider takes its engine as an injected ``ShellExecutor.Configuration``-shaped run
/// closure, so this suite can assert **what** was asked — the resolved argv, with parameter
/// values substituted — and **that** nothing was asked when it must not be. No test here
/// spawns a child; the real engine's hostile battery lives in `ShellExecutorTests`.
///
/// ## The load-bearing refusal is asserted at the gate, by attempting the call
///
/// The C13 acceptance — a destructive invocation without a confirmation is refused *by
/// attempting the call*, never by observing that no prompt appeared — is driven through
/// ``ActionGate``: live mode, the tool enabled, no approval, and a destructive command.
/// What is asserted is that the submission is ``ActionDecision/confirmationRequired`` **and
/// that the engine was never reached**. The full executor-over-audit-store round trip
/// belongs to the `wiring` aspect, which composes the executor; this suite asserts the
/// refusal at the seam the provider is responsible for.
///
/// ## What is not asserted here
///
/// Nothing wires the provider into the composition root, and nothing here constructs an
/// ``ActionConfirmation`` — Family B confines that to ``ActionGate`` across `Sources/` and
/// `Tests/` alike, and a suite that forged a token to test `invoke` directly would defeat
/// the exact structural refusal the aspect exists to establish. Every invocation below
/// therefore travels through the gate.
final class ShellProviderTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-shell-provider-\(UUID().uuidString)")
    }

    /// The destructive command of the PRD's data model — no `readOnly`, so it claims the
    /// destructive radius.
    private static let emptyDownloads = ShellCommandDefinition(
        id: "empty-downloads",
        command: ["/usr/bin/find", "~/Downloads", "-type", "f", "-delete"],
        clause: "This cannot be undone.")

    /// The read-only command of the PRD's data model — the one way to claim a read-only radius.
    private static let openDashboard = ShellCommandDefinition(
        id: "open-dashboard",
        command: ["/usr/bin/open", "http://localhost:3000"],
        readOnly: true)

    /// A command with two fixed named parameter slots (`$1`, `$2`).
    private static let archive = ShellCommandDefinition(
        id: "archive",
        command: ["/usr/bin/tar", "-czf", "$1", "$2"],
        parameters: [
            ShellCommandParameter(name: "Archive name"),
            ShellCommandParameter(name: "Source"),
        ])

    /// The planted argv: a config whose fixed argv is destructive and whose clause pretends
    /// otherwise. The sentence must show the argv verbatim and the clause must not hide it.
    private static let planted = ShellCommandDefinition(
        id: "planted",
        command: ["/usr/bin/rm", "-rf", "/tmp/evil"],
        clause: "safely tidies temporary files")

    /// A command that declares a parameter its argv never references — a value supplied for
    /// it could never run, so the provider must refuse rather than render a value that lies
    /// about what would happen.
    private static let misconfigured = ShellCommandDefinition(
        id: "misconfigured",
        command: ["/usr/bin/ls", "/var/backups"],
        parameters: [ShellCommandParameter(name: "Backup set")])

    /// The PRD data model's example file — the fixture for the registry-loading path.
    private static let wellFormedJSON = """
        {
          "version": 1,
          "commands": [
            {
              "id": "empty-downloads",
              "command": ["/usr/bin/find", "~/Downloads", "-type", "f", "-delete"],
              "readOnly": false,
              "parameters": [],
              "clause": "This cannot be undone."
            },
            {
              "id": "open-dashboard",
              "command": ["/usr/bin/open", "http://localhost:3000"],
              "readOnly": true,
              "parameters": [],
              "clause": "Opens the staging dashboard."
            },
            {
              "id": "list-backups",
              "command": ["/usr/bin/ls", "/var/backups"],
              "parameters": [{"name": "Backup set"}]
            }
          ]
        }
        """

    private func makeInvocation(
        toolID: String, arguments: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(
                providerID: ShellProvider.providerID, toolID: toolID, arguments: arguments),
            "the invocation under test must construct", file: file, line: line)
    }

    /// A provider over the given commands whose engine records every call and answers
    /// `result`. The runner is returned so a test can assert what was — and was not — asked.
    private func makeProvider(
        commands: [ShellCommandDefinition], result: ShellExecutionResult
    ) -> (ShellProvider, RecordingShellRunner) {
        let runner = RecordingShellRunner(result: result)
        return (ShellProvider(commands: commands) { configuration in
            await runner.run(configuration)
        }, runner)
    }

    /// A successful engine answer.
    private func success() -> ShellExecutionResult {
        ShellExecutionResult(
            status: .succeeded(exitCode: 0),
            standardOutput: Data(), standardError: Data(), outputWasTruncated: false)
    }

    // MARK: - 1. toolIDs from the registry, fixed at construction

    /// **The provider's tools are the registry's command ids, in the registry's order.**
    func testToolIDsEqualTheRegistryCommandIDsInOrder() async throws {
        let (provider, _) = makeProvider(commands: [Self.openDashboard, Self.emptyDownloads], result: success())

        XCTAssertEqual(
            provider.toolIDs, ["open-dashboard", "empty-downloads"],
            "the provider serves exactly the configured commands, in the order the registry "
                + "declared them — a provider that invented, filtered or reordered tools would "
                + "be answering for a registry rather than reporting it")
    }

    /// **The registry-shaped factory loads the file and fixes the tool list at construction.**
    ///
    /// Driven over a real temporary directory and a real `shell-commands.json`, so the
    /// registry path is witnessed rather than assumed.
    func testLoadReadsTheRegistryFileAndFixesTheToolIDsAtConstruction() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.wellFormedJSON.utf8)
            .write(to: directory.appendingPathComponent("shell-commands.json"))

        let provider = await ShellProvider.load(registry: ShellCommandRegistry(directory: directory))

        XCTAssertEqual(
            provider.toolIDs, ["empty-downloads", "open-dashboard", "list-backups"],
            "the loaded provider serves the file's commands in the file's order — construction "
                + "reads the registry once and the list is fixed for the provider's lifetime")
    }

    // MARK: - 2. The argv-derived sentence

    /// **The sentence is derived from the argv: the command name and the argv appear verbatim,
    /// and a misleading clause cannot hide them.**
    ///
    /// The planted fixture is the point: its argv deletes files and its clause claims it
    /// tidies them. The card must show the deletion — the clause is appended after the argv,
    /// never standing in for it.
    func testDescribeRendersTheArgvVerbatimAndAClauseCannotHideIt() async throws {
        let (provider, _) = makeProvider(commands: [Self.planted], result: success())

        let summary = await provider.describe(try makeInvocation(toolID: "planted"))

        XCTAssertTrue(
            summary.sentence.contains("Run the shell command 'planted'"),
            "the sentence names the command: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("/usr/bin/rm -rf /tmp/evil"),
            "the planted argv appears VERBATIM in the sentence — the card confirms what "
                + "actually runs, never the author's description of it: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("safely tidies temporary files"),
            "the authored clause is appended, not dropped")
        let argvRange = summary.sentence.range(of: "/usr/bin/rm -rf /tmp/evil")
        let clauseRange = summary.sentence.range(of: "safely tidies temporary files")
        XCTAssertNotNil(argvRange)
        XCTAssertNotNil(clauseRange)
        XCTAssertLessThan(
            argvRange!.lowerBound, clauseRange!.lowerBound,
            "the clause comes AFTER the argv — a clause that preceded or replaced the argv "
                + "could hide what runs: \(summary.sentence)")
    }

    /// **Supplied parameter values render as `key = value` pairs, keys sorted, and substitute
    /// into the argv — so the sentence states exactly what would run.**
    ///
    /// The supplied value carries a control character (`\n`): it must be sanitised to a space
    /// in the sentence, never able to forge a new line of the dialog it appears in.
    func testParameterValuesRenderSortedSanitisedKeyEqualsValuePairsAndSubstituteIntoTheArgv() async throws {
        let (provider, _) = makeProvider(commands: [Self.archive], result: success())
        let invocation = try makeInvocation(
            toolID: "archive",
            arguments: ##"{"Source": "~/dev\nrm -rf /", "Archive name": "backup.tar"}"##)

        let summary = await provider.describe(invocation)

        XCTAssertTrue(
            summary.sentence.contains("Archive name = \"backup.tar\""),
            "a supplied value renders as key = value, quoted: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("Source = \"~/dev rm -rf /\""),
            "every supplied value renders, sanitised — the control character became a space, "
                + "never a new dialog line: \(summary.sentence)")
        XCTAssertFalse(
            summary.sentence.contains("\n"),
            "no control character may reach the sentence: \(summary.sentence)")
        let archiveNameRange = summary.sentence.range(of: "Archive name =")
        let sourceRange = summary.sentence.range(of: "Source =")
        XCTAssertNotNil(archiveNameRange)
        XCTAssertNotNil(sourceRange)
        XCTAssertLessThan(
            archiveNameRange!.lowerBound, sourceRange!.lowerBound,
            "the pairs are sorted by key — a sentence a person approves must not depend on a "
                + "dictionary's iteration order: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("/usr/bin/tar -czf \"backup.tar\" \"~/dev rm -rf /\""),
            "the argv is rendered with the supplied values substituted in place, so the "
                + "sentence states what would actually run: \(summary.sentence)")
    }

    /// **A control character in the authored clause cannot forge a dialog line either.**
    ///
    /// The clause is untrusted prose rendered into a safety dialog, exactly like a value —
    /// it must be sanitised on the way in.
    func testAControlCharacterInTheClauseCannotForgeADialogLine() async throws {
        let evilClause = ShellCommandDefinition(
            id: "evil-clause",
            command: ["/usr/bin/echo", "hi"],
            clause: "trust me\nand do it anyway")
        let (provider, _) = makeProvider(commands: [evilClause], result: success())

        let summary = await provider.describe(try makeInvocation(toolID: "evil-clause"))

        XCTAssertTrue(
            summary.sentence.contains("trust me and do it anyway"),
            "the clause is appended, sanitised — the newline became a space: \(summary.sentence)")
        XCTAssertFalse(
            summary.sentence.contains("\n"),
            "a clause must not be able to forge a new line of the dialog it appears in: "
                + "\(summary.sentence)")
    }

    // MARK: - 3. Destructive by default

    /// **Absent `readOnly` claims the destructive radius; declared `readOnly: true` is the
    /// only way to claim a read-only one.**
    func testAbsentReadOnlyClaimsDestructiveAndDeclaredTrueClaimsReadOnly() async throws {
        let (provider, _) = makeProvider(
            commands: [Self.emptyDownloads, Self.openDashboard], result: success())

        let destructive = await provider.describe(try makeInvocation(toolID: "empty-downloads"))
        XCTAssertEqual(
            destructive.blastRadius, .destructive,
            "a command whose definition does not declare readOnly: true claims the destructive "
                + "radius — the MCP 'absent means unsafe' precedent, and the floor the gate's "
                + "escalate-only policy can only raise")

        let readOnly = await provider.describe(try makeInvocation(toolID: "open-dashboard"))
        XCTAssertEqual(
            readOnly.blastRadius, .readOnly,
            "readOnly: true is the one way to claim a read-only radius")
    }

    // MARK: - 4. Refusals that keep the radius

    /// **Unreadable argument text refuses with the command's own radius intact.**
    ///
    /// A describe that answered "nothing will happen, read-only" for a destructive command
    /// with an unreadable payload would hand the gate a read-only classification for a
    /// command that is not one — a de-escalation is a de-escalation however it is arrived at.
    func testUnreadableArgumentTextRefusesWhileKeepingTheDestructiveRadius() async throws {
        let (provider, _) = makeProvider(commands: [Self.emptyDownloads], result: success())
        let invocation = try makeInvocation(toolID: "empty-downloads", arguments: "{not json at all")

        let summary = await provider.describe(invocation)

        XCTAssertTrue(
            summary.blastRadius.requiresConfirmation,
            "the radius is the command's claim, not a reading of the payload — unreadable "
                + "arguments must not become a read-only classification: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("refused"),
            "the sentence says the call will be refused: \(summary.sentence)")
        XCTAssertTrue(
            summary.sentence.contains("/usr/bin/find ~/Downloads -type f -delete"),
            "even the refusal renders the argv — the person still sees what would have run: "
                + "\(summary.sentence)")
    }

    /// **A command that declares parameters but receives none is refused, radius intact.**
    func testMissingParameterValuesRefuseWhileKeepingTheDestructiveRadius() async throws {
        let (provider, _) = makeProvider(commands: [Self.archive], result: success())

        let summary = await provider.describe(try makeInvocation(toolID: "archive"))

        XCTAssertTrue(
            summary.blastRadius.requiresConfirmation,
            "missing values are a refusal with the command's own radius: \(summary.sentence)")
        XCTAssertTrue(summary.sentence.contains("refused"))
    }

    /// **A parameter value that is not a JSON string is refused, radius intact** — the argv
    /// is a string array, and a value that has no honest string spelling is a value the
    /// command could not honestly run with.
    func testANonStringParameterValueRefusesWhileKeepingTheDestructiveRadius() async throws {
        let (provider, _) = makeProvider(commands: [Self.archive], result: success())
        let invocation = try makeInvocation(
            toolID: "archive", arguments: ##"{"Archive name": "a.tar", "Source": 3}"##)

        let summary = await provider.describe(invocation)

        XCTAssertTrue(summary.blastRadius.requiresConfirmation)
        XCTAssertTrue(summary.sentence.contains("refused"))
    }

    /// **An argument key no parameter declares is refused, radius intact** — a value for a
    /// slot that does not exist could never run, so the sentence must not pretend it would.
    func testAnUndeclaredParameterKeyRefusesWhileKeepingTheDestructiveRadius() async throws {
        let (provider, _) = makeProvider(commands: [Self.archive], result: success())
        let invocation = try makeInvocation(
            toolID: "archive",
            arguments: ##"{"Archive name": "a.tar", "Source": "src", "Sneaky": "x"}"##)

        let summary = await provider.describe(invocation)

        XCTAssertTrue(summary.blastRadius.requiresConfirmation)
        XCTAssertTrue(summary.sentence.contains("refused"))
    }

    /// **A command whose argv never references a declared parameter is refused, radius
    /// intact** — a supplied value could never reach the argv, so the sentence must not
    /// render one that lies about what would run.
    func testACommandWhoseArgvNeverReferencesADeclaredParameterIsRefusedKeepingTheRadius() async throws {
        let (provider, _) = makeProvider(commands: [Self.misconfigured], result: success())
        let invocation = try makeInvocation(
            toolID: "misconfigured", arguments: ##"{"Backup set": "/tmp"}"##)

        let summary = await provider.describe(invocation)

        XCTAssertTrue(
            summary.blastRadius.requiresConfirmation,
            "a command that declares a parameter its argv never references keeps its "
                + "destructive claim — the refusal is about the value, never the radius: "
                + "\(summary.sentence)")
        XCTAssertTrue(summary.sentence.contains("refused"))
    }

    // MARK: - 5. Unknown commands

    /// **An unknown command describes as a refusal value, never a trap and never an error.**
    func testAnUnknownCommandIsDescribedAsARefusalValueNeverATrap() async throws {
        let (provider, _) = makeProvider(commands: [Self.openDashboard], result: success())

        let summary = await provider.describe(try makeInvocation(toolID: "not-a-command"))

        XCTAssertFalse(
            summary.sentence.isEmpty,
            "a refusal is still a concrete sentence: \(summary.sentence)")
        XCTAssertTrue(summary.sentence.contains("not-a-command"))
        XCTAssertFalse(
            summary.blastRadius.requiresConfirmation,
            "nothing will happen, so nothing needs confirming")
    }

    /// **The tool id of an unknown command is sanitised before it reaches the sentence.**
    func testADescribeSanitisesAToolIDInAnUnknownCommandRefusal() async throws {
        let (provider, _) = makeProvider(commands: [Self.openDashboard], result: success())

        let summary = await provider.describe(try makeInvocation(toolID: "evil\ncommand"))

        XCTAssertFalse(
            summary.sentence.contains("\n"),
            "an unserved tool id must not forge a new line of the refusal dialog: "
                + "\(summary.sentence)")
        XCTAssertTrue(summary.sentence.contains("evil command"))
    }

    // MARK: - 6. invoke: the engine call and the fold

    /// **`invoke` runs the resolved argv through the engine and returns its outcome.**
    ///
    /// Driven through the gate — the only thing that can mint the confirmation `invoke`
    /// demands. The call-logged runner records what was asked, so the assertion is about the
    /// argv that would actually run.
    func testInvokeRunsTheResolvedArgvThroughTheEngineAndReturnsItsOutcome() async throws {
        let (provider, runner) = makeProvider(commands: [Self.emptyDownloads], result: success())
        let invocation = try makeInvocation(toolID: "empty-downloads")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(
            calls.count, 1,
            "exactly one run was asked of the engine")
        XCTAssertEqual(
            calls[0].executablePath, "/usr/bin/find",
            "the executable is the argv's first element")
        XCTAssertEqual(
            calls[0].arguments, ["~/Downloads", "-type", "f", "-delete"],
            "the engine receives the fixed argv — no shell, no metacharacters, nothing typed "
                + "at call time")
    }

    /// **Named parameter values are substituted into the argv before the engine is asked.**
    func testInvokeSubstitutesTheNamedParameterValuesIntoTheArgv() async throws {
        let (provider, runner) = makeProvider(commands: [Self.archive], result: success())
        let invocation = try makeInvocation(
            toolID: "archive",
            arguments: ##"{"Archive name": "backup.tar", "Source": "~/dev"}"##)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        XCTAssertEqual(decision.outcome, .succeeded)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            calls[0].arguments, ["-czf", "backup.tar", "~/dev"],
            "the `$1` and `$2` slots are replaced by the supplied values — what the sentence "
                + "rendered is what runs")
    }

    /// **The engine's bounded failure keys are carried into the outcome unchanged.**
    ///
    /// The fold is one-to-one: the audit entry records the key the engine produced, never a
    /// translation. Swept over the closed vocabulary so a new key is a reviewed addition,
    /// not a stray literal the fold never mapped.
    func testEngineFailureKeysAreCarriedUnchangedIntoTheOutcome() async throws {
        for key in ShellExecutionResult.boundedFailureKeys {
            let failed = ShellExecutionResult(
                status: .failed(reasonKey: key),
                standardOutput: Data(), standardError: Data(), outputWasTruncated: false)
            let (provider, _) = makeProvider(commands: [Self.emptyDownloads], result: failed)
            let invocation = try makeInvocation(toolID: "empty-downloads")

            let decision = await ActionGate.submit(
                invocation, to: provider, enablement: ActionEnablement([invocation]),
                policy: .none, approval: .granted, mode: .live)

            guard case .failed(let reasonKey)? = decision.outcome else {
                return XCTFail(
                    "the engine's \(key) must become a returned failure: "
                        + "\(String(describing: decision.outcome))")
            }
            XCTAssertEqual(
                reasonKey, key,
                "the fold carries the bounded key unchanged — never translated, never "
                    + "re-spelled, so the audit vocabulary stays closed")
        }
    }

    /// **Unreadable arguments are a returned failure at invoke, and the engine is never
    /// asked to run anything.**
    func testInvokeRefusesUnreadableArgumentsAsAValueAndNeverRuns() async throws {
        let (provider, runner) = makeProvider(commands: [Self.emptyDownloads], result: success())
        let invocation = try makeInvocation(toolID: "empty-downloads", arguments: "{not json at all")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)

        guard case .failed(let reasonKey)? = decision.outcome else {
            return XCTFail(
                "unreadable arguments are a returned failure: "
                    + "\(String(describing: decision.outcome))")
        }
        XCTAssertFalse(reasonKey.isEmpty, "the key names why")
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "nothing is run on a payload this provider could not read — a run with the "
                + "arguments dropped would be a different action from the one that was confirmed")
    }

    /// **An unknown command invokes to a returned refusal, never a trap, and never runs.**
    func testAnUnknownCommandInvokesToARefusalNeverATrap() async throws {
        let (provider, runner) = makeProvider(commands: [Self.openDashboard], result: success())
        let unknown = try makeInvocation(toolID: "not-a-command")

        let decision = await ActionGate.submit(
            unknown, to: provider, enablement: ActionEnablement([unknown]),
            policy: .none, approval: .granted, mode: .live)

        guard case .failed(let reasonKey)? = decision.outcome else {
            return XCTFail(
                "an unknown command is a returned failure: "
                    + "\(String(describing: decision.outcome))")
        }
        XCTAssertFalse(reasonKey.isEmpty)
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "a command the registry never declared is not a command to run")
    }

    /// **An empty argv — a shape only a direct constructor can produce, since the registry
    /// refuses it — is refused, never a trap.**
    func testAnEmptyArgvCommandIsRefusedNeverATrap() async throws {
        let empty = ShellCommandDefinition(id: "empty-argv", command: [])
        let (provider, runner) = makeProvider(commands: [empty], result: success())
        let invocation = try makeInvocation(toolID: "empty-argv")

        let summary = await provider.describe(invocation)
        XCTAssertTrue(
            summary.blastRadius.requiresConfirmation,
            "an unrunable argv keeps its claim — the refusal is a value, never a trap")
        XCTAssertTrue(summary.sentence.contains("refused"))

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .live)
        guard case .failed(let reasonKey)? = decision.outcome else {
            return XCTFail(
                "an empty argv is a returned failure, never a trap: "
                    + "\(String(describing: decision.outcome))")
        }
        XCTAssertFalse(reasonKey.isEmpty)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty, "nothing is run for an argv that cannot run")
    }

    // MARK: - 7. The gate holds at maximum radius

    /// **THE load-bearing acceptance: a destructive invocation without a confirmation is
    /// refused by attempting the call, and the engine is never reached.**
    ///
    /// This is the C13 spine applied to the highest blast radius in the roadmap. The
    /// submission below is the live path in every respect — the tool enabled, live mode, no
    /// approval, a command that would really delete files — and the refusal is asserted on
    /// the engine's call log: the call was *attempted* through the gate and stopped there,
    /// rather than the gate being skipped and the command running without a yes.
    func testADestructiveInvocationWithoutApprovalIsRefusedByAttemptingTheCall() async throws {
        let (provider, runner) = makeProvider(commands: [Self.emptyDownloads], result: success())
        let invocation = try makeInvocation(toolID: "empty-downloads")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .withheld, mode: .live)

        guard case .confirmationRequired = decision else {
            return XCTFail(
                """
                a destructive shell command ran without a human's yes: \(decision).
                The confirmation is the only mitigation for a command that can do anything the \
                user can do — a submission that reaches invoke without one has defeated the spine.
                """)
        }
        XCTAssertNil(decision.outcome, "nothing ran, so there is no outcome to report")
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "the engine was never asked — the refusal happens by attempting the call, never "
                + "by observing that no prompt appeared")
    }

    /// **A dry-run describes and stops: the engine is reached zero times.**
    func testADryRunDescribesAndNeverInvokes() async throws {
        let (provider, runner) = makeProvider(commands: [Self.openDashboard], result: success())
        let invocation = try makeInvocation(toolID: "open-dashboard")

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            policy: .none, approval: .granted, mode: .dryRun)

        guard case .previewed = decision else {
            return XCTFail("a rehearsal does not act: \(decision)")
        }
        let calls = await runner.calls
        XCTAssertTrue(
            calls.isEmpty,
            "a dry-run must not reach the engine — zero side effects is a call count")
    }
}

// MARK: - The call-logged engine

/// The provider's engine seam, recorded: every configuration it is asked to run is logged,
/// and the answer is the scripted one.
///
/// An actor because the provider's run closure is `async` and the log is read from the
/// assertions afterwards — the ``RecordingActionProvider`` shape, for the engine instead of
/// the seam. No test here constructs a real ``ShellExecutor``; the real engine's hostile
/// battery lives in `ShellExecutorTests`.
private actor RecordingShellRunner {

    private let result: ShellExecutionResult
    private var log: [ShellExecutor.Configuration] = []

    init(result: ShellExecutionResult) {
        self.result = result
    }

    func run(_ configuration: ShellExecutor.Configuration) -> ShellExecutionResult {
        log.append(configuration)
        return result
    }

    /// Every configuration this runner was asked to run, in order.
    var calls: [ShellExecutor.Configuration] { log }
}