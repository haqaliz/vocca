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

import Synchronization
import VoccaCore
import VoccaUI
import XCTest

/// The FAILSAFE window's contracts (`failsafe-surface` Phase C): the parts of the panel that are
/// not chrome, driven headlessly — a fake ``TranscriptHolder``, the reducer, and the injected
/// copy/retry handlers. The `FailsafeStateReducerTests` pattern, moved up one level: the window
/// itself is glue "executed by nothing in CI" (its focus behaviour and key equivalents need a
/// window server session — the smoke checklist's rows, `SMOKE_CHECKLIST.md` steps 30 and 32; by
/// step number, not line range, because the line range this cited had already drifted off them),
/// so what is
/// asserted here is everything the panel decides *between* the user's intent and the seam.
///
/// The class is `@MainActor` like the panel it drives (`ClipboardRungTests`' shape): the panel is
/// an `NSPanel` subclass, so its whole surface is main-actor-isolated — an actor in the tests
/// would split the one state the assertions read.
///
/// ## The delivery shape, stated because the seam has no push
///
/// ``TranscriptHolder`` offers `hold`/`current`/`release` and nothing else — there is no
/// "transcript held" notification to subscribe to. The composition root therefore *tells* the
/// panel when a failsafe has fired (after awaiting the holder's `hold`), and the panel answers by
/// reading `current()`: ``FailsafePanel/presentHeldTranscript()`` is that read. "The holder
/// delivers" in these tests is exactly that — the fake holds, the panel reads, the state
/// presents.
@MainActor
final class FailsafePanelContractTests: XCTestCase {

    // MARK: - The custody line

    /// A held transcript promises custody; a reason-only notice promises nothing, because there is
    /// nothing held. "Your words are safe here" over an empty panel would be the cruellest
    /// sentence in the app.
    func testTheCustodyLineIsPresentOnlyWhenSomethingIsHeld() {
        let held = heldTranscript(reason: .exhausted, appName: "Notes")
        for state in [
            FailsafeState.presenting(held), .retrying(held), .copied(held),
        ] {
            let line = FailsafeCopy.custodyLine(for: state)
            XCTAssertFalse(line.isEmpty, "\(state) holds a transcript and must say so")
            XCTAssertTrue(
                line.contains("safe"),
                "the line's whole job is to answer \"have I lost it?\"")
        }
        XCTAssertEqual(
            FailsafeCopy.custodyLine(for: .reasonOnly(.transcriptionFailed)), "",
            "nothing is held, so nothing may be promised")
        XCTAssertEqual(FailsafeCopy.custodyLine(for: .reasonOnly(.modelUnavailable)), "")
    }

    /// The line states the no-timeout guarantee, which is otherwise an invisible property of the
    /// reducer — it has no time-based transition at all — and therefore something a user has no
    /// way to discover before deciding whether to hurry.
    func testTheCustodyLineStatesTheNoTimeoutGuarantee() {
        let held = heldTranscript(appName: nil)
        let line = FailsafeCopy.custodyLine(for: .presenting(held))
        XCTAssertTrue(
            line.contains("until you dismiss it"),
            "a panel that never times out must say so, or the user assumes it does")
    }


    // MARK: - The fakes

    /// The fake holder every test drives — `FakeTranscriptHolder`'s shape from `HeldTranscriptTests`,
    /// minus the durable-store ledger: the panel's contracts care about *what is held* and
    /// *whether release was called*, not about the write ordering the seam's own suite pins.
    private actor PanelTestHolder: TranscriptHolder {
        private var currentTranscript: HeldTranscript?
        private(set) var releaseCount = 0

        func hold(_ transcript: HeldTranscript) async throws {
            currentTranscript = transcript
        }

        func current() async -> HeldTranscript? {
            currentTranscript
        }

        func release() async {
            releaseCount += 1
            currentTranscript = nil
        }
    }

    /// One fixture: the panel wired to a fake holder and two recording handler channels.
    ///
    /// The handlers record through `Synchronization.Mutex` (`ModelDownloaderTests`' progress
    /// channel): the panel's handlers are synchronous `(HeldTranscript) -> Void` closures called
    /// on the main actor, so a mutex-guarded array is the honest recording shape — deterministic,
    /// no races, no polling. The channels live in a reference-counted box rather than on the
    /// fixture itself: `Mutex` is noncopyable, so a value can be owned by the handler closures
    /// *or* by a stored property, not both — a box both hold is neither.
    @MainActor
    private final class Fixture {
        /// The recording channels, in a box the handler closures and the tests both hold.
        final class Channels {
            let copies = Mutex<[HeldTranscript]>([])
            let retries = Mutex<[HeldTranscript]>([])
        }

