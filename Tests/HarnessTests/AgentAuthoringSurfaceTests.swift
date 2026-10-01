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
import VoccaUI
import XCTest

/// **The agent authoring surface's pins** (`agent-authoring` spec acceptances 3-7): the copy
/// the section speaks, the agreement between the surface's validation vocabulary and the
/// action layer's own constants, the section's shape in the page, and the bindings' no-op
/// defaults.
///
/// Written red, before any of the surface exists. The copy pins are the
/// ``ActionsTabTests`` shape; the vocabulary-agreement pin is the store/resolver agreement
/// precedent (`IntentPhraseStoreTests`) — `VoccaUI` may not name the action layer's types
/// (the module boundary), so the surface's second spelling of the caps and the placeholder is
/// honest only while this pin proves it agrees with the one source of truth.
final class AgentAuthoringSurfaceTests: XCTestCase {

    // MARK: - The copy pins

    /// The authoring copy, verbatim: the add affordance, the chooser, the editor labels, the
    /// honest detection facts, and the loud refusals.
    func testTheAuthoringCopyIsPinned() {
        XCTAssertEqual(ActionsTabCopy.agentAddButton, "Add coding agent")
        XCTAssertEqual(ActionsTabCopy.agentChooserTitle, "Preset")
        XCTAssertEqual(ActionsTabCopy.agentBlankOption, "Blank")
        XCTAssertEqual(ActionsTabCopy.agentExecutablePathLabel, "Executable path")
        XCTAssertEqual(ActionsTabCopy.agentArgumentsLabel, "Arguments")
        XCTAssertEqual(ActionsTabCopy.agentProjectDirectoryLabel, "Project directory")
        XCTAssertEqual(ActionsTabCopy.agentTimeoutLabel, "Timeout (seconds)")
        XCTAssertEqual(ActionsTabCopy.agentEnvironmentLabel, "Environment")
        XCTAssertEqual(ActionsTabCopy.agentClauseLabel, "Clause")
        XCTAssertEqual(ActionsTabCopy.agentAddEnvironmentEntry, "Add environment entry")

        // The honest detection facts: "detected" means the binary exists at that path.
        XCTAssertEqual(
            ActionsTabCopy.agentDetected("/opt/homebrew/bin/claude"),
            "Detected — /opt/homebrew/bin/claude")
        XCTAssertEqual(ActionsTabCopy.agentNotDetected, "not detected")

        // The loud refusals — each names what was refused.
        XCTAssertTrue(
            ActionsTabCopy.agentPlaceholderWarning.hasPrefix("Save refused:"),
            "the placeholder refusal is loud")
        XCTAssertTrue(
            ActionsTabCopy.agentPlaceholderWarning.contains("<task>"),
            "the warning names the placeholder itself")
        XCTAssertTrue(ActionsTabCopy.agentDuplicateID("claude").hasPrefix("Save refused:"))
        XCTAssertTrue(ActionsTabCopy.agentDuplicateID("claude").contains("claude"))
        XCTAssertTrue(
            ActionsTabCopy.agentInvalidRow(ActionsTabCopy.agentTimeoutReason).hasPrefix("Save refused:"))
        XCTAssertEqual(
            ActionsTabCopy.agentTimeoutReason,
            "the timeout must be a number between 1 and 600 seconds")
    }

    /// **The surface's validation vocabulary agrees with the action layer's** — `VoccaUI`
    /// cannot name the registry's constants, so the surface spells the caps, the timeout
    /// default and the placeholder itself; this pin is what keeps that second spelling the
    /// same fact. A retune on either side fails here, loudly.
    func testTheAuthoringVocabularyAgreesWithTheActionLayer() {
        XCTAssertEqual(AgentAuthoringConstants.taskPlaceholder, KnownAgentPresets.taskPlaceholder)
        XCTAssertEqual(AgentAuthoringConstants.maximumIDLength, CodingAgentRegistry.maximumIDLength)
        XCTAssertEqual(
            AgentAuthoringConstants.maximumArgumentCount, CodingAgentRegistry.maximumArgumentCount)
        XCTAssertEqual(
            AgentAuthoringConstants.maximumEnvironmentEntries,
            CodingAgentRegistry.maximumEnvironmentEntries)
        XCTAssertEqual(
            AgentAuthoringConstants.maximumEnvironmentValueLength,
            CodingAgentRegistry.maximumEnvironmentValueLength)
        XCTAssertEqual(
            AgentAuthoringConstants.maximumTimeoutSeconds, CodingAgentRegistry.maximumTimeoutSeconds)
        XCTAssertEqual(
            AgentAuthoringConstants.defaultTimeoutSeconds, CodingAgentRegistry.defaultTimeoutSeconds)
        XCTAssertEqual(AgentAuthoringConstants.agentProviderID, CodingAgentProvider.providerID)
    }

