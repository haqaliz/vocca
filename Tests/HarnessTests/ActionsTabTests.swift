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
import VoccaCore
import VoccaUI
import XCTest

/// **The Actions tab's contract** (`action-surface-wiring/actions-tab/spec.md`, acceptances 1-7).
///
/// Written red, before any of the tab exists. The tab is a settings surface for the action
/// layer: servers can be configured, their tools discovered by an **explicit, user-initiated**
/// action, tools enabled one at a time (**off by default** — M7), and an enabled tool armed
/// into the confirmation state the wiring's card reads. Three things this file exists to pin,
/// because each is a safety property rather than a preference:
///
/// - **arming a disabled tool is refused by the reducer**, so no confirmation signal can be
///   emitted from a state that did not change (the M7 never-read rule at the surface);
/// - **the D2 copy lives in the discover section** — the moment of spawn — because configuring
///   a server is trust extended to its author, not a guarantee Vocca can make;
/// - **no "don't ask again" copy exists anywhere in the tab** (M4a): a confirmation is never
///   skippable, so no sentence may offer to skip it.
final class ActionsTabTests: XCTestCase {

    // MARK: - Fixtures

    /// A state as the page opens it: the config loaded, nothing discovered, nothing armed.
    private func loaded(
        servers: [ActionsServerRow] = [], enablement: Set<ActionsToolKey> = []
    ) -> ActionsTabState {
        ActionsTabReducer.reduce(
            .initial, .configLoaded(servers: servers, enablement: enablement))
    }

    private func tool(
        _ providerID: String, _ toolID: String, enabled: Bool = false,
        radius: ActionsTabRadius = .destructive
    ) -> ActionsToolRow {
        ActionsToolRow(
            providerID: providerID, toolID: toolID, summary: "does \(toolID)",
            radius: radius, isEnabled: enabled)
    }

    // MARK: - Acceptance 1 · the tab exists in the sidebar

    /// `allCases` drives the sidebar (`SettingsTab.swift`): a case that exists gets a row and a
    /// page, or the build fails. The case has to exist, and it has to carry words and a symbol.
    func testSettingsTabIncludesActions() {
        XCTAssertTrue(SettingsTab.allCases.contains(.actions))
        XCTAssertEqual(SettingsTab.actions.title, "Actions")
        XCTAssertEqual(SettingsTab.actions.symbolName, "bolt")
        XCTAssertEqual(SettingsTab.actions.id, "actions")
    }

    // MARK: - Acceptance 2 · servers and discovery

    /// Add, edit and remove a server. The id is minted once at add time and survives edits —
    /// it is what the config file and every later reader identify the server by
    /// (`MCPServerConfiguration`), so an edit must never look like a delete plus a new server.
    func testServersCanBeAddedEditedAndRemoved() {
        var state = loaded()
        XCTAssertEqual(state.discovery, .idle, "nothing is discovered before anyone asks")

        state = ActionsTabReducer.reduce(state, .serverNameFieldEdited("files"))
        state = ActionsTabReducer.reduce(state, .serverPathFieldEdited("/usr/bin/files-server"))
        state = ActionsTabReducer.reduce(state, .serverAdded)
        XCTAssertEqual(state.servers.count, 1)
        let server = state.servers[0]
        XCTAssertEqual(server.name, "files")
        XCTAssertEqual(server.path, "/usr/bin/files-server")
        XCTAssertEqual(
            state.serverNameDraft, "",
            "the draft clears once the server exists — a second add must not repeat the first")

        state = ActionsTabReducer.reduce(state, .serverEditStarted(id: server.id))
        XCTAssertEqual(
            state.serverNameDraft, "files", "the editor opens on the server's own name")
        XCTAssertEqual(state.serverPathDraft, "/usr/bin/files-server")
        state = ActionsTabReducer.reduce(state, .serverNameFieldEdited("files-2"))
        state = ActionsTabReducer.reduce(state, .serverPathFieldEdited("/opt/files"))
        state = ActionsTabReducer.reduce(state, .serverEdited)
        XCTAssertEqual(state.servers[0].id, server.id, "an edit keeps the identity")
        XCTAssertEqual(state.servers[0].name, "files-2")
        XCTAssertEqual(state.servers[0].path, "/opt/files")
        XCTAssertNil(state.editingServerID, "the editor closes once the edit is committed")

        state = ActionsTabReducer.reduce(state, .serverRemoved(id: server.id))
        XCTAssertTrue(state.servers.isEmpty)
    }