        let panel: FailsafePanel
        let holder: PanelTestHolder
        let channels: Channels

        init(holder: PanelTestHolder) {
            self.holder = holder
            let channels = Channels()
            self.channels = channels
            self.panel = FailsafePanel(
                holder: holder,
                copyHandler: { transcript in channels.copies.withLock { $0.append(transcript) } },
                retryHandler: { transcript in channels.retries.withLock { $0.append(transcript) } })
        }
    }

    // MARK: - Helpers

    private func heldTranscript(
        text: String = "The quick brown fox jumps over the lazy dog",
        reason: FailsafeReason = .exhausted,
        appName: String? = "Slack",
        capturedAt: Duration = .seconds(42)
    ) -> HeldTranscript {
        HeldTranscript(text: text, reason: reason, targetAppName: appName, capturedAt: capturedAt)
    }

    /// A fixture with `transcript` already held by its fake holder and presented — the state every
    /// intent test starts from.
    private func makeFixture(_ transcript: HeldTranscript) async throws -> Fixture {
        let fixture = Fixture(holder: PanelTestHolder())
        try await fixture.holder.hold(transcript)
        _ = await fixture.panel.presentHeldTranscript()
        return fixture
    }

    /// The held text a state carries, or `nil` when it holds nothing — the "is the text still
    /// recoverable" probe.
    private func heldText(of state: FailsafeState) -> String? {
        switch state {
        case .hidden, .reasonOnly: return nil
        case .presenting(let transcript), .retrying(let transcript), .copied(let transcript):
            return transcript.text
        }
    }

    // MARK: - Custody in: the holder delivers

    /// The failsafe fired and the panel read the holder: `presenting` with the reason and the
    /// target app name intact — the structured cause the view renders from.
    func testHolderDeliveryPresentsWithTheReasonAndTargetAppName() async throws {
        let transcript = heldTranscript(reason: .exhausted, appName: "Slack")
        let fixture = try await makeFixture(transcript)

        guard case .presenting(let presented) = fixture.panel.state else {
            return XCTFail("a fired failsafe must present, got \(fixture.panel.state)")
        }
        XCTAssertEqual(presented.text, transcript.text)
        XCTAssertEqual(presented.reason, .exhausted, "the cause must surface verbatim")
        XCTAssertEqual(presented.targetAppName, "Slack", "the {app} the view renders must surface")
    }

    /// The relaunch load presents the unresolved entry with its captured-at note intact — the
    /// journal's entry arrives through the same panel, marked as a relaunch (`PRODUCT_SPEC.md:117`).
    func testRelaunchLoadPresentsWithItsCapturedAtNoteIntact() async throws {
        let transcript = heldTranscript(text: "Unresolved at the crash", capturedAt: .milliseconds(12_345))
        let holder = PanelTestHolder()
        try await holder.hold(transcript)
        let fixture = Fixture(holder: holder)

        let loaded = await fixture.panel.loadJournalOnLaunch()

        XCTAssertEqual(loaded, transcript, "the relaunch load must read back exactly the held entry")
        guard case .presenting(let presented) = fixture.panel.state else {
            return XCTFail("a relaunch load must present, got \(fixture.panel.state)")
        }
        XCTAssertEqual(presented.capturedAt, .milliseconds(12_345),
            "the captured-at note must flow through verbatim")
        XCTAssertEqual(presented.text, "Unresolved at the crash")
    }

    // MARK: - Copy

    /// ⌘C: the copy handler receives **exactly the held text, once** — and the retry handler is
    /// never touched by a copy.
    func testCopyRoutesExactlyTheHeldTextOnceToTheCopyHandler() async throws {
        let transcript = heldTranscript(text: "Copy every last word of this, verbatim.")
        let fixture = try await makeFixture(transcript)

        fixture.panel.copyTranscript()

        XCTAssertEqual(fixture.channels.copies.withLock { $0 }, [transcript],
            "the copy handler must receive exactly the held text, once")
        XCTAssertEqual(fixture.channels.retries.withLock { $0 }, [],
            "copy must never touch the retry handler")
        XCTAssertEqual(fixture.panel.state, .copied(transcript),
            "⌘C must land the state in .copied")
    }

