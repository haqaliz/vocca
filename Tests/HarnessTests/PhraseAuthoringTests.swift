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
import Synchronization
import VoccaActions
import VoccaBootstrap
import VoccaCore
import VoccaUI
import XCTest

/// **The phrase authoring surface's acceptances** (`phrase-authoring` spec A1-A10).
///
/// Written red, before any of the surface exists. The section is the first in-app authoring
/// path for `intent-phrases.json`: rows are added/edited/removed through the reducer, the
/// `keywordFallback` switch rides the draft, and the whole table is written through the real
/// `IntentPhraseStore` — never on open, never on a no-op close, and never over a hand edit
/// (the snapshot guard).
///
/// The three pins this file owns:
/// - **the two spellings agree** — `ActionsPhraseRow`/`ActionsPhraseFile` mirror
///   `PhraseIntentRow`/`IntentPhraseFile`, and the surface's own normalization/caps agree with
///   the resolver's and the store's (the `AgentAuthoringSurfaceTests` precedent);
/// - **the boundary holds** — no `VoccaUI` file names the confined intent types;
/// - **the write is explicit** — a load writes nothing, a changed save writes the new table,
///   and a save over a hand edit refuses with the conflict copy and writes nothing.
final class PhraseAuthoringTests: XCTestCase {

