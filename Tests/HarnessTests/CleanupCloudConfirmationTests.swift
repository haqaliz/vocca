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

/// **R3 — the one-time confirmation before text may leave the Mac.**
///
/// `PRODUCT_SPEC.md:273`: *"Selecting the cloud rung shows a one-time confirmation naming exactly
/// what gets sent. Not a checkbox buried in a paragraph — a dialog the user has to read."*
///
/// This is the aspect's must-have, never traded away, and it is the surface `ROADMAP.md`
/// principle 2 says must survive an audit of the actual code paths — a regression here is
/// positioning-fatal, not a UI bug. So the decisions are pure and every one of them runs here:
/// what is written and when, what a decline leaves behind, and what "one-time" costs.
final class CleanupCloudConfirmationTests: XCTestCase {

    // MARK: - Selecting the cloud rung does not persist until confirmed

    /// **Picking the cloud rung asks first.** The plan is a confirmation, not a write — nothing
    /// reaches `cleanup-config.json` on the click.
    func testPickingTheCloudRungPlansAConfirmationRatherThanAWrite() {
        let state = Self.loaded(provider: .rules)

        guard case .confirm(let kind) = CleanupTabReducer.plan(state, picking: .byok) else {
            return XCTFail("the cloud rung must be confirmed before anything is written")
        }
        XCTAssertEqual(kind, .byok)
    }

    /// **The two local rungs are never confirmed.** A dialog in front of a choice that sends
    /// nothing anywhere is a dialog people learn to dismiss without reading, which is how the one
    /// that matters stops working. Ollama runs on the machine (`PRODUCT_SPEC.md:267`), so it is a
    /// local rung for this purpose too.
    func testTheLocalRungsAreNeverConfirmed() {
        let state = Self.loaded(provider: .byok)

        guard case .write = CleanupTabReducer.plan(state, picking: .rules) else {
            return XCTFail("returning to the zero-network default is never gated on a dialog")
        }
        guard case .write = CleanupTabReducer.plan(state, picking: .ollama) else {
            return XCTFail("Ollama is on-device; nothing leaves, so nothing is confirmed")
        }
    }

    /// **An unconfigured cloud rung is refused before it is confirmed.**
    ///
    /// Ordering, and it is a real decision: confirming egress to an endpoint the user has not
    /// typed would ask them to approve sending text to nowhere, and would then fail the write
    /// anyway. The refusal is the more useful answer and comes first.
    func testAnUnconfiguredCloudRungIsRefusedBeforeItIsConfirmed() {
        var state = Self.loaded(provider: .rules)
        state = CleanupTabReducer.reduce(state, .endpointEdited(.byok, ""))

        guard case .refuse = CleanupTabReducer.plan(state, picking: .byok) else {
            return XCTFail("a rung with no endpoint is refused, not confirmed")
        }
    }

    /// **Recording that the dialog is up moves nothing else.** The selection, the draft's provider
    /// and the file are all untouched while the user is reading.
    func testTheDialogBeingUpChangesNothingButTheDialog() {
        var state = Self.loaded(provider: .rules)
        state = CleanupTabReducer.reduce(state, .confirmationRequested(.byok))

        XCTAssertEqual(state.pendingConfirmation, .byok)
        XCTAssertEqual(state.selection, .rules, "nothing is chosen while the dialog is open")
        XCTAssertEqual(state.draft.provider, .rules)
    }

    // MARK: - Declining leaves the previous choice intact

    /// **Declining leaves the previous choice intact — the value that was there.**
    ///
    /// Not "off", not "unset", not the shipped default: whatever the file said before the user
    /// clicked. The test drives it from a non-default previous choice on purpose, because a
    /// rollback that reset to `rules` would pass a test written from `rules` and would silently
    /// take a user off Ollama for declining an unrelated dialog.
    func testDecliningLeavesThePreviousChoiceIntact() {
        var state = Self.loaded(provider: .ollama)
        state = CleanupTabReducer.reduce(state, .confirmationRequested(.byok))
        state = CleanupTabReducer.reduce(state, .confirmationDeclined)

        XCTAssertEqual(state.selection, .ollama, "the value that was there, not a default")
        XCTAssertEqual(state.draft.provider, .ollama)
        XCTAssertNil(state.pendingConfirmation)
    }

    /// **Declining acknowledges nothing.** The dialog has not been read and agreed to, so the
    /// next attempt must ask again — an acknowledgement earned by dismissing is not an
    /// acknowledgement.
    func testDecliningDoesNotAcknowledgeAnything() {
        var state = Self.loaded(provider: .rules)
        state = CleanupTabReducer.reduce(state, .confirmationRequested(.byok))
        state = CleanupTabReducer.reduce(state, .confirmationDeclined)

        XCTAssertFalse(state.hasAcknowledgedCloud)
        guard case .confirm = CleanupTabReducer.plan(state, picking: .byok) else {
            return XCTFail("re-selecting after declining must ask again")
        }
    }

    // MARK: - Accepting

    /// **Accepting acknowledges, and only then is the rung written.** The write carries the cloud
    /// rung; the selection still waits for the write to land, exactly as every other rung does.
    func testAcceptingAcknowledgesAndThenTheRungIsWritten() {
        var state = Self.loaded(provider: .rules)
        state = CleanupTabReducer.reduce(state, .confirmationRequested(.byok))
        state = CleanupTabReducer.reduce(state, .confirmationAccepted)

        XCTAssertTrue(state.hasAcknowledgedCloud)
        XCTAssertNil(state.pendingConfirmation)
        XCTAssertEqual(state.selection, .rules, "accepting is not yet a write")

        guard case .write(let draft) = CleanupTabReducer.plan(state, picking: .byok) else {
            return XCTFail("after acknowledgement the rung is written")
        }
        XCTAssertEqual(draft.provider, .byok)

        let saved = CleanupTabReducer.reduce(state, .saveSucceeded(.byok))
        XCTAssertEqual(saved.selection, .byok)
    }

    // MARK: - One-time

    /// **It is one-time: an acknowledged user is never asked again.** Including after leaving the
    /// cloud rung and coming back, which is the path a nagging implementation gets wrong.
    func testAnAcknowledgedUserIsNeverAskedAgain() {
        var state = Self.loaded(provider: .rules)
        state = CleanupTabReducer.reduce(state, .acknowledgementLoaded(true))

        guard case .write = CleanupTabReducer.plan(state, picking: .byok) else {
            return XCTFail("an acknowledged user is not asked again")
        }
        state = CleanupTabReducer.reduce(state, .saveSucceeded(.byok))
        state = CleanupTabReducer.reduce(state, .saveSucceeded(.rules))
        guard case .write = CleanupTabReducer.plan(state, picking: .byok) else {
            return XCTFail("nor after leaving the cloud rung and returning to it")
        }
    }

    /// **The acknowledgement survives a relaunch**, which is what makes "one-time" mean once and
    /// not once per window. The flag is read into the state at load; a tab that started every
    /// session at `false` would nag exactly the user who already agreed.
    func testTheAcknowledgementIsLoadedIntoTheState() {
        let fresh = CleanupTabReducer.reduce(.initial, .acknowledgementLoaded(false))
        XCTAssertFalse(fresh.hasAcknowledgedCloud)

        let returning = CleanupTabReducer.reduce(.initial, .acknowledgementLoaded(true))
        XCTAssertTrue(returning.hasAcknowledgedCloud)
    }

    // MARK: - The dialog names exactly what gets sent

    /// **The dialog names the destination**, from the endpoint the user typed — not a generic
    /// "a server somewhere".
    func testTheDialogNamesTheDestination() {
        let body = CleanupTabCopy.cloudConfirmationBody(endpoint: "https://api.example.com/v1")

        XCTAssertTrue(body.contains("https://api.example.com/v1"))
    }

    /// **The dialog names exactly what gets sent, and what does not.**
    ///
    /// What `BYOKCleanupProvider` actually puts on the wire is the transcript text, a fixed
    /// instruction prompt and the model name, with the key in an `Authorization` header. **The
    /// audio never leaves the machine** — and that is the fact a person weighing this decision
    /// most needs, because "cloud cleanup" sounds like it might mean their voice. Saying it is
    /// the difference between a dialog that informs and one that alarms.
    func testTheDialogNamesWhatIsSentAndWhatIsNot() {
        let body = CleanupTabCopy.cloudConfirmationBody(endpoint: "https://api.example.com/v1")
            .lowercased()

        XCTAssertTrue(body.contains("text"), "the text of every dictation is what is sent")
        XCTAssertTrue(body.contains("audio"), "and the audio is what is not — say so")
        XCTAssertTrue(
            body.contains("never") || body.contains("not"),
            "the audio sentence has to be a denial, not a mention")
        XCTAssertTrue(body.contains("key"), "the API key travels with every request")
    }

    /// **It is a dialog the user has to read, not a checkbox in a paragraph.** The two buttons say
    /// what they do — the ``SpeechTabCopy/keepItButton`` argument: in a dialog whose other button
    /// sends text off the machine, "OK" and "Cancel" are the two words that tell you least.
    func testTheDialogsButtonsSayWhatTheyDo() {
        XCTAssertFalse(CleanupTabCopy.cloudConfirmationTitle.isEmpty)
        for label in [CleanupTabCopy.cloudConfirmAccept, CleanupTabCopy.cloudConfirmDecline] {
            XCTAssertFalse(label.isEmpty)
            XCTAssertNotEqual(label, "OK")
            XCTAssertNotEqual(label, "Cancel")
        }
        XCTAssertNotEqual(
            CleanupTabCopy.cloudConfirmAccept, CleanupTabCopy.cloudConfirmDecline,
            "two buttons that read the same are one button")
    }

    // MARK: - Fixtures

    /// A loaded tab on `provider`, with both blocks configured so the rung under test is never
    /// refused for the wrong reason.
    private static func loaded(provider: CleanupProviderKind) -> CleanupTabState {
        CleanupTabReducer.reduce(
            .initial,
            .configLoaded(
                CleanupConfigDraft(
                    provider: provider,
                    ollamaEndpoint: "http://localhost:11434",
                    ollamaModel: "llama3.1",
                    byokEndpoint: "https://api.example.com/v1",
                    byokModel: "gpt-4o-mini")))
    }
}