    /// Copy pressed repeatedly is idempotent: each ⌘C carries the same full text (`plan` §6).
    func testRepeatedCopyCarriesTheSameFullTextEveryPress() async throws {
        let transcript = heldTranscript(text: "Press twice, copy twice, lose nothing.")
        let fixture = try await makeFixture(transcript)

        fixture.panel.copyTranscript()
        fixture.panel.copyTranscript()

        XCTAssertEqual(fixture.channels.copies.withLock { $0 }, [transcript, transcript],
            "every ⌘C must carry the same full text")
    }

    /// Copy while a retry is in flight still works — the failsafe stays interactive throughout.
    func testCopyWorksWhileARetryIsInFlight() async throws {
        let transcript = heldTranscript()
        let fixture = try await makeFixture(transcript)

        fixture.panel.retryTranscript()
        fixture.panel.copyTranscript()

        XCTAssertEqual(fixture.channels.copies.withLock { $0 }, [transcript])
        XCTAssertEqual(fixture.panel.state, .copied(transcript),
            "⌘C during a retry must copy the held text")
    }

    /// A stray ⌘C on a failsafe that never fired is a no-op — nothing held, nothing to copy; the
    /// handler must not write anything to the pasteboard.
    func testStrayCopyOnAHiddenPanelDoesNotFireTheCopyHandler() async {
        let fixture = Fixture(holder: PanelTestHolder())

        fixture.panel.copyTranscript()

        XCTAssertEqual(fixture.panel.state, .hidden)
        XCTAssertEqual(fixture.channels.copies.withLock { $0 }, [],
            "a stray ⌘C must not write to the pasteboard")
        XCTAssertEqual(fixture.channels.retries.withLock { $0 }, [])
    }

    // MARK: - Retry

    /// ⏎: the retry handler fires once with the transcript, and the transcript is *retained* in
    /// state — custody is not released into the re-run. A failed re-run re-holds: the panel
    /// returns to `presenting` with the text intact and the fresh cause.
    func testRetryRoutesOnceRetainingTheTranscriptAndAFailedReRunReholdsItIntact() async throws {
        let transcript = heldTranscript(text: "Retry me, I am not lost.")
        let fixture = try await makeFixture(transcript)

        fixture.panel.retryTranscript()

        XCTAssertEqual(fixture.channels.retries.withLock { $0 }, [transcript],
            "the retry handler must receive the held transcript, once")
        XCTAssertEqual(fixture.channels.copies.withLock { $0 }, [],
            "retry must never touch the copy handler")
        guard case .retrying(let retrying) = fixture.panel.state else {
            return XCTFail("a retry must retain the transcript, got \(fixture.panel.state)")
        }
        XCTAssertEqual(retrying.text, transcript.text,
            "the retry must retain the held text, not release it")

        try await fixture.holder.hold(heldTranscript(text: transcript.text, reason: .noFocusedField))
        _ = await fixture.panel.presentHeldTranscript()

        guard case .presenting(let presented) = fixture.panel.state else {
            return XCTFail("a failed re-run must return to presenting, got \(fixture.panel.state)")
        }
        XCTAssertEqual(presented.text, transcript.text,
            "a failed re-run must never drop the text")
        XCTAssertEqual(presented.reason, .noFocusedField,
            "the re-run's updated cause must surface — the copy follows the fresh failure")
    }

    // MARK: - Dismiss

    /// ✕: the failsafe hides **and the holder is released** — dismiss resolves the custody.
    func testDismissHidesAndReleasesTheHolder() async throws {
        let fixture = try await makeFixture(heldTranscript())

        await fixture.panel.dismissTranscript()

        let releaseCount = await fixture.holder.releaseCount
        XCTAssertEqual(fixture.panel.state, .hidden, "dismiss must hide the failsafe")
        XCTAssertEqual(releaseCount, 1,
            "dismiss must release the held transcript")
    }

    /// A stray ✕ on a failsafe that never fired releases nothing — an Esc in the target app must
    /// not purge a journal the user has not resolved.
    func testDismissFromHiddenIsANoOpOnTheHolder() async {
        let holder = PanelTestHolder()
        let fixture = Fixture(holder: holder)

        await fixture.panel.dismissTranscript()

        let releaseCount = await holder.releaseCount
        XCTAssertEqual(fixture.panel.state, .hidden)
        XCTAssertEqual(releaseCount, 0,
            "a stray ✕ must not purge the journal")
    }

    // MARK: - Never auto-dismisses, at the panel surface

