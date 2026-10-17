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

/// **The audit tools' enablement surface** (`audit-enablement` spec acceptances A1-A7): the F-A
/// fix that gives `audit.count` (read-only) and `audit.clear` (destructive) an Actions-tab
/// enablement row, so enabling them is not a hand-edit of `action-config.json`.
///
/// The section mirrors the shipped **Shell commands** section exactly: a row source on the
/// action wiring (`listAuditTools`, a static list read — never a discovery, never a spawn), a
/// default-off reducer fold with the persisted enablement re-applied, and a section on
/// `ActionsTabPage`. The deliberate difference is **D-1**: the audit rows are **toggle-only** —
/// `audit.clear` is destructive and the tab is not a run surface, so the section renders the
/// enable toggle, the radius, the D2 copy and an explicit destructive warning on `audit.clear`,
/// and **no arm/preview affordance**.
@MainActor
final class AuditEnablementTests: XCTestCase {

    private static let providerID = AuditActionProvider.providerID
    private static let countToolID = AuditActionProvider.countToolID
    private static let clearToolID = AuditActionProvider.clearToolID

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-audit-enablement-\(UUID().uuidString)")
    }

    private func loaded(
        enablement: Set<ActionsToolKey> = []
    ) -> ActionsTabState {
        ActionsTabReducer.reduce(.initial, .configLoaded(servers: [], enablement: enablement))
    }

    private func tool(
        _ providerID: String, _ toolID: String, enabled: Bool = false,
        radius: ActionsTabRadius = .destructive
    ) -> ActionsToolRow {
        ActionsToolRow(
            providerID: providerID, toolID: toolID, summary: "does \(toolID)",
            radius: radius, isEnabled: enabled)
    }

    /// The composed action surface over real temp-directory stores and the real
    /// `AuditActionProvider` — the one place `IntentRoundTripHarness` builds a root, reused so
    /// this suite drives the shipped recipe rather than a second spelling of it.
    private func harness(
        directory: URL
    ) -> IntentRoundTripHarness<AuditActionProvider> {
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        return IntentRoundTripHarness(
            directory: directory,
            provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore)
    }

    // MARK: - A1 · the row source

    /// `listAuditTools` answers with exactly the provider's two tools, in the provider's order,
    /// with the radius read from `describe` — `audit.count` read-only, `audit.clear`
    /// destructive — and both **off** (absent is off, M7).
    func testListAuditToolsReturnsTheTwoProviderRowsWithRadiiFromDescribe() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = harness(directory: directory)

        let rows = await harness.surface.listAuditTools()

        XCTAssertEqual(
            rows.map(\.toolID), [Self.countToolID, Self.clearToolID],
            "the row source is the provider's own tool list, in its own order")
        XCTAssertEqual(
            rows.map(\.providerID), [Self.providerID, Self.providerID],
            "every audit row is keyed to the audit provider id — the id enablement rows name")
        XCTAssertEqual(
            rows.map(\.radius), [.readOnly, .destructive],
            "the radius is read from the provider's describe — audit.count read-only, "
                + "audit.clear destructive — never assumed")
        XCTAssertTrue(
            rows.allSatisfy { !$0.isEnabled },
            "both audit rows are off by default — absent is off (M7)")
    }

    /// **A6** — the row source names no new network or `Process` symbol: the `VoccaUI` family
    /// scan covers the Actions folder, so the property is pinned here for the wiring that reads
    /// the provider. The transport lint's permitted set stays two files; reaching for a
    /// transport to list two static tools would be a reviewed edit, not this.
    func testListAuditToolsNamesNoNetworkOrProcessFamily() throws {
        let url = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaBootstrap/ActionWiring.swift")
        let text = SwiftSourceScanner.stripComments(from: try String(contentsOf: url, encoding: .utf8))

        for family in ["URLSession", "NW", "Network", "Process", "posix_spawn", "NSTask",
            "system"] {
            let pattern = "\\b\(family)[A-Za-z0-9_]*"
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let hits = regex.matches(in: text, range: range)
            XCTAssertTrue(
                hits.isEmpty,
                "the row source names the \(family) family — listing two static audit tools "
                    + "must not spawn or connect")
        }
    }

    // MARK: - A1 · the section fold

    /// `auditToolsLoaded` sets `auditRows` and `isAuditToolsLoaded`, folds the rows **off by
    /// default**, and re-applies a persisted enablement row — exactly the shell fold.
    func testAuditToolsLoadedFoldsRowsOffByDefaultAndReappliesEnablement() {
        var state = loaded(
            enablement: [ActionsToolKey(providerID: Self.providerID, toolID: Self.clearToolID)])
        let rows = [
            tool(Self.providerID, Self.countToolID, enabled: true, radius: .readOnly),
            tool(Self.providerID, Self.clearToolID, enabled: true, radius: .destructive),
        ]

        state = ActionsTabReducer.reduce(state, .auditToolsLoaded(rows))

        XCTAssertTrue(state.isAuditToolsLoaded, "the section has looked")
        XCTAssertFalse(
            state.auditRows[0].isEnabled,
            "an audit row is off even when handed enabled — default off is the reducer's rule")
        XCTAssertTrue(
            state.auditRows[1].isEnabled,
            "a persisted enablement row re-applies at load — enabling must survive a relaunch")
    }

    /// An audit row's toggle flips the row **and** the persisted set together — the same
    /// enablement set, the same save the server rows use.
    func testAnAuditRowsToggleFlipsTheRowAndThePersistedSet() {
        var state = loaded()
        state = ActionsTabReducer.reduce(
            state,
            .auditToolsLoaded([tool(Self.providerID, Self.countToolID, radius: .readOnly)]))

        state = ActionsTabReducer.reduce(
            state,
            .toolEnabledChanged(providerID: Self.providerID, toolID: Self.countToolID, enabled: true))
        XCTAssertTrue(state.auditRows[0].isEnabled)
        XCTAssertTrue(
            state.enablement.contains(
                ActionsToolKey(providerID: Self.providerID, toolID: Self.countToolID)))

        state = ActionsTabReducer.reduce(
            state,
            .toolEnabledChanged(providerID: Self.providerID, toolID: Self.countToolID, enabled: false))
        XCTAssertFalse(state.auditRows[0].isEnabled)
        XCTAssertFalse(
            state.enablement.contains(
                ActionsToolKey(providerID: Self.providerID, toolID: Self.countToolID)))
    }

    // MARK: - A2 · the toggle writes the pair the resolver reads

    /// Toggling `audit.count` writes `{providerID: "dev.vocca.audit", toolID: "audit.count"}` to
    /// `action-config.json`, the store reflects it, and the next `listAuditTools` re-renders the
    /// row enabled — the pair the resolver's catalog gate reads.
    func testTogglingAnAuditToolWritesThePairToTheConfigStore() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = harness(directory: directory)

        try await harness.surface.setToolEnabled(Self.providerID, Self.countToolID, true)

        let config = await harness.configStore.load()
        XCTAssertTrue(
            config.enablement.contains(
                ActionConfigEnablementRow(providerID: Self.providerID, toolID: Self.countToolID)),
            "the toggle persists the exact (providerID, toolID) pair — the row the resolver "
                + "reads, never a hand-edit")
        let rows = await harness.surface.listAuditTools()
        XCTAssertEqual(
            rows.first(where: { $0.toolID == Self.countToolID })?.isEnabled, true,
            "the next read re-renders the enabled row — the store is the one source of truth")
    }

    // MARK: - A3 · an enabled audit tool resolves through the composed provider

    /// With the audit tool enabled, a phrase naming it resolves through the composed provider to
    /// the exact invocation — the catalog gate the enablement pair feeds.
    func testAnEnabledAuditToolResolvesThroughTheComposedProvider() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let phraseStore = IntentPhraseStore(
            directory: directory.appendingPathComponent("phrases"), log: { _ in })
        try await phraseStore.save(
            IntentPhraseFile(phrases: [
                PhraseIntentRow(
                    phrase: "how big is the log", providerID: Self.providerID,
                    toolID: Self.countToolID)
            ]))
        let auditStore = FileSystemActionAuditStore(
            directory: directory.appendingPathComponent("audit"))
        let harness = IntentRoundTripHarness(
            directory: directory,
            provider: AuditActionProvider(store: auditStore),
            auditStore: auditStore,
            resolverProvider: { PhraseIntentResolver(rows: await phraseStore.load().phrases) })

        try await harness.surface.setToolEnabled(Self.providerID, Self.countToolID, true)
        let resolution = await harness.wiring.resolve("How big is the log?")

        XCTAssertEqual(
            toolCall(in: resolution),
            ActionInvocation(providerID: Self.providerID, toolID: Self.countToolID),
            "enabling the audit tool puts its pair in the resolver's catalog — the phrase "
                + "resolves through the composed provider")
    }

    // MARK: - A4 · the composed default is unchanged

    /// The composed default enables nothing and renders both audit rows off — the audit tools
    /// are opt-in, so the shipped configuration's facts (`spawnsSubprocess=false`, the audit
    /// posture) are untouched.
    func testTheComposedDefaultLeavesAuditEnablementEmpty() async {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let harness = harness(directory: directory)

        let config = await harness.surface.loadConfig()
        XCTAssertTrue(
            config.enablement.isEmpty, "nothing is enabled out of the box")
        let rows = await harness.surface.listAuditTools()
        XCTAssertTrue(
            rows.allSatisfy { !$0.isEnabled },
            "both audit rows render off in the composed default — opt-in, never enabled on "
                + "arrival")
        XCTAssertFalse(
            harness.surface.spawnsSubprocess,
            "listing the audit tools spawns nothing — the composed default cannot create a child")
    }

    // MARK: - A5 · the copy and its placement

    /// The audit section's D2 copy and the `audit.clear` destructive warning sit **in the audit
    /// section** — the moment of enable — the shell/agent placement precedent.
    func testTheAuditSectionCarriesTheD2CopyAndTheDestructiveWarning() throws {
        let page = SwiftSourceScanner.stripComments(from: try pageSource())
        guard let sectionTitle = page.range(of: "ActionsTabCopy.auditSectionTitle") else {
            return XCTFail("the page must name its audit section through the copy enum")
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
            body.body.contains("ActionsTabCopy.auditD2TrustCopy"),
            "the audit section must carry the D2 copy — the moment of enable")
        XCTAssertTrue(
            body.body.contains("auditToolRow("),
            "the audit section renders its rows through the audit renderer, so the warning is "
                + "reached from the section exactly as the shell/agent sections reach their copy")
        let renderer = try XCTUnwrap(
            functionBody(named: "auditToolRow", in: page),
            "the audit renderer must exist for the section to render its rows")
        XCTAssertTrue(
            renderer.contains("ActionsTabCopy.auditClearDestructiveWarning"),
            "the audit.clear destructive warning must live on the audit row renderer")
        XCTAssertTrue(
            renderer.contains(".destructive"),
            "the warning is gated on the destructive radius the provider's describe reported")
    }

    /// **D-1**: the audit section's rows offer **no arm/preview affordance** — `audit.clear` is
    /// destructive and the tab is not a run surface. The scan is not vacuous: the shared
    /// `toolRow` still carries the affordances for every other provider.
    func testTheAuditRowsOfferNoArmAffordances() throws {
        let page = SwiftSourceScanner.stripComments(from: try pageSource())
        guard let sectionTitle = page.range(of: "ActionsTabCopy.auditSectionTitle") else {
            return XCTFail("the page must name its audit section through the copy enum")
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
        XCTAssertFalse(
            body.body.contains("ActionsTabCopy.invokeButton"),
            "the audit section must not offer Invoke — audit.clear cannot be armed from the tab")
        XCTAssertFalse(
            body.body.contains("ActionsTabCopy.previewButton"),
            "the audit section must not offer Preview — the section is toggle-only (D-1)")
        XCTAssertTrue(
            body.body.contains("auditToolRow("),
            "the section renders its own toggle-only row — the affordances are omitted by "
                + "construction, not by a condition that could drift")
    }

    /// The audit D2 copy, exact-in-spirit of the shell/agent copies: the audit tools act on the
    /// local audit log, and clearing it cannot be undone.
    func testTheAuditD2TrustCopyIsPinned() {
        XCTAssertEqual(
            ActionsTabCopy.auditD2TrustCopy,
            "The audit tools act on your local action audit log. Vocca cannot restore it "
                + "once cleared.")
    }

    /// The `audit.clear` destructive warning, pinned: it permanently deletes every entry.
    func testTheAuditClearDestructiveWarningIsPinned() {
        XCTAssertEqual(
            ActionsTabCopy.auditClearDestructiveWarning,
            "Warning: audit.clear permanently deletes every entry in the audit log. This "
                + "cannot be undone.")
    }

    // MARK: - A7 · the binding default claims nothing

    /// The `loadAuditTools` default claims nothing: an un-wired surface renders no audit rows,
    /// which is the only true thing it can say before the wiring fills the slot.
    func testTheLoadAuditToolsBindingDefaultClaimsNothing() async {
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

        let rows = await bindings.loadAuditTools()
        XCTAssertTrue(
            rows.isEmpty,
            "an un-wired audit leg claims no rows — a surface must not invent tools it cannot "
                + "name")
    }

    // MARK: - Helpers

    private func toolCall(in resolution: IntentResolution) -> ActionInvocation? {
        if case .toolCall(let invocation) = resolution { return invocation }
        return nil
    }

    private func pageSource() throws -> String {
        try String(
            contentsOf: try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/Actions/ActionsTabPage.swift"),
            encoding: .utf8)
    }

    /// The braced body of the `func <name>` declaration in `source`, comments already stripped
    /// — `nil` when the declaration or its balanced body cannot be found.
    private func functionBody(named name: String, in source: String) -> String? {
        guard let declaration = source.range(of: "func \(name)") else { return nil }
        let after = source[declaration.upperBound...]
        guard let brace = after.firstIndex(of: "{") else { return nil }
        let characters = Array(after)
        let offset = after.distance(from: after.startIndex, to: brace)
        return SwiftSourceScanner.bracedBody(in: characters, openingBraceIndex: offset)?.body
    }
}