    /// **The D2 copy is unchanged** — the agent leg's trust-extension copy, exact-in-spirit,
    /// untouched by the authoring surface.
    func testTheD2CopyIsUnchanged() {
        XCTAssertEqual(
            ActionsTabCopy.agentD2TrustCopy,
            "Configuring a coding agent runs it on your machine with your configured project; "
                + "Vocca cannot see inside a program it starts on your behalf — an enabled "
                + "agent's egress is never provable.")
    }

    // MARK: - The section's shape in the page

    /// **The agents section carries the chooser, the editor and the row actions** — the
    /// section body renders the rows with their editor and the add affordance beside the D2
    /// copy and the default-off detail, and the page's gestures all fold through the reducer
    /// (a chooser pick opens the pre-filled editor, field edits and Save fold, Edit opens,
    /// Remove folds).
    func testTheAgentsSectionCarriesTheChooserTheEditorAndTheRowActions() throws {
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
            body.body.contains("ActionsTabCopy.agentD2TrustCopy"),
            "the agents section must carry the D2 copy — the moment of arm")
        XCTAssertTrue(
            body.body.contains("ActionsTabCopy.defaultOffDetail"),
            "the agents section's rows sit beside the default-off detail, like the server rows")
        XCTAssertTrue(body.body.contains("agentRow("), "the agent rows render in the section")
        XCTAssertTrue(body.body.contains("agentEditor("), "the editor renders in the section")
        XCTAssertTrue(body.body.contains("addAgentForm()"), "the add affordance renders in the section")

        XCTAssertTrue(
            page.contains(".agentEditorOpened"),
            "a chooser pick opens the pre-filled editor through the reducer")
        XCTAssertTrue(
            page.contains(".agentSaveRequested"),
            "the editor's Save validates and folds through the reducer")
        XCTAssertTrue(
            page.contains(".agentDraftFieldEdited"),
            "every field edit folds through the reducer")
        XCTAssertTrue(
            page.contains(".agentEditStarted"),
            "a row's Edit opens through the reducer")
        XCTAssertTrue(
            page.contains(".agentRemoved"),
            "a row's Remove folds through the reducer")
        XCTAssertTrue(
            page.contains("ActionsTabCopy.agentAddButton"),
            "the add affordance's copy is on the page")
        XCTAssertTrue(
            page.contains("ActionsTabCopy.agentChooserTitle"),
            "the chooser title's copy is on the page")
        XCTAssertTrue(
            page.contains("ActionsTabCopy.agentDetected"),
            "the detection-fact rendering is on the page")
        XCTAssertTrue(
            page.contains("ActionsTabCopy.agentNotDetected"),
            "the not-detected rendering is on the page")
    }

    // MARK: - The bindings claim nothing bare

    /// The C12 convention: a `SettingsBindings` constructed with only the required closures
    /// claims nothing and changes nothing. The authoring closures all default — an empty
    /// preset list renders the honest chooser, an empty definitions list renders the honest
    /// empty state, no detection facts are claimed, and a save that goes nowhere changes
    /// nothing.
    @MainActor
    func testTheAuthoringBindingDefaultsClaimNothing() async {
        let bindings = SettingsBindings(
            isToggleMode: { true },
            setToggleMode: { _ in },
            hotkeyDisplayName: { "" },
            chordForKeyEvent: { _, keyCode in HotkeyChord(keyCode: keyCode, modifiers: []) },
            validateChord: { chord, _ in HotkeyBindingRules.validate(chord, against: []) },
            rebind: { _, _ in .unchanged },
            engineDisplayName: { "" },
            cleanupSummary: { nil },
            loadDictionary: { [] },
            saveDictionary: { _ in })

        let presets = await bindings.loadAgentPresets()
        XCTAssertEqual(
            presets, [],
            "no presets are claimed — with nothing behind the page, the chooser has nothing "
                + "to render")
        let definitions = await bindings.loadAgentDefinitions()
        XCTAssertEqual(
            definitions, [],
            "no definitions are claimed — the honest empty state")
        let detection = await bindings.detectAgents()
        XCTAssertEqual(
            detection, [:],
            "no detection facts are claimed — nothing is said about any binary")
        try? await bindings.saveAgents(.empty)
        // Nothing to assert but that it returned: the default changes nothing and reports
        // nothing, which a claims-something default could not manage.
    }

    // MARK: - Fixtures

    private func pageSource() throws -> String {
        try String(
            contentsOf: try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/Actions/ActionsTabPage.swift"),
            encoding: .utf8)
    }
}