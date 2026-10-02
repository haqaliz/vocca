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
import VoccaUI
import XCTest
@testable import VoccaBootstrap

/// **The agent authoring surface's contract** (`agent-authoring` spec acceptances 1-6): the
/// row editor's reducer rows and the save round trip through the real registry.
///
/// Written red, before any of the surface exists. The editor is the Servers-editor pattern
/// applied to `coding-agents.json`: a preset pick pre-fills the drafts (executable/argv from
/// the preset and its detection fact, project directory from the remembered last value), every
/// row field is editable, and Save validates **before** anything reaches the file — the
/// definition's own init rules, the duplicate-id refusal (the registry's first-wins would
/// silently skip a duplicate), and the `<task>` placeholder warning — then folds the row and
/// writes through the registry's save. Save failure keeps the draft; success clears it.
///
/// ## What is real here
///
/// The save path drives the **real** `CodingAgentRegistry` over a real temp directory through
/// the **shipped** mapping (`AppBootstrap.agentFile(from:)` — the translation the composition
/// root's `saveAgents` closure uses), so "write → reload → row present, byte-stable" is the
/// file's own round trip, not a double's opinion of it. Nothing spawns.
final class AgentAuthoringTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-agent-authoring-\(UUID().uuidString)")
    }

    private static let fileName = "coding-agents.json"

    private func bytes(in directory: URL) -> Data? {
        FileManager.default.contents(
            atPath: directory.appendingPathComponent(Self.fileName).path)
    }

    /// The claude preset, as the chooser would receive it through the wiring.
    private static let claude = ActionsAgentPreset(
        id: "claude", displayName: "Claude", candidateNames: ["claude"],
        arguments: ["-p", "<task>"])

    /// The codex preset, as the chooser would receive it through the wiring.
    private static let codex = ActionsAgentPreset(
        id: "codex", displayName: "Codex", candidateNames: ["codex"],
        arguments: ["exec", "<task>"])

    /// A valid definition for assertions — the tab's plain spelling of a registry row.
    private func definition(
        _ id: String,
        executablePath: String = "/usr/local/bin/code-agent",
        arguments: [String] = ["-serve"],
        projectDirectory: String = "/Users/alice/Projects/work",
        timeoutSeconds: Int = 30,
        environment: [String: String]? = nil,
        clause: String? = nil
    ) -> ActionsAgentDefinition {
        ActionsAgentDefinition(
            id: id, executablePath: executablePath, arguments: arguments,
            projectDirectory: projectDirectory, timeoutSeconds: timeoutSeconds,
            environment: environment, clause: clause)
    }

    /// A state with the editor open on the claude preset and the placeholder already
    /// replaced — the baseline every refusal battery mutates one field at a time. The
    /// executable and the project directory are made valid here (the not-detected pre-fill
    /// is a relative marker on purpose), so each case's single mutation is the only thing
    /// wrong with its row.
    private func baselineAdd() -> ActionsTabState {
        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(state, .agentPresetsLoaded([Self.claude]))
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: "claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.arguments, "-p fix the bug"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.executablePath, "/opt/homebrew/bin/claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.projectDirectory, "/Users/alice/Projects/work"))
        return state
    }

    // MARK: - Acceptance 1 · the save round trip through the real registry

    /// **Write → reload → the row is present, byte-stable.** The authoring reducer folds the
    /// row, the shipped mapping translates the tab's file at the root, and the **real**
    /// registry persists it over a real temp directory — the file is the memory, and a second
    /// save of the same file writes the same bytes.
    func testTheSaveBindingWritesARowTheRegistryReadsBack() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CodingAgentRegistry(directory: directory)

        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(state, .agentPresetsLoaded([Self.claude]))
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: "claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.executablePath, "/opt/homebrew/bin/claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.arguments, "-p fix the bug"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.projectDirectory, "/Users/alice/Projects/work"))
        state = ActionsTabReducer.reduce(state, .agentEnvironmentPairAdded)
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.environmentKey(0), "ANTHROPIC_API_KEY"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.environmentValue(0), "sk-test"))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)
        XCTAssertEqual(state.agentDefinitions.count, 1)

        // The shipped save path: the tab's file, mapped at the root, persisted by the registry.
        let file = ActionsAgentFile(agents: state.agentDefinitions)
        let mapped = try AppBootstrap.agentFile(from: file)
        try await registry.save(mapped)
        let firstBytes = try XCTUnwrap(bytes(in: directory))

        // Write → reload → the row is present, exactly as saved.
        let reloaded = await registry.load()
        XCTAssertEqual(reloaded, mapped, "the reloaded registry is exactly what the save wrote")
        XCTAssertEqual(reloaded.agents.map(\.id), ["claude"])
        XCTAssertEqual(reloaded.agents[0].executablePath, "/opt/homebrew/bin/claude")
        XCTAssertEqual(reloaded.agents[0].arguments, ["-p", "fix", "the", "bug"])
        XCTAssertEqual(reloaded.agents[0].projectDirectory, "/Users/alice/Projects/work")
        XCTAssertEqual(reloaded.agents[0].environment, ["ANTHROPIC_API_KEY": "sk-test"])

        // Byte-stable: a second save of the same file writes the same bytes.
        try await registry.save(mapped)
        XCTAssertEqual(
            bytes(in: directory), firstBytes,
            "the same file is the same bytes every time — a hand-editable file must not "
                + "re-order itself between saves")
    }

    // MARK: - Acceptance 2 · the stable id, in-place edit, enablement cascade

    /// **The reducer mints a stable id once per add; edit mutates in place.** The id is
    /// pre-filled from the preset and committed as the row's own id — never regenerated by a
    /// save — and an edit locates the row by its current id and replaces it in place: an edit
    /// never looks like a delete plus a new row.
    func testTheReducerMintsAStableIDOncePerAddAndEditMutatesInPlace() {
        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(state, .agentPresetsLoaded([Self.claude]))
        state = ActionsTabReducer.reduce(
            state,
            .agentDetectionLoaded(["claude": .detected(path: "/opt/homebrew/bin/claude")]))
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: "claude"))
        XCTAssertEqual(state.agentIDDraft, "claude", "the preset's id pre-fills the draft")
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.arguments, "-p fix the bug"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.projectDirectory, "/Users/alice/Projects/work"))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)
        XCTAssertEqual(state.agentDefinitions.count, 1)
        let row = state.agentDefinitions[0]
        XCTAssertEqual(row.id, "claude", "the id is minted once, at the add — the preset's own id")
        XCTAssertEqual(row.executablePath, "/opt/homebrew/bin/claude")

        state = ActionsTabReducer.reduce(state, .saveSucceeded)
        state = ActionsTabReducer.reduce(state, .agentEditStarted(id: "claude"))
        XCTAssertEqual(state.agentIDDraft, "claude", "the editor opens on the row's own id")
        XCTAssertEqual(state.agentExecutablePathDraft, "/opt/homebrew/bin/claude")
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.arguments, "-p fix the other bug"))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)
        XCTAssertEqual(state.agentDefinitions.count, 1, "an edit never adds a row")
        XCTAssertEqual(state.agentDefinitions[0].id, "claude", "an edit keeps the identity")
        XCTAssertEqual(state.agentDefinitions[0].arguments, ["-p", "fix", "the", "other", "bug"])

        state = ActionsTabReducer.reduce(state, .saveSucceeded)
        state = ActionsTabReducer.reduce(state, .agentEditStarted(id: "ghost"))
        XCTAssertEqual(
            state.agentDefinitions.count, 1, "an unknown id opens nothing")
        XCTAssertFalse(state.isAgentEditorOpen, "and leaves the editor closed")
    }

    /// **An edit that renames the id mutates the row in place and carries its enablement
    /// with it** — the old enablement key would otherwise dangle, and a row the user enabled
    /// would silently stop being enabled.
    func testAnEditThatRenamesTheIDCascadesTheEnablementRow() {
        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(state, .agentDefinitionsLoaded([definition("fixer")]))
        state = ActionsTabReducer.reduce(
            state,
            .configLoaded(
                servers: [],
                enablement: [ActionsToolKey(providerID: "vocca.agent", toolID: "fixer")]))

        state = ActionsTabReducer.reduce(state, .agentEditStarted(id: "fixer"))
        state = ActionsTabReducer.reduce(state, .agentDraftFieldEdited(.id, "fixer-2"))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)

        XCTAssertEqual(
            state.agentDefinitions.map(\.id), ["fixer-2"],
            "the edit mutates the row in place — never a delete-plus-add")
        XCTAssertTrue(
            state.enablement.contains(
                ActionsToolKey(providerID: "vocca.agent", toolID: "fixer-2")),
            "the renamed row carries its enablement with it")
        XCTAssertFalse(
            state.enablement.contains(
                ActionsToolKey(providerID: "vocca.agent", toolID: "fixer")),
            "the old key never dangles")
    }

    /// **Remove cascades the enablement key** — a removed agent's key would otherwise be
    /// re-saved by the next save, and the store's stale-row tolerance would keep it forever.
    func testRemoveCascadesTheEnablementKey() {
        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(
            state, .agentDefinitionsLoaded([definition("fixer"), definition("keeper")]))
        state = ActionsTabReducer.reduce(
            state,
            .configLoaded(
                servers: [],
                enablement: [
                    ActionsToolKey(providerID: "vocca.agent", toolID: "fixer"),
                    ActionsToolKey(providerID: "vocca.agent", toolID: "keeper"),
                ]))

        state = ActionsTabReducer.reduce(state, .agentRemoved(id: "fixer"))

        XCTAssertEqual(state.agentDefinitions.map(\.id), ["keeper"])
        XCTAssertFalse(
            state.enablement.contains(
                ActionsToolKey(providerID: "vocca.agent", toolID: "fixer")),
            "the removed agent's enablement row goes with it — the next save must not re-add it")
        XCTAssertTrue(
            state.enablement.contains(
                ActionsToolKey(providerID: "vocca.agent", toolID: "keeper")),
            "the other rows' enablement is untouched")
    }

    // MARK: - Acceptance 3 · the refusals at Save

    /// **A duplicate id is refused at Save with the loud copy** — the registry's first-wins
    /// would silently skip the duplicate, so the editor refuses it loudly, names the id, and
    /// keeps the editor open with the draft intact. An edit that renames onto another
    /// existing row is refused the same way.
    func testADuplicateIDIsRefusedAtSaveWithTheLoudCopy() {
        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(
            state, .agentDefinitionsLoaded([definition("claude")]))
        state = ActionsTabReducer.reduce(state, .agentPresetsLoaded([Self.claude]))
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: "claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.arguments, "-p fix the bug"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.executablePath, "/opt/homebrew/bin/claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.projectDirectory, "/Users/alice/Projects/work"))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)

        XCTAssertEqual(state.agentDefinitions.count, 1, "the duplicate is never added")
        XCTAssertEqual(state.saveError, ActionsTabCopy.agentDuplicateID("claude"))
        XCTAssertTrue(state.isAgentEditorOpen, "the refused save keeps the editor open")
        XCTAssertEqual(state.agentIDDraft, "claude", "the draft is kept for the user to fix")

        var renamed = ActionsTabState.initial
        renamed = ActionsTabReducer.reduce(
            renamed, .agentDefinitionsLoaded([definition("claude"), definition("codex")]))
        renamed = ActionsTabReducer.reduce(renamed, .agentEditStarted(id: "claude"))
        renamed = ActionsTabReducer.reduce(renamed, .agentDraftFieldEdited(.id, "codex"))
        renamed = ActionsTabReducer.reduce(renamed, .agentSaveRequested)
        XCTAssertEqual(
            renamed.agentDefinitions.map(\.id), ["claude", "codex"],
            "the rename onto an existing row is refused")
        XCTAssertEqual(renamed.saveError, ActionsTabCopy.agentDuplicateID("codex"))
        XCTAssertEqual(
            renamed.editingAgentID, "claude",
            "the refused edit keeps the editor on the original row")
    }

    /// **A `<task>`-containing argv is refused with the placeholder warning** — the preset
    /// template pre-fills the placeholder, and a save that still carries it is refused loudly
    /// with a warning naming the placeholder: the row the user saves must be a row that means
    /// something. Replacing the placeholder makes the same row save.
    func testAPlaceholderContainingArgvIsRefusedWithThePlaceholderWarning() {
        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(state, .agentPresetsLoaded([Self.claude]))
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: "claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.executablePath, "/opt/homebrew/bin/claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.projectDirectory, "/Users/alice/Projects/work"))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)

        XCTAssertTrue(state.agentDefinitions.isEmpty)
        XCTAssertEqual(state.saveError, ActionsTabCopy.agentPlaceholderWarning)
        XCTAssertTrue(
            state.saveError?.contains("<task>") ?? false,
            "the warning names the placeholder itself")
        XCTAssertTrue(state.isAgentEditorOpen, "the refused save keeps the editor open")

        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.arguments, "-p fix the bug"))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)
        XCTAssertEqual(state.agentDefinitions.count, 1, "replacing the placeholder makes the row save")
        XCTAssertNil(state.saveError)
    }

    /// **An invalid row is refused loudly, before the file ever sees it** — the definition's
    /// own init rules, spelled on the surface: a relative or `~` executable path, a **filled-in**
    /// relative or `~` project directory, a timeout outside `1...600` (or not a number at all),
    /// an empty id. An emptied timeout draft is the definition's *absent* — the 30-second
    /// default — not a refusal, and an **empty** project directory is the nil-directory row —
    /// the caption's contract, never a refusal.
    func testAnInvalidRowIsRefusedAtSaveLoudly() {
        let cases: [(String, (ActionsTabState) -> ActionsTabState, String)] = [
            (
                "relative executable",
                { ActionsTabReducer.reduce($0, .agentDraftFieldEdited(.executablePath, "claude")) },
                ActionsTabCopy.agentExecutablePathReason
            ),
            (
                "tilde executable",
                { ActionsTabReducer.reduce($0, .agentDraftFieldEdited(.executablePath, "~/bin/claude")) },
                ActionsTabCopy.agentExecutablePathReason
            ),
            (
                "empty executable",
                { ActionsTabReducer.reduce($0, .agentDraftFieldEdited(.executablePath, "")) },
                ActionsTabCopy.agentExecutablePathReason
            ),
            (
                "relative project directory",
                { ActionsTabReducer.reduce($0, .agentDraftFieldEdited(.projectDirectory, "Projects/work")) },
                ActionsTabCopy.agentProjectDirectoryReason
            ),
            (
                "tilde project directory",
                { ActionsTabReducer.reduce($0, .agentDraftFieldEdited(.projectDirectory, "~/Projects/work")) },
                ActionsTabCopy.agentProjectDirectoryReason
            ),
            (
                "timeout zero",
                { ActionsTabReducer.reduce($0, .agentDraftFieldEdited(.timeoutSeconds, "0")) },
                ActionsTabCopy.agentTimeoutReason
            ),
            (
                "timeout over the cap",
                { ActionsTabReducer.reduce($0, .agentDraftFieldEdited(.timeoutSeconds, "601")) },
                ActionsTabCopy.agentTimeoutReason
            ),
            (
                "timeout not a number",
                { ActionsTabReducer.reduce($0, .agentDraftFieldEdited(.timeoutSeconds, "soon")) },
                ActionsTabCopy.agentTimeoutReason
            ),
        ]
        for (name, mutate, reason) in cases {
            var state = baselineAdd()
            state = mutate(state)
            state = ActionsTabReducer.reduce(state, .agentSaveRequested)
            XCTAssertTrue(state.agentDefinitions.isEmpty, "\(name): no row is committed")
            XCTAssertEqual(
                state.saveError, ActionsTabCopy.agentInvalidRow(reason),
                "\(name): the refusal is loud and names the reason")
            XCTAssertTrue(state.isAgentEditorOpen, "\(name): the refused save keeps the editor open")
        }

        // The empty id: a blank pick has no pre-filled id to save under.
        var blank = ActionsTabState.initial
        blank = ActionsTabReducer.reduce(blank, .agentEditorOpened(presetID: nil))
        blank = ActionsTabReducer.reduce(
            blank, .agentDraftFieldEdited(.executablePath, "/opt/homebrew/bin/claude"))
        blank = ActionsTabReducer.reduce(
            blank, .agentDraftFieldEdited(.projectDirectory, "/Users/alice/Projects/work"))
        blank = ActionsTabReducer.reduce(
            blank, .agentDraftFieldEdited(.arguments, "-p fix the bug"))
        blank = ActionsTabReducer.reduce(blank, .agentSaveRequested)
        XCTAssertTrue(blank.agentDefinitions.isEmpty)
        XCTAssertEqual(blank.saveError, ActionsTabCopy.agentInvalidRow(ActionsTabCopy.agentEmptyIDReason))

        // The timeout default: an emptied timeout draft is the definition's absent — 30.
        var defaulted = baselineAdd()
        defaulted = ActionsTabReducer.reduce(
            defaulted, .agentDraftFieldEdited(.timeoutSeconds, ""))
        defaulted = ActionsTabReducer.reduce(defaulted, .agentSaveRequested)
        XCTAssertEqual(defaulted.agentDefinitions.count, 1)
        XCTAssertEqual(defaulted.agentDefinitions[0].timeoutSeconds, 30)
    }

    /// **An empty Project directory field saves — the nil-directory row, round-tripped
    /// through the real registry without the key.** The caption's contract: "leave empty to
    /// detect the focused app's project" — so the blank draft is not a refusal, and the row
    /// the editor commits carries no `projectDirectory` at all in the file's bytes (absence
    /// has one spelling), reloading as nil.
    func testAnEmptyProjectDirectoryFieldSavesAndRoundTripsWithoutTheKey() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CodingAgentRegistry(directory: directory)

        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(state, .agentPresetsLoaded([Self.claude]))
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: "claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.executablePath, "/opt/homebrew/bin/claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.arguments, "-p fix the bug"))
        // The project directory stays the blank pre-fill — the empty field is the point.
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)
        XCTAssertEqual(state.agentDefinitions.count, 1, "an empty project directory field saves")
        XCTAssertNil(
            state.agentDefinitions[0].projectDirectory,
            "the empty draft is the nil-directory row — the arm-time resolution's row")

        // The shipped save path: the tab's file, mapped at the root, persisted by the registry.
        let file = ActionsAgentFile(agents: state.agentDefinitions)
        let mapped = try AppBootstrap.agentFile(from: file)
        try await registry.save(mapped)
        let text = String(decoding: try XCTUnwrap(bytes(in: directory)), as: UTF8.self)
        XCTAssertFalse(
            text.contains("projectDirectory"),
            "absence has one spelling — the saved nil-directory row carries no projectDirectory key")

        let reloaded = await registry.load()
        XCTAssertEqual(reloaded, mapped, "the reloaded registry is exactly what the save wrote")
        XCTAssertEqual(reloaded.agents.map(\.id), ["claude"])
        XCTAssertNil(
            reloaded.agents[0].projectDirectory,
            "the nil-directory row survives the round trip as nil")
    }

    /// **A whitespace-only Project directory field is the empty spelling too** — the field
    /// reads as the nil-directory row, never a refusal and never a mangled relative path.
    func testAWhitespaceOnlyProjectDirectoryFieldSavesAsTheNilDirectoryRow() {
        var state = baselineAdd()
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.projectDirectory, "   "))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)
        XCTAssertEqual(state.agentDefinitions.count, 1)
        XCTAssertNil(
            state.agentDefinitions[0].projectDirectory,
            "a whitespace-only field is the empty spelling — the nil-directory row")
    }

    /// **A row over the caps is refused loudly, never clamped** — 65 arguments, 17
    /// environment entries, a 257-character key or value: a row the store would silently skip
    /// on load is a row the editor refuses at Save.
    func testARowOverTheCapsIsRefusedAtSaveLoudly() {
        var manyArgs = baselineAdd()
        let args = (1...65).map { "arg\($0)" }.joined(separator: " ")
        manyArgs = ActionsTabReducer.reduce(manyArgs, .agentDraftFieldEdited(.arguments, args))
        manyArgs = ActionsTabReducer.reduce(manyArgs, .agentSaveRequested)
        XCTAssertTrue(manyArgs.agentDefinitions.isEmpty)
        XCTAssertEqual(
            manyArgs.saveError, ActionsTabCopy.agentInvalidRow(ActionsTabCopy.agentArgumentCountReason))

        var manyEnv = baselineAdd()
        for _ in 0..<17 { manyEnv = ActionsTabReducer.reduce(manyEnv, .agentEnvironmentPairAdded) }
        for index in 0..<17 {
            manyEnv = ActionsTabReducer.reduce(
                manyEnv, .agentDraftFieldEdited(.environmentKey(index), "K\(index)"))
        }
        manyEnv = ActionsTabReducer.reduce(manyEnv, .agentSaveRequested)
        XCTAssertTrue(manyEnv.agentDefinitions.isEmpty)
        XCTAssertEqual(
            manyEnv.saveError, ActionsTabCopy.agentInvalidRow(ActionsTabCopy.agentEnvironmentCountReason))

        var longKey = baselineAdd()
        longKey = ActionsTabReducer.reduce(longKey, .agentEnvironmentPairAdded)
        longKey = ActionsTabReducer.reduce(
            longKey,
            .agentDraftFieldEdited(
                .environmentKey(0), String(repeating: "k", count: 257)))
        longKey = ActionsTabReducer.reduce(longKey, .agentSaveRequested)
        XCTAssertTrue(longKey.agentDefinitions.isEmpty)
        XCTAssertEqual(
            longKey.saveError, ActionsTabCopy.agentInvalidRow(ActionsTabCopy.agentEnvironmentLengthReason))

        var longValue = baselineAdd()
        longValue = ActionsTabReducer.reduce(longValue, .agentEnvironmentPairAdded)
        longValue = ActionsTabReducer.reduce(
            longValue, .agentDraftFieldEdited(.environmentKey(0), "K"))
        longValue = ActionsTabReducer.reduce(
            longValue,
            .agentDraftFieldEdited(
                .environmentValue(0), String(repeating: "v", count: 257)))
        longValue = ActionsTabReducer.reduce(longValue, .agentSaveRequested)
        XCTAssertTrue(longValue.agentDefinitions.isEmpty)
        XCTAssertEqual(
            longValue.saveError, ActionsTabCopy.agentInvalidRow(ActionsTabCopy.agentEnvironmentLengthReason))
    }

    /// The environment pairs fold into the row's dictionary — and a pair with no key is not
    /// an entry: it contributes nothing rather than a `""` key.
    func testTheEnvironmentPairsFoldIntoTheDefinitionAndEmptyKeysAreDropped() {
        var state = baselineAdd()
        state = ActionsTabReducer.reduce(state, .agentEnvironmentPairAdded)
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.environmentKey(0), "ANTHROPIC_API_KEY"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.environmentValue(0), "sk-test"))
        state = ActionsTabReducer.reduce(state, .agentEnvironmentPairAdded)
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.environmentValue(1), "orphan"))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)

        XCTAssertEqual(
            state.agentDefinitions[0].environment, ["ANTHROPIC_API_KEY": "sk-test"],
            "a pair with no key contributes nothing — never a \"\" entry")
    }

    // MARK: - Acceptance 4 · save failure keeps the draft, success clears it

    /// **Save failure folds `saveFailed` and keeps the draft; save success clears it.** The
    /// editor's fold commits the row and closes the editor, but the drafts are held until a
    /// save that actually reached the file — a failed write surfaces the loud error with the
    /// row the user wrote still in front of them, and the next successful save clears the
    /// drafts.
    func testSaveFailureKeepsTheDraftAndSuccessClearsIt() {
        var state = baselineAdd()
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)
        XCTAssertEqual(state.agentDefinitions.count, 1)
        XCTAssertEqual(
            state.agentIDDraft, "claude",
            "the committed draft is still held — only a save that reached the file clears it")

        state = ActionsTabReducer.reduce(state, .saveFailed("disk full"))
        XCTAssertEqual(state.saveError, "disk full")
        XCTAssertEqual(state.agentIDDraft, "claude", "a failed save keeps the draft")
        XCTAssertEqual(state.agentArgumentsDraft, "-p fix the bug")

        state = ActionsTabReducer.reduce(state, .saveSucceeded)
        XCTAssertNil(state.saveError)
        XCTAssertEqual(state.agentIDDraft, "", "a successful save clears the draft")
        XCTAssertEqual(state.agentArgumentsDraft, "")
        XCTAssertEqual(state.agentProjectDirectoryDraft, "")
        XCTAssertEqual(state.agentEnvironmentDrafts, [])
    }

    // MARK: - Acceptance 5 · the preset pick pre-fills

    /// **A preset pick pre-fills executable/argv from the detection fact** — the detected
    /// path when the binary exists there, the first candidate name unresolved when it does
    /// not (a visible marker the user must make absolute — Save refuses until then) — and a
    /// blank pick starts empty.
    func testAPresetPickPrefillsExecutableAndArgvFromTheDetectionFact() {
        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(state, .agentPresetsLoaded([Self.claude, Self.codex]))
        state = ActionsTabReducer.reduce(
            state,
            .agentDetectionLoaded([
                "claude": .detected(path: "/opt/homebrew/bin/claude"),
                "codex": .notDetected,
            ]))

        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: "claude"))
        XCTAssertEqual(state.agentIDDraft, "claude")
        XCTAssertEqual(
            state.agentExecutablePathDraft, "/opt/homebrew/bin/claude",
            "the detected path pre-fills the executable")
        XCTAssertEqual(state.agentArgumentsDraft, "-p <task>", "the argv template pre-fills")
        XCTAssertEqual(state.agentTimeoutDraft, "30")

        state = ActionsTabReducer.reduce(state, .agentEditorClosed)
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: "codex"))
        XCTAssertEqual(
            state.agentExecutablePathDraft, "codex",
            "not detected: the first candidate name, unresolved — never a claim that it runs")
        XCTAssertEqual(state.agentArgumentsDraft, "exec <task>")

        state = ActionsTabReducer.reduce(state, .agentEditorClosed)
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: nil))
        XCTAssertEqual(state.agentExecutablePathDraft, "", "a blank pick starts empty")
        XCTAssertEqual(state.agentArgumentsDraft, "")
        XCTAssertEqual(state.agentIDDraft, "")
    }

    /// **S2: the editor pre-fills the project directory from a remembered last value** — in
    /// memory only this slice, never persisted.
    func testTheEditorRemembersTheLastProjectDirectory() {
        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(state, .agentPresetsLoaded([Self.claude]))
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: "claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.executablePath, "/opt/homebrew/bin/claude"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.arguments, "-p fix the bug"))
        state = ActionsTabReducer.reduce(
            state, .agentDraftFieldEdited(.projectDirectory, "/Users/alice/Projects/work"))
        state = ActionsTabReducer.reduce(state, .agentSaveRequested)
        XCTAssertEqual(
            state.agentDefinitions[0].projectDirectory, "/Users/alice/Projects/work")

        state = ActionsTabReducer.reduce(state, .saveSucceeded)
        state = ActionsTabReducer.reduce(state, .agentEditorOpened(presetID: nil))
        XCTAssertEqual(
            state.agentProjectDirectoryDraft, "/Users/alice/Projects/work",
            "the editor pre-fills the remembered last project directory — in memory, never "
                + "persisted this slice")
    }

    // MARK: - Acceptance 6 · the composed default is unchanged

    /// **The composed default is unchanged: the section with no rows still reads the empty
    /// state.** The initial state carries no rows, no presets, no detection facts and no
    /// open editor; a loaded-but-empty state is the honest "nothing configured". The PROBE
    /// post-condition (`agents=0 spawnsSubprocess=false`) is the zero-network suite's fact,
    /// untouched by anything here.
    func testTheComposedDefaultIsUnchanged() {
        let state = ActionsTabState.initial
        XCTAssertTrue(state.agentDefinitions.isEmpty, "no rows — the section reads the empty state")
        XCTAssertTrue(state.agentRows.isEmpty)
        XCTAssertTrue(state.agentPresets.isEmpty)
        XCTAssertTrue(state.agentDetection.isEmpty)
        XCTAssertFalse(state.isAgentLoaded, "no load has been asked for yet")
        XCTAssertFalse(state.isAgentCatalogLoaded)
        XCTAssertFalse(state.isAgentEditorOpen, "no editor is open")
        XCTAssertNil(state.editingAgentID)

        var loaded = state
        loaded = ActionsTabReducer.reduce(loaded, .configLoaded(servers: [], enablement: []))
        loaded = ActionsTabReducer.reduce(loaded, .agentConfigLoaded([]))
        loaded = ActionsTabReducer.reduce(loaded, .agentDefinitionsLoaded([]))
        XCTAssertTrue(loaded.isAgentLoaded)
        XCTAssertTrue(
            loaded.agentDefinitions.isEmpty,
            "the honest empty state: loaded, and nothing configured")
        XCTAssertTrue(loaded.agentRows.isEmpty)
    }
}