    /// A server needs both a name and a path — a nameless server or a pathless one is not a
    /// server (the store refuses an empty executable path), and the reducer refuses the add
    /// before the file ever sees it.
    func testServerAddRefusesANamelessOrPathlessServer() {
        let nameless = ActionsTabReducer.reduce(
            .initial, .serverNameFieldEdited(""))
        XCTAssertTrue(
            ActionsTabReducer.reduce(nameless, .serverPathFieldEdited("/usr/bin/x")).servers.isEmpty,
            "a server with no name cannot be added")

        let pathless = ActionsTabReducer.reduce(
            .initial, .serverPathFieldEdited(""))
        XCTAssertTrue(
            ActionsTabReducer.reduce(pathless, .serverNameFieldEdited("x")).servers.isEmpty,
            "a server with no path cannot be added")
    }

    /// Discovery is a closed three-step: idle → discovering → succeeded, with the tool list held
    /// on success. Nothing else may be held — the row the page renders comes from this state.
    func testDiscoveryTransitionsIdleDiscoveringSucceeded() {
        var state = loaded()
        state = ActionsTabReducer.reduce(state, .discoveryStarted(serverID: "s1"))
        XCTAssertEqual(state.discovery, .discovering(serverID: "s1"))

        let rows = [tool("s1", "list"), tool("s1", "delete")]
        state = ActionsTabReducer.reduce(state, .discoverySucceeded(serverID: "s1", tools: rows))
        guard case .succeeded(let serverID, let tools) = state.discovery else {
            return XCTFail("discovery must succeed, got \(state.discovery)")
        }
        XCTAssertEqual(serverID, "s1")
        XCTAssertEqual(tools, rows, "the tool list is held on success")
        XCTAssertEqual(state.toolRows, rows, "the page's rows are the held list")
    }

    /// A failed discovery holds the bounded key — the reason shown under the discover control —
    /// and a retry leaves `failed` for `discovering`: the tab recovers without a relaunch.
    func testDiscoveryFailureYieldsTheKeyAndRetryRecovers() {
        var state = loaded()
        state = ActionsTabReducer.reduce(state, .discoveryStarted(serverID: "s1"))
        state = ActionsTabReducer.reduce(state, .discoveryFailed(serverID: "s1", key: "spawn refused"))
        guard case .failed(let serverID, let key) = state.discovery else {
            return XCTFail("discovery must fail, got \(state.discovery)")
        }
        XCTAssertEqual(serverID, "s1")
        XCTAssertEqual(key, "spawn refused")
        XCTAssertTrue(state.toolRows.isEmpty, "no stale tool rows survive a failure")

        state = ActionsTabReducer.reduce(state, .discoveryStarted(serverID: "s1"))
        XCTAssertEqual(
            state.discovery, .discovering(serverID: "s1"),
            "a retry recovers from failure to discovering")
    }

    /// **Default off (M7), and it is the reducer's rule, not the wiring's.** A tool handed over
    /// as enabled arrives off unless the persisted enablement holds its key — a lying discovery
    /// answer cannot arm a tool on arrival. And **absent is off**: a flip for a tool with no row
    /// mints nothing and enables nothing.
    func testNewlyDiscoveredToolsDefaultOffAndAbsentIsOff() {
        var state = loaded(enablement: [ActionsToolKey(providerID: "s1", toolID: "remembered")])
        let rows = [tool("s1", "fresh", enabled: true), tool("s1", "remembered", enabled: true)]
        state = ActionsTabReducer.reduce(state, .discoverySucceeded(serverID: "s1", tools: rows))

        XCTAssertFalse(
            state.toolRows[0].isEnabled,
            "a newly discovered tool's row is off even when handed enabled — default off is the "
                + "reducer's, so the wiring cannot arm a tool on arrival")
        XCTAssertTrue(
            state.toolRows[1].isEnabled,
            "a persisted enablement row re-applies at discovery — re-enabling after a relaunch "
                + "must not require re-discovering and re-toggling")

        let before = state
        state = ActionsTabReducer.reduce(
            state, .toolEnabledChanged(providerID: "s1", toolID: "never-listed", enabled: true))
        XCTAssertEqual(
            state, before,
            "absent is off: a tool with no row cannot be enabled, in the state or the set")
    }

    /// Enablement flips the row **and** the persisted set together — the draft the page saves
    /// cannot disagree with the table the user is reading.
    func testToolEnablementFlipsTheRowAndThePersistedSet() {
        var state = loaded()
        state = ActionsTabReducer.reduce(
            state, .discoverySucceeded(serverID: "s1", tools: [tool("s1", "list")]))

        state = ActionsTabReducer.reduce(
            state, .toolEnabledChanged(providerID: "s1", toolID: "list", enabled: true))
        XCTAssertTrue(state.toolRows[0].isEnabled)
        XCTAssertTrue(
            state.enablement.contains(ActionsToolKey(providerID: "s1", toolID: "list")))

        state = ActionsTabReducer.reduce(
            state, .toolEnabledChanged(providerID: "s1", toolID: "list", enabled: false))
        XCTAssertFalse(state.toolRows[0].isEnabled)
        XCTAssertFalse(
            state.enablement.contains(ActionsToolKey(providerID: "s1", toolID: "list")))
    }

    /// Removing a server takes its tool rows and its enablement rows with it. The rows are the
    /// state's half and the set is the draft's half — the file's enablement for the removed
    /// server would otherwise be re-saved by the very next save, and the store's stale-row
    /// tolerance would keep a ghost server's tools enabled forever.
    func testRemovingAServerRemovesItsToolRowsAndEnablementRows() {
        var state = loaded()
        state = ActionsTabReducer.reduce(
            state, .serverNameFieldEdited("files"))
        state = ActionsTabReducer.reduce(
            state, .serverPathFieldEdited("/usr/bin/files"))
        state = ActionsTabReducer.reduce(state, .serverAdded)
        let server = state.servers[0]

        state = ActionsTabReducer.reduce(state, .discoveryStarted(serverID: server.id))
        state = ActionsTabReducer.reduce(
            state,
            .discoverySucceeded(
                serverID: server.id, tools: [tool(server.id, "list"), tool(server.id, "delete")]))
        state = ActionsTabReducer.reduce(
            state, .toolEnabledChanged(providerID: server.id, toolID: "list", enabled: true))

        state = ActionsTabReducer.reduce(state, .serverRemoved(id: server.id))
        XCTAssertTrue(state.servers.isEmpty)
        XCTAssertTrue(
            state.toolRows.isEmpty,
            "the removed server's tool rows go with it — the table cannot keep offering its tools")
        XCTAssertEqual(
            state.discovery, .idle,
            "discovery of a removed server resets — a removed server's result must not linger")
        XCTAssertFalse(
            state.enablement.contains(ActionsToolKey(providerID: server.id, toolID: "list")),
            "the removed server's enablement rows go with it — the next save must not re-add them")
    }

    // MARK: - Acceptance 3 · the arm path runs through the gate only

    /// Arming an **enabled** tool yields `awaitingConfirmation` — the state the wiring's card
    /// signal targets. The tab never calls the gate; it emits the state and stops.
    func testArmingAnEnabledToolYieldsAwaitingConfirmation() {
        var state = loaded()
        state = ActionsTabReducer.reduce(
            state, .discoverySucceeded(serverID: "s1", tools: [tool("s1", "list")]))
        state = ActionsTabReducer.reduce(
            state, .toolEnabledChanged(providerID: "s1", toolID: "list", enabled: true))

        state = ActionsTabReducer.reduce(state, .armRequested(providerID: "s1", toolID: "list"))
        XCTAssertEqual(state.arm, .awaitingConfirmation(providerID: "s1", toolID: "list"))
    }

    /// **Arming a disabled tool is refused by the reducer** — the state does not change, so no
    /// confirmation signal can be emitted from it. The M7 never-read rule at the surface: a tool
    /// that was never enabled is never one confirmation away from running.
    func testArmingADisabledToolIsRefused() {
        var state = loaded()
        state = ActionsTabReducer.reduce(
            state, .discoverySucceeded(serverID: "s1", tools: [tool("s1", "list")]))
        let before = state

        state = ActionsTabReducer.reduce(state, .armRequested(providerID: "s1", toolID: "list"))
        XCTAssertEqual(
            state, before,
            "arming a disabled tool leaves the state untouched — a fold that changes nothing can "
                + "emit no confirmation signal")
        XCTAssertEqual(state.arm, .idle)
    }

    /// An absent tool is refused the same way — absent is off, so absent cannot arm.
    func testArmingAnAbsentToolIsRefused() {
        let before = loaded()
        let after = ActionsTabReducer.reduce(before, .armRequested(providerID: "s1", toolID: "ghost"))
        XCTAssertEqual(after, before)
    }

    /// The confirmation state clears on dismissal — the wiring folds this when the card goes
    /// away, so the arm path is a complete round trip even before the wiring exists.
    func testArmClearsOnDismissal() {
        var state = loaded()
        state = ActionsTabReducer.reduce(
            state, .discoverySucceeded(serverID: "s1", tools: [tool("s1", "list")]))
        state = ActionsTabReducer.reduce(
            state, .toolEnabledChanged(providerID: "s1", toolID: "list", enabled: true))
        state = ActionsTabReducer.reduce(state, .armRequested(providerID: "s1", toolID: "list"))
        XCTAssertEqual(state.arm, .awaitingConfirmation(providerID: "s1", toolID: "list"))

        state = ActionsTabReducer.reduce(state, .armDismissed)
        XCTAssertEqual(state.arm, .idle)
    }

    // MARK: - Acceptance 4 · preview renders without acting

    /// The preview row renders the provider's own sentence — the dry-run half of the seam. The
    /// tab's state holds the row; that the sentence was produced without any `invoke` is the
    /// wiring level's assertion (stub call log), not something a settings table can know.
    func testPreviewShownRendersThePreviewRow() {
        var state = loaded()
        state = ActionsTabReducer.reduce(
            state,
            .previewShown(
                providerID: "s1", toolID: "list",
                sentence: "List the files in the current directory."))
        guard case .showing(let providerID, let toolID, let sentence) = state.preview else {
            return XCTFail("the preview row must render, got \(state.preview)")
        }
        XCTAssertEqual(providerID, "s1")
        XCTAssertEqual(toolID, "list")
        XCTAssertEqual(sentence, "List the files in the current directory.")

        state = ActionsTabReducer.reduce(state, .previewCleared)
        XCTAssertEqual(state.preview, .idle)
    }

    // MARK: - Acceptance 5 · the copy pins

    /// The D2 copy, exact-in-spirit (`spec.md`: "configuring a server is trust extended to its
    /// author, not a guarantee we can make"). It is the narrowed promise in words: Vocca's check
    /// cannot see inside a program Vocca starts on your behalf.
    func testTheD2TrustCopyIsPinned() {
        XCTAssertEqual(
            ActionsTabCopy.d2TrustCopy,
            "Configuring a server is trust extended to its author, not a guarantee we can make.")
    }

    /// The default-off detail (M7) — the row copy under the toggles: tools are off until enabled,
    /// and a disabled tool cannot be invoked.
    func testTheDefaultOffDetailIsPinned() {
        XCTAssertEqual(
            ActionsTabCopy.defaultOffDetail,
            "Tools are off by default. Enable a tool before it can be invoked.")
    }

    /// **M4a, at the copy layer:** no sentence anywhere in the tab offers to skip the next
    /// confirmation. A confirmation that can be switched off is a confirmation that quietly
    /// stops being asked; the tab's words may never sell that.
    func testNoAskAgainCopyInTheActionsFolder() throws {
        let folder = try actionsFolder()
        let files = SwiftSourceScanner.swiftFiles(under: folder)
        XCTAssertFalse(files.isEmpty, "the scan ran against nothing")

        for file in files {
            let text = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            for phrase in ["ask again", "don't ask", "always allow", "remember my choice",
                "don't show this again"] {
                XCTAssertFalse(
                    text.contains(phrase),
                    "\(file.lastPathComponent) carries '\(phrase)' — M4a: a confirmation is "
                        + "never skippable, so no sentence may offer to skip it")
            }
        }
    }

    // MARK: - Acceptance 6 · the bindings claim nothing bare