    // MARK: - Fixtures

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-phrase-authoring-\(UUID().uuidString)")
    }

    private static let fileName = "intent-phrases.json"

    private func bytes(in directory: URL) -> Data? {
        FileManager.default.contents(
            atPath: directory.appendingPathComponent(Self.fileName).path)
    }

    private func row(
        _ phrase: String, providerID: String = "dev.vocca.audit", toolID: String = "audit.count"
    ) -> ActionsPhraseRow {
        ActionsPhraseRow(phrase: phrase, providerID: providerID, toolID: toolID)
    }

    /// Folds a valid add of `phrase` → `providerID/toolID` into `state`, leaving the editor
    /// closed on success.
    private func adding(
        _ state: ActionsTabState, phrase: String, providerID: String = "dev.vocca.audit",
        toolID: String = "audit.count"
    ) -> ActionsTabState {
        var next = ActionsTabReducer.reduce(state, .phraseEditorOpened)
        next = ActionsTabReducer.reduce(next, .phraseDraftFieldEdited(.phrase, phrase))
        next = ActionsTabReducer.reduce(next, .phraseDraftFieldEdited(.providerID, providerID))
        next = ActionsTabReducer.reduce(next, .phraseDraftFieldEdited(.toolID, toolID))
        return ActionsTabReducer.reduce(next, .phraseSaveRequested)
    }

    // MARK: - A8 · the boundary and the agreement

    /// **The time the two spellings agree.** `VoccaUI` cannot name the core/action-layer types
    /// (the module boundary and the intent-seam lint), so the surface carries a second spelling
    /// of the row, the file, the caps and the one normalization. This pin is what keeps that
    /// second spelling the same fact: a retune on either side fails here, loudly.
    func testTheSurfaceSpellingAgreesWithTheIntentLayer() {
        // The row's three fields, 1:1.
        let surfaceRow = ActionsPhraseRow(
            phrase: "clear the audit log", providerID: "dev.vocca.audit", toolID: "audit.clear")
        let coreRow = PhraseIntentRow(
            phrase: "clear the audit log", providerID: "dev.vocca.audit", toolID: "audit.clear")
        XCTAssertEqual(surfaceRow.phrase, coreRow.phrase)
        XCTAssertEqual(surfaceRow.providerID, coreRow.providerID)
        XCTAssertEqual(surfaceRow.toolID, coreRow.toolID)

        // The file's version and switch.
        XCTAssertEqual(ActionsPhraseFile.empty.version, IntentPhraseFile.empty.version)
        XCTAssertEqual(ActionsPhraseFile.empty.keywordFallback, IntentPhraseFile.empty.keywordFallback)

        // The caps, mirrored from the store.
        XCTAssertEqual(
            PhraseAuthoringConstants.maximumPhraseLength, IntentPhraseStore.maximumPhraseLength)
        XCTAssertEqual(PhraseAuthoringConstants.maximumIDLength, IntentPhraseStore.maximumIDLength)

        // The provider ids the editor refuses and hints.
        XCTAssertEqual(PhraseAuthoringConstants.shellProviderID, ShellProvider.providerID)
        XCTAssertEqual(PhraseAuthoringConstants.auditProviderID, AuditActionProvider.providerID)

        // The one normalization, pinned against the resolver's own over a corpus.
        let corpus = [
            "Clear the audit-log!", "  count   the audit log  ", "!!!", "", "A--b  C!",
            "Already  normalized", "café au lait", "123 456",
        ]
        for phrase in corpus {
            XCTAssertEqual(
                PhraseAuthoringConstants.normalized(phrase), PhraseIntentResolver.normalized(phrase),
                "the surface's normalization must agree with the resolver's for '\(phrase)'")
        }
    }

    /// **The root mapping round-trips losslessly.** The tab's file maps to the store's at the
    /// composition root (`AppBootstrap.phraseFile(from:)`, the `agentFile(from:)` precedent),
    /// and back for load — the fields the UI carries are exactly the fields the file holds.
    func testTheRootMappingRoundTripsLosslessly() throws {
        let surface = ActionsPhraseFile(
            version: 1,
            phrases: [
                ActionsPhraseRow(
                    phrase: "clear the audit log", providerID: "dev.vocca.audit",
                    toolID: "audit.clear"),
                ActionsPhraseRow(
                    phrase: "run my agent", providerID: "vocca.agent", toolID: "claude"),
            ],
            keywordFallback: true)

        let core = try AppBootstrap.phraseFile(from: surface)
        XCTAssertEqual(core.version, surface.version)
        XCTAssertEqual(core.keywordFallback, surface.keywordFallback)
        XCTAssertEqual(core.phrases.map(\.phrase), surface.phrases.map(\.phrase))
        XCTAssertEqual(core.phrases.map(\.providerID), surface.phrases.map(\.providerID))
        XCTAssertEqual(core.phrases.map(\.toolID), surface.phrases.map(\.toolID))

        XCTAssertEqual(AppBootstrap.actionsPhraseFile(from: core), surface)
    }

    /// **The boundary as a scan.** No `VoccaUI` source file names the confined intent
    /// types — the surface consumes the root's mapped plain types and nothing else.
    func testNoVoccaUIFileNamesTheConfinedIntentTypes() throws {
        let root = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources/VoccaUI")
        let files = SwiftSourceScanner.swiftFiles(under: root)
        XCTAssertFalse(files.isEmpty, "the scan ran against nothing")

        for file in files {
            let code = SwiftSourceScanner.stripComments(
                from: try String(contentsOf: file, encoding: .utf8))
            for family in ["PhraseIntentRow", "IntentPhraseFile", "IntentPhraseStore"] {
                let pattern = "\\b\(family)[A-Za-z0-9_]*"
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(code.startIndex..<code.endIndex, in: code)
                XCTAssertTrue(
                    regex.matches(in: code, range: range).isEmpty,
                    "\(file.lastPathComponent) names \(family) — VoccaUI may not (the "
                        + "module boundary and the intent-seam lint)")
            }
        }
    }

    // MARK: - A1 · the round trip resolves on the next turn

    /// **Write through the real store, resolve on the next call.** The authoring fold commits
    /// the row, the root mapping translates it, the real `IntentPhraseStore` persists it over a
    /// real temp directory, and the **per-turn provider** — the same closure the voice leg reads
    /// — resolves the phrase on its next call. No relaunch, no recomposition.
    @MainActor
    func testASavedPhraseResolvesOnTheNextTurnWithoutRecomposition() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IntentPhraseStore(directory: directory, log: { _ in })
        let provider = AppBootstrap.composeIntentResolverProvider(store: store)

        // Before any save, a phrase resolves nothing.
        let before = await provider()
        XCTAssertEqual(
            before.resolve(
                "count the audit log",
                against: [
                    ToolReference(
                        providerID: "dev.vocca.audit", toolID: "audit.count", displayName: "")
                ]),
            .none,
            "an empty table resolves nothing")

        var state = ActionsTabState.initial
        state = adding(state, phrase: "count the audit log")
        XCTAssertFalse(state.isPhraseEditorOpen, "a valid row closes the editor")

        // The shipped save path: the tab's file, mapped at the root, persisted by the store.
        let draft = ActionsPhraseFile(phrases: state.phraseRows)
        try await store.save(AppBootstrap.phraseFile(from: draft))

        let after = await provider()
        let resolution = after.resolve(
            "count the audit log",
            against: [
                ToolReference(
                    providerID: "dev.vocca.audit", toolID: "audit.count", displayName: "")
            ])
        guard case .toolCall(let invocation) = resolution else {
            return XCTFail("a saved phrase must resolve on the next turn — got \(resolution)")
        }
        XCTAssertEqual(invocation.providerID, "dev.vocca.audit")
        XCTAssertEqual(invocation.toolID, "audit.count")
    }

    // MARK: - A2 · byte preservation (no write without an explicit changed save)

    /// **Opening and closing with no change writes nothing.** The load path reads; the store's
    /// `save` is never called, so the recorder observes zero writes and the user's bytes are
    /// unchanged.
    func testLoadingAndClosingWithoutChangesWritesNothing() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = #"{"phrases":[{"phrase":"clear the audit log","providerID":"dev.vocca.audit","toolID":"audit.clear"}],"version":1}"#
        try Data(raw.utf8).write(to: directory.appendingPathComponent(Self.fileName))
        let before = bytes(in: directory)

        let recorder = RecordingPhraseFileSystem()
        let store = IntentPhraseStore(directory: directory, fileSystem: recorder, log: { _ in })
        let loaded = await store.load()
        var state = ActionsTabReducer.reduce(
            .initial, .phrasesConfigLoaded(AppBootstrap.actionsPhraseFile(from: loaded)))
        XCTAssertTrue(state.isPhrasesLoaded)
        XCTAssertEqual(state.phraseRows.count, 1)

        // Closing the section folds nothing that writes.
        state = ActionsTabReducer.reduce(state, .phraseEditCancelled)
        _ = state

        XCTAssertEqual(recorder.writeCount, 0, "a load must never write")
        XCTAssertEqual(recorder.moveCount, 0, "a load must never rename a temp file over the table")
        XCTAssertEqual(bytes(in: directory), before, "the user's bytes are untouched")
    }

    // MARK: - A3 · the keywordFallback switch

    /// **A hand-set `keywordFallback: true` survives a row edit; the toggle writes the new
    /// value.** The switch rides the draft, so a save that changes a row preserves the value the
    /// user set by hand — and flipping the toggle is itself a change that persists.
    func testAHandSetKeywordFallbackSurvivesARowEditAndTheToggleWritesTheNewValue() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IntentPhraseStore(directory: directory, log: { _ in })

        // A hand-edited file with the switch on.
        let handSet = IntentPhraseFile(
            phrases: [
                PhraseIntentRow(
                    phrase: "clear the audit log", providerID: "dev.vocca.audit",
                    toolID: "audit.clear")
            ],
            keywordFallback: true)
        try await store.save(handSet)

        let loaded = await store.load()
        var state = ActionsTabReducer.reduce(
            .initial, .phrasesConfigLoaded(AppBootstrap.actionsPhraseFile(from: loaded)))
        XCTAssertTrue(state.keywordFallbackDraft, "the switch rides the draft from the file")

        // Edit the row and save; the switch is carried unchanged.
        state = ActionsTabReducer.reduce(state, .phraseEditStarted(phrase: "clear the audit log"))
        state = ActionsTabReducer.reduce(
            state, .phraseDraftFieldEdited(.phrase, "clear my audit log"))
        state = ActionsTabReducer.reduce(state, .phraseSaveRequested)
        let afterEdit = ActionsPhraseFile(
            version: state.phraseVersion, phrases: state.phraseRows,
            keywordFallback: state.keywordFallbackDraft)
        try await store.save(
            AppBootstrap.phraseFile(from: afterEdit),
            ifUnchangedFrom: AppBootstrap.phraseFile(from: state.phraseSnapshot!))
        state = ActionsTabReducer.reduce(state, .phrasesSaved(afterEdit))
        var reloaded = await store.load()
        XCTAssertTrue(reloaded.keywordFallback, "a row edit must preserve the hand-set switch")
        XCTAssertEqual(reloaded.phrases.map(\.phrase), ["clear my audit log"])

        // Flip the switch off; the toggle writes the new value.
        state = ActionsTabReducer.reduce(state, .keywordFallbackToggled(false))
        XCTAssertFalse(state.keywordFallbackDraft)
        let toggled = ActionsPhraseFile(
            version: state.phraseVersion, phrases: state.phraseRows,
            keywordFallback: state.keywordFallbackDraft)
        try await store.save(
            AppBootstrap.phraseFile(from: toggled),
            ifUnchangedFrom: AppBootstrap.phraseFile(from: state.phraseSnapshot!))
        reloaded = await store.load()
        XCTAssertFalse(reloaded.keywordFallback, "the toggle's new value is written")
    }

    // MARK: - A4 · the shell refusal

    /// **A `dev.vocca.shell` target is refused in the editor, loudly, with the draft kept.**
    /// The row never reaches the store from the surface — and the store refuses it too (the
    /// defense in depth), so a shell phrase cannot be authored either way.
    func testAShellTargetIsRefusedInTheEditorLoudly() {
        var state = ActionsTabState.initial
        state = ActionsTabReducer.reduce(state, .phraseEditorOpened)
        state = ActionsTabReducer.reduce(
            state, .phraseDraftFieldEdited(.phrase, "empty my downloads"))
        state = ActionsTabReducer.reduce(
            state, .phraseDraftFieldEdited(.providerID, PhraseAuthoringConstants.shellProviderID))
        state = ActionsTabReducer.reduce(state, .phraseDraftFieldEdited(.toolID, "empty"))

        let folded = ActionsTabReducer.reduce(state, .phraseSaveRequested)

        XCTAssertTrue(folded.isPhraseEditorOpen, "a refused save keeps the editor open")
        XCTAssertTrue(folded.phraseRows.isEmpty, "no row is committed")
        let error = folded.saveError ?? ""
        XCTAssertTrue(error.hasPrefix("Save refused:"), "the refusal is loud: \(error)")
        XCTAssertTrue(
            error.lowercased().contains("shell"),
            "the refusal says why — a shell command cannot be reached by voice: \(error)")
    }

    // MARK: - A5 · the duplicate / empty / over-length refusals

    /// **Duplicate (normalized), empty, and over-length rows are refused at Save, loudly, with
    /// the draft kept** — mirrored from the store's load rules so the editor and the file agree.
    func testDuplicateEmptyAndOverLengthRowsAreRefusedAtSaveLoudly() {
        // A duplicate of a committed row.
        var state = adding(ActionsTabState.initial, phrase: "clear the audit log")
        XCTAssertEqual(state.phraseRows.count, 1)
        state = ActionsTabReducer.reduce(state, .phraseEditorOpened)
        state = ActionsTabReducer.reduce(
            state, .phraseDraftFieldEdited(.phrase, "Clear the audit-log!"))
        state = ActionsTabReducer.reduce(
            state, .phraseDraftFieldEdited(.providerID, "dev.vocca.audit"))
        state = ActionsTabReducer.reduce(state, .phraseDraftFieldEdited(.toolID, "audit.count"))
        var folded = ActionsTabReducer.reduce(state, .phraseSaveRequested)
        XCTAssertTrue(folded.isPhraseEditorOpen, "a duplicate is refused")
        XCTAssertEqual(folded.phraseRows.count, 1, "no duplicate row is committed")
        XCTAssertTrue((folded.saveError ?? "").hasPrefix("Save refused:"))

        // An empty phrase.
        folded = adding(ActionsTabState.initial, phrase: "!!!")
        XCTAssertTrue(folded.isPhraseEditorOpen, "a phrase with no words is refused")
        XCTAssertTrue(folded.phraseRows.isEmpty, "nothing is committed")
        XCTAssertTrue((folded.saveError ?? "").hasPrefix("Save refused:"))

        // An empty target.
        var emptyTarget = ActionsTabReducer.reduce(
            ActionsTabState.initial, .phraseEditorOpened)
        emptyTarget = ActionsTabReducer.reduce(
            emptyTarget, .phraseDraftFieldEdited(.phrase, "a real phrase"))
        emptyTarget = ActionsTabReducer.reduce(emptyTarget, .phraseSaveRequested)
        XCTAssertTrue(emptyTarget.isPhraseEditorOpen, "an empty target is refused")
        XCTAssertTrue((emptyTarget.saveError ?? "").hasPrefix("Save refused:"))

        // An over-length phrase.
        let tooLong = String(repeating: "a", count: PhraseAuthoringConstants.maximumPhraseLength + 1)
        let long = adding(ActionsTabState.initial, phrase: tooLong)
        XCTAssertTrue(long.isPhraseEditorOpen, "an over-length phrase is refused")
        XCTAssertTrue(long.phraseRows.isEmpty)
        XCTAssertTrue((long.saveError ?? "").hasPrefix("Save refused:"))
    }

    // MARK: - A6 · edit keeps identity, remove deletes

    /// **An in-place edit keeps the row's identity (no duplicate on rename); remove deletes the
    /// row from the draft.** Edit locates the row by its current phrase and replaces it in
    /// place — never a delete-plus-add.
    func testAnEditKeepsTheRowIdentityAndRemoveDeletesIt() {
        var state = adding(ActionsTabState.initial, phrase: "clear the audit log")
        state = adding(state, phrase: "count the audit log", toolID: "audit.count")
        XCTAssertEqual(state.phraseRows.count, 2)

        state = ActionsTabReducer.reduce(state, .phraseEditStarted(phrase: "clear the audit log"))
        XCTAssertEqual(state.phrasePhraseDraft, "clear the audit log", "the editor opens on the row")
        XCTAssertEqual(state.editingPhraseID, "clear the audit log")
        state = ActionsTabReducer.reduce(
            state, .phraseDraftFieldEdited(.phrase, "clear my audit log"))
        state = ActionsTabReducer.reduce(state, .phraseSaveRequested)

        XCTAssertEqual(state.phraseRows.count, 2, "an edit never adds a row")
        XCTAssertEqual(
            state.phraseRows.map(\.phrase), ["clear my audit log", "count the audit log"],
            "the edit replaces the row in place, keeping its identity")

        state = ActionsTabReducer.reduce(state, .phraseRemoved(phrase: "clear my audit log"))
        XCTAssertEqual(state.phraseRows.map(\.phrase), ["count the audit log"])
    }

    /// Removing the last phrase leaves an empty valid table — not an absent row set that reads
    /// as "not loaded": the draft still builds a valid file with `phrases: []`.
    func testRemovingTheLastPhraseLeavesAnEmptyTable() {
        var state = adding(ActionsTabState.initial, phrase: "clear the audit log")
        state = ActionsTabReducer.reduce(state, .phraseRemoved(phrase: "clear the audit log"))
        XCTAssertTrue(state.phraseRows.isEmpty)
        let file = ActionsPhraseFile(version: state.phraseVersion, phrases: state.phraseRows)
        XCTAssertEqual(file.phrases, [], "no rows — a valid empty table, never an absent one")
    }

    // MARK: - A7 · save failure and the conflict guard

    /// **A failed save keeps the draft; a successful save clears it; a conflict surfaces the
    /// conflict copy and writes nothing.** The editor's fold commits the row and closes the
    /// editor, but the drafts are held until a save that reached the file.
    func testSaveFailureKeepsTheDraftAndSuccessClearsIt() {
        var state = ActionsTabReducer.reduce(ActionsTabState.initial, .phraseEditorOpened)
        state = ActionsTabReducer.reduce(state, .phraseDraftFieldEdited(.phrase, "a phrase"))
        state = ActionsTabReducer.reduce(
            state, .phraseDraftFieldEdited(.providerID, "dev.vocca.audit"))
        state = ActionsTabReducer.reduce(state, .phraseDraftFieldEdited(.toolID, "audit.count"))
        state = ActionsTabReducer.reduce(state, .phraseSaveRequested)
        XCTAssertEqual(state.phraseRows.count, 1)
        XCTAssertEqual(state.phrasePhraseDraft, "a phrase", "the committed draft is still held")

        state = ActionsTabReducer.reduce(state, .saveFailed("disk full"))
        XCTAssertEqual(state.saveError, "disk full")
        XCTAssertEqual(state.phrasePhraseDraft, "a phrase", "a failed save keeps the draft")

        state = ActionsTabReducer.reduce(
            state,
            .phrasesSaved(
                ActionsPhraseFile(phrases: state.phraseRows)))
        XCTAssertNil(state.saveError)
        XCTAssertEqual(state.phrasePhraseDraft, "", "a successful save clears the draft")
        XCTAssertEqual(state.phraseProviderIDDraft, "")
        XCTAssertEqual(state.phraseToolIDDraft, "")
    }

    /// **A conflict surfaces the conflict copy and advances nothing.** The snapshot the store
    /// compared against no longer matches disk, so the page folds the conflict copy (not a
    /// generic failure) and the draft is kept.
    func testAConflictSurfacesTheConflictCopyAndKeepsTheDraft() {
        var state = ActionsTabReducer.reduce(ActionsTabState.initial, .phraseEditorOpened)
        state = ActionsTabReducer.reduce(state, .phraseDraftFieldEdited(.phrase, "a phrase"))
        state = ActionsTabReducer.reduce(
            state, .phraseDraftFieldEdited(.providerID, "dev.vocca.audit"))
        state = ActionsTabReducer.reduce(state, .phraseDraftFieldEdited(.toolID, "audit.count"))
        state = ActionsTabReducer.reduce(state, .phraseSaveRequested)

        state = ActionsTabReducer.reduce(state, .saveFailed(ActionsTabCopy.phraseConflict))

        XCTAssertEqual(state.saveError, ActionsTabCopy.phraseConflict)
        XCTAssertTrue(
            ActionsTabCopy.phraseConflict.contains("changed on disk"),
            "the conflict copy says the file changed on disk")
    }

    // MARK: - The store-level conflict, through the real save path

    /// **A hand edit between open and save refuses the write and leaves the bytes untouched.**
    /// The section saves with the snapshot it loaded; a committed file that changed since then
    /// is a conflict — the store's guard, reached through the same mapping the binding uses.
    func testSaveIfUnchangedRefusesWhenAHandEditLanded() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IntentPhraseStore(directory: directory, log: { _ in })

        let opened = ActionsPhraseFile(
            phrases: [row("clear the audit log", toolID: "audit.clear")])
        try await store.save(AppBootstrap.phraseFile(from: opened))

        // The user reads the section, then hand-edits the file before saving.
        let snapshot = ActionsPhraseFile(phrases: opened.phrases)
        let handEdited = IntentPhraseFile(
            phrases: [
                PhraseIntentRow(
                    phrase: "someone else's phrase", providerID: "dev.vocca.audit",
                    toolID: "audit.count")
            ])
        try await store.save(handEdited)
        let before = bytes(in: directory)

        var thrown: IntentPhraseStoreError?
        do {
            try await store.save(
                AppBootstrap.phraseFile(
                    from: ActionsPhraseFile(phrases: opened.phrases + [row("count the log")])),
                ifUnchangedFrom: AppBootstrap.phraseFile(from: snapshot))
        } catch let error as IntentPhraseStoreError {
            thrown = error
        }
        XCTAssertEqual(thrown, .fileChangedOnDisk, "the snapshot guard refuses the write")
        XCTAssertEqual(bytes(in: directory), before, "nothing was written over the hand edit")
    }

    // MARK: - The section's shape in the page

    /// **The Phrases section carries the editor, the toggle and the row actions** — the section
    /// body renders rows with their editor and the add affordance, and the gestures all fold
    /// through the reducer.
    func testThePhrasesSectionCarriesTheEditorTheToggleAndTheRowActions() throws {
        let page = SwiftSourceScanner.stripComments(from: try pageSource())
        guard let sectionTitle = page.range(of: "ActionsTabCopy.phrasesSectionTitle") else {
            return XCTFail("the page must name its phrases section through the copy enum")
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
        XCTAssertTrue(body.body.contains("phraseRow("), "the phrase rows render in the section")
        XCTAssertTrue(body.body.contains("phraseEditor("), "the editor renders in the section")
        XCTAssertTrue(
            body.body.contains("addPhraseForm()"), "the add affordance renders in the section")
        XCTAssertTrue(
            body.body.contains("keywordFallbackToggled"),
            "the keywordFallback toggle lives in the section and folds through the reducer")
        XCTAssertTrue(
            body.body.contains("ActionsTabCopy.phraseKeywordFallbackLabel"),
            "the toggle carries its label copy")

        XCTAssertTrue(
            page.contains(".phraseEditorOpened"),
            "the add affordance opens the editor through the reducer")
        XCTAssertTrue(
            page.contains(".phraseSaveRequested"),
            "the editor's Save validates and folds through the reducer")
        XCTAssertTrue(page.contains(".phraseDraftFieldEdited"), "every field edit folds")
        XCTAssertTrue(page.contains(".phraseEditStarted"), "a row's Edit opens through the reducer")
        XCTAssertTrue(page.contains(".phraseRemoved"), "a row's Remove folds through the reducer")
        XCTAssertTrue(
            page.contains("ActionsTabCopy.phraseAddButton"),
            "the add affordance's copy is on the page")
    }

    // MARK: - The copy pins

    /// The phrases copy, verbatim: the section, the empty state, the field labels, the toggle
    /// and the loud refusals.
    func testThePhraseCopyIsPinned() {
        XCTAssertEqual(ActionsTabCopy.phrasesSectionTitle, "Phrases")
        XCTAssertEqual(ActionsTabCopy.phraseAddButton, "Add phrase")
        XCTAssertEqual(ActionsTabCopy.phraseFieldLabel, "Phrase")
        XCTAssertEqual(ActionsTabCopy.phraseProviderLabel, "Provider")
        XCTAssertEqual(ActionsTabCopy.phraseToolLabel, "Tool")
        XCTAssertEqual(ActionsTabCopy.phraseKeywordFallbackLabel, "Keyword fallback")

        XCTAssertTrue(
            ActionsTabCopy.phraseEmptyPhrases.hasPrefix("No phrases"),
            "the empty state is honest about why it is empty")

        XCTAssertTrue(ActionsTabCopy.phraseInvalidRow(ActionsTabCopy.phraseDuplicateReason)
            .hasPrefix("Save refused:"))
        XCTAssertTrue(
            ActionsTabCopy.phraseShellTargetReason.lowercased().contains("shell"),
            "the shell refusal names what it refuses")
        XCTAssertEqual(
            ActionsTabCopy.phraseConflict, "the file changed on disk — reopen the section")
    }

    // MARK: - The bindings claim nothing bare

    /// The C12 convention: the two phrase closures default — an empty file renders the honest
    /// empty state and a save that goes nowhere never claims success.
    @MainActor
    func testThePhraseBindingDefaultsClaimNothing() async {
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

        let loaded = await bindings.loadPhrases()
        XCTAssertEqual(loaded, .empty, "no phrases are claimed — the honest empty state")

        let outcome = await bindings.savePhrases(.empty, .empty)
        XCTAssertNotEqual(
            outcome, .saved,
            "an un-wired save must never claim success — that would tell a user their phrase "
                + "was stored when nothing is behind the binding")
    }

    // MARK: - Fixtures

    private func pageSource() throws -> String {
        try String(
            contentsOf: try PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/Actions/ActionsTabPage.swift"),
            encoding: .utf8)
    }
}

// MARK: - Test doubles

/// A filesystem that records the writes it sees, so "a load never writes" is asserted rather
/// than hoped. Reads and existence delegate to the real filesystem, so the load returns the
/// pre-written table.
private final class RecordingPhraseFileSystem: ActionConfigFileSystem {
    private let backing = DefaultActionConfigFileSystem()
    private let writes = Mutex(0)
    private let moves = Mutex(0)

    var writeCount: Int { writes.withLock { $0 } }
    var moveCount: Int { moves.withLock { $0 } }

    func createDirectory(at url: URL) async throws { try await backing.createDirectory(at: url) }
    func write(_ data: Data, to url: URL) async throws {
        writes.withLock { $0 += 1 }
        try await backing.write(data, to: url)
    }
    func moveItem(at source: URL, to destination: URL) async throws {
        moves.withLock { $0 += 1 }
        try await backing.moveItem(at: source, to: destination)
    }
    func read(_ url: URL) async -> Data? { await backing.read(url) }
    func fileExists(atPath path: String) async -> Bool { await backing.fileExists(atPath: path) }
}