    /// The structural pin, restated where the panel lives: over the panel's *own* routing
    /// surface — copy, retry, a re-present and a relaunch reload — nothing moves a presented
    /// transcript to `hidden`; only dismiss does (`PRODUCT_SPEC.md:104`).
    func testOnlyDismissMovesAPresentedTranscriptToHiddenAtThePanelSurface() async throws {
        let transcript = heldTranscript()

        try await assertRouteKeepsShowing(transcript, "copy") { $0.copyTranscript() }
        try await assertRouteKeepsShowing(transcript, "retry") { $0.retryTranscript() }
        try await assertRouteKeepsShowing(transcript, "re-present") {
            _ = await $0.presentHeldTranscript()
        }
        try await assertRouteKeepsShowing(transcript, "relaunch reload") {
            _ = await $0.loadJournalOnLaunch()
        }

        let fixture = try await makeFixture(transcript)
        await fixture.panel.dismissTranscript()
        XCTAssertEqual(fixture.panel.state, .hidden,
            "dismiss is the only path from presenting to hidden at the panel")
    }

    private func assertRouteKeepsShowing(
        _ transcript: HeldTranscript,
        _ name: String,
        route: @MainActor (FailsafePanel) async -> Void
    ) async throws {
        let fixture = try await makeFixture(transcript)
        await route(fixture.panel)
        XCTAssertNotEqual(fixture.panel.state, .hidden,
            "\(name) must never hide a presented transcript")
        XCTAssertNotNil(heldText(of: fixture.panel.state),
            "\(name) must keep the text recoverable")
    }

    // MARK: - The rendered copy (`FailsafeCopy`)

    /// `PRODUCT_SPEC.md:111` verbatim: the Secure Input refusal names the cause, not the app.
    func testSecureInputCopyRendersThePasswordFieldRefusal() {
        XCTAssertEqual(
            FailsafeCopy.reasonText(for: .secureInput, targetAppName: "1Password"),
            "This looks like a password field. Vocca won't type into it — press ⌘C to paste it yourself.")
    }

    /// `PRODUCT_SPEC.md:112` verbatim: the exhausted copy interpolates the target app name into
    /// the {app} slot.
    func testExhaustedCopyInterpolatesTheTargetAppName() {
        XCTAssertEqual(
            FailsafeCopy.reasonText(for: .exhausted, targetAppName: "Notion"),
            "Couldn't type into Notion. Press ⌘C to paste it manually, or ⏎ to try again.")
    }

    /// When the app name could not be resolved, the exhausted copy falls back to a name-less
    /// phrasing — never "Couldn't type into ." and never an invented name.
    func testExhaustedCopyFallsBackToANameLessPhrasingWhenTheAppNameIsMissing() {
        XCTAssertEqual(
            FailsafeCopy.reasonText(for: .exhausted, targetAppName: nil),
            "Couldn't type into the focused app. Press ⌘C to paste it manually, or ⏎ to try again.")
    }

    /// `PRODUCT_SPEC.md:113` verbatim: the no-focus copy points at the fix — click, then ⏎.
    func testNoFocusedFieldCopyRendersTheClickAndRetryPrompt() {
        XCTAssertEqual(
            FailsafeCopy.reasonText(for: .noFocusedField, targetAppName: nil),
            "Nothing was focused. Click where you want this, then press ⏎.")
    }

    /// The reserved revocation reason renders its honest refusal as the fallback — the
    /// `[Open Settings]` affordance is a later unit's action, so the copy stands without it.
    func testAccessibilityRevokedCopyRendersTheHonestRefusal() {
        XCTAssertEqual(
            FailsafeCopy.reasonText(for: .accessibilityRevoked, targetAppName: nil),
            "Vocca's permission to type was turned off. Press ⌘C to paste it manually.")
    }

    /// The affordances legend, `PRODUCT_SPEC.md:54` verbatim — what ⌘C, ⏎ and ✕ do. Asserted
    /// over a presented transcript; a reason-only notice renders an empty legend instead (PRD R5).
    func testAffordancesLineRendersTheProductSpecAffordances() {
        let transcript = heldTranscript()
        XCTAssertEqual(
            FailsafeCopy.affordancesLine(for: .presenting(transcript)),
            "⌘C to copy    ⏎ retry   ✕")
        XCTAssertEqual(
            FailsafeCopy.affordancesLine(for: .reasonOnly(.modelUnavailable)),
            "",
            "a reason-only notice must render no affordances legend — no text exists to copy or retry")
    }
}