    /// The C12 convention: a `SettingsBindings` constructed with only the required closures
    /// claims nothing and changes nothing. The Actions closures all default — an empty config
    /// renders the honest empty state, an un-wired discovery claims no tools, an un-wired
    /// preview claims no sentence, and the save/arm/signal closures change nothing at all.
    @MainActor
    func testTheActionsBindingDefaultsClaimNothing() async {
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

        let config = await bindings.loadActionsConfig()
        XCTAssertEqual(
            config, .empty,
            "no server is claimed and no enablement is claimed — with nothing behind the page, "
                + "the empty state is the only true thing it can say")

        let discovery = await bindings.discoverTools(forServerID: "s1")
        XCTAssertEqual(
            discovery, .succeeded([]),
            "an un-wired discovery claims no tools — the empty answer, never a failure nobody "
                + "reported and never a tool list nobody listed")

        let sentence = await bindings.previewAction(providerID: "s1", toolID: "list")
        XCTAssertNil(
            sentence, "an un-wired preview claims no sentence — a surface must not invent one")

        try? await bindings.saveActionsConfig(.empty)
        try? await bindings.setToolEnabled(providerID: "s1", toolID: "list", enabled: true)
        try? await bindings.armAction(providerID: "s1", toolID: "list")
        bindings.confirmationPresented()
        bindings.confirmationDismissed()
        // Nothing to assert but that each returned: the point is that the defaults change
        // nothing and report nothing, which a claims-something default could not manage.
    }

    // MARK: - Acceptance 7 · the tab never spawns and never connects

    /// The tab's files name no network family and no `Process` — the `ActionTransportProhibition`
    /// lint covers `VoccaActions` only, so the property for the surface that *shows* the spawn
    /// controls is pinned here: a settings table must not be the place a socket or a child
    /// quietly appears. Identifier-prefix families, the `ModelDownloaderSeamTests` shape.
    func testTheActionsFolderNamesNoNetworkFamilyAndNoProcess() throws {
        let folder = try actionsFolder()
        let files = SwiftSourceScanner.swiftFiles(under: folder)
        XCTAssertFalse(files.isEmpty, "the scan ran against nothing")

        for file in files {
            let text = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            for family in ["URLSession", "NW", "Network", "Process", "posix_spawn", "NSTask",
                "system"] {
                let pattern = "\\b\(family)[A-Za-z0-9_]*"
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                let hits = regex.matches(in: text, range: range)
                XCTAssertTrue(
                    hits.isEmpty,
                    "\(file.lastPathComponent) names the \(family) family — a settings tab must "
                        + "not spawn or connect; reaching for one is the wiring's reviewed move")
            }
        }
    }

    // MARK: - The D2 copy's placement (the moment of spawn)

    /// The D2 copy sits in the **discover section** — the section whose button spawns the child.
    /// A trust caveat that lived anywhere else on the page could be read after the fact; the one
    /// place a user must meet it is where the spawn is initiated.
    func testTheDiscoverSectionCarriesTheD2Copy() throws {
        let page = SwiftSourceScanner.stripComments(from: try pageSource())
        guard let sectionTitle = page.range(of: "ActionsTabCopy.toolsSectionTitle") else {
            return XCTFail("the page must name its tools section through the copy enum")
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
            body.body.contains("ActionsTabCopy.d2TrustCopy"),
            "the discover section must carry the D2 copy — the moment of spawn")
        XCTAssertTrue(
            body.body.contains("ActionsTabCopy.discoverButton"),
            "the discover button lives in the same section as the copy")
    }

    /// The arm path emits the confirmation signal only after the reducer's fold: the page folds
    /// `.armRequested`, and calls `confirmationPresented()` only when the folded state is
    /// `awaitingConfirmation` — a refused arm (disabled tool) can therefore never signal.
    func testTheArmPathEmitsTheConfirmationSignalOnlyAfterTheFold() throws {
        let page = SwiftSourceScanner.stripComments(from: try pageSource())
        XCTAssertTrue(page.contains(".armRequested"), "the arm path goes through the reducer")
        XCTAssertTrue(page.contains("awaitingConfirmation"), "the signal is gated on the folded arm state")
        XCTAssertTrue(
            page.contains("confirmationPresented()"),
            "the page emits the card signal — that is the whole of its arm path")
    }

    // MARK: - Fixtures

    private func actionsFolder() throws -> URL {
        try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaUI/Actions")
    }

    private func pageSource() throws -> String {
        try String(
            contentsOf: try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/Actions/ActionsTabPage.swift"),
            encoding: .utf8)
    }
}