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

import VoccaCore
import XCTest

/// The sentence-binding (N2 tightening, `action-surface-wiring` C13 slice 5), pinned before the
/// parameter exists.
///
/// ## What is being bound, and why
///
/// ``ActionApproval/granted`` asserts that a human said yes — and **cannot verify it** (N2). The
/// UI layer drew a sentence, the human approved *that sentence*, and the approval travelled back
/// with no memory of what it approved. Between the sentence being shown and the approval being
/// handed to ``ActionGate``, the sentence can change (an audit count moved, a file was deleted), and
/// the user would be approving something they never saw. This aspect closes that window inside the
/// gate: a granted approval may carry the exact sentence the person was shown, and the gate refuses
/// — by attempting the call and reading the refusal — when its own freshly-rendered sentence no
/// longer matches.
///
/// ## Why the refusal is asserted by making the call
///
/// The C13 precedent applies verbatim: an assertion that watches for the *absence* of a prompt
/// passes just as well when the mechanism was deleted. So every claim here is made by submitting an
/// invocation and reading the decision that comes back, and the provider's acting half is watched
/// by ``RecordingActionProvider`` — in fail-if-invoked mode where a call must not reach it, so a
/// regression fails at the violation rather than at the assertion afterwards.
///
/// ## What the binding does not claim
///
/// The gate compares strings; it does not know that the human ever *saw* the sentence it is
/// handed. The seeing is asserted by the UI layer that drew the card. What the gate makes
/// structural is the replay: an approval that names a sentence can be used for exactly that
/// sentence, and nothing else.
final class ActionGateSentenceBindingTests: XCTestCase {

    // MARK: - Fixtures

    private func makeInvocation(
        providerID: String = "dev.vocca.stub", toolID: String = "delete-downloads",
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> ActionInvocation {
        try XCTUnwrap(
            ActionInvocation(providerID: providerID, toolID: toolID),
            "a non-empty provider id and tool id must construct an invocation", file: file,
            line: line)
    }

    /// The sentence the stub's `describe` renders for the default invocation — written out **here**
    /// rather than read from the stub, so a test that agrees with the gate by construction proves
    /// nothing.
    private let stubSentence = "Stub would run delete-downloads on dev.vocca.stub."

    // MARK: - 1. The refusal, by attempting the call

    /// **A granted approval whose sentence differs from what the gate renders is refused.**
    ///
    /// The load-bearing acceptance: the approval was given to a sentence that is no longer the
    /// sentence this submission would act on, so acting on it would be replaying the approval
    /// against a different action. The refusal is returned by a call that was actually made — the
    /// exact sentence the stub renders was *not* approved, and the stub would have failed this test
    /// outright if the acting half had been reached.
    ///
    /// The decision is ``ActionDecision/declined(_:)``, which carries no summary: the provider was
    /// not reached, so there is nothing it was asked to describe for this decision — though `describe`
    /// itself was called once, because the gate can only compare against its own freshly-rendered
    /// sentence. That one call, and no more, is part of the claim: the comparison reuses the
    /// decision's own summary and adds no extra provider calls.
    func testAGrantedApprovalWithAMismatchedSentenceIsRefusedByAttemptingTheCall() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive,
            behavior: .failsTheTestIfInvoked)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]), policy: .none,
            approval: .granted, approvedSentence: "Delete 3 files in ~/Downloads.")

        XCTAssertEqual(
            decision, .declined(.approvedSentenceMismatch),
            "a granted approval bound to a sentence the gate no longer renders must come back "
                + "declined, carrying the bounded key the audit log records")
        XCTAssertFalse(
            decision.reachedTheProvider,
            "the refusal never reached the acting half of the seam")
        XCTAssertNil(
            decision.summary,
            "a declined decision carries no summary — the provider was not invoked, so there is "
                + "nothing the gate acted on")
        XCTAssertNil(
            decision.outcome,
            "and no outcome: nothing was attempted, so nothing succeeded or failed")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "the number the acceptance reads: the provider was not invoked, and the stub would "
                + "have failed this test outright if it had been")
        XCTAssertEqual(provider.executionCount, 0, "and nothing executed")
        XCTAssertEqual(
            provider.describeCount, 1,
            "the comparison reused the decision's own sentence — the mismatch cost one describe "
                + "and no extra provider calls")
    }

    // MARK: - 2. The matching sentence proceeds

    /// **A granted approval carrying the exact sentence the gate renders proceeds to invoke** —
    /// no false refusal.
    ///
    /// The binding must not make confirmation impossible: it narrows what an approval can be
    /// replayed against, and the sentence it *can* be replayed against is the one the gate
    /// renders. The sentence here is written out by hand rather than read from the stub, so the
    /// match is a fact about the two texts, not about the test agreeing with the gate by
    /// construction.
    func testAGrantedApprovalWithTheExactMatchingSentenceProceedsToInvoke() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(toolIDs: ["delete-downloads"])

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]), policy: .none,
            approval: .granted, approvedSentence: stubSentence)

        XCTAssertEqual(
            decision,
            .invoked(
                summary: ActionSummary(sentence: stubSentence, blastRadius: .destructive),
                outcome: .succeeded),
            "the exact sentence the gate rendered is the one sentence the approval may be used for")
        XCTAssertEqual(provider.invokeCount, 1, "the acting half was reached")
        XCTAssertEqual(provider.executionCount, 1, "and it genuinely executed")
    }

    // MARK: - 3. nil is today's behaviour

    /// **`approvedSentence == nil` behaves byte-identically to today** — the F2 precedent.
    ///
    /// The test is not "the default happens to work": it is "the default grants nothing the
    /// caller did not ask for". `nil` asks for no binding, so the gate decides exactly as a
    /// submission that never mentions the parameter does — asserted by running both spellings and
    /// requiring the same decision, which is what keeps every existing call site's semantics
    /// untouched.
    func testAGrantedApprovalWithNilApprovedSentenceBehavesExactlyAsToday() async throws {
        let invocation = try makeInvocation()
        let enablement = ActionEnablement([invocation])

        let today = RecordingActionProvider(toolIDs: ["delete-downloads"])
        let asToday = await ActionGate.submit(
            invocation, to: today, enablement: enablement, policy: .none, approval: .granted)

        let withNil = RecordingActionProvider(toolIDs: ["delete-downloads"])
        let nilSpelled = await ActionGate.submit(
            invocation, to: withNil, enablement: enablement, policy: .none, approval: .granted,
            approvedSentence: nil)

        let expected = ActionDecision.invoked(
            summary: ActionSummary(sentence: stubSentence, blastRadius: .destructive),
            outcome: .succeeded)
        XCTAssertEqual(asToday, expected, "today's call site still behaves as today")
        XCTAssertEqual(
            nilSpelled, expected,
            "an explicitly-nil binding is byte-identical to no binding at all — nil grants nothing")
        XCTAssertEqual(today.invokeCount, 1)
        XCTAssertEqual(withNil.invokeCount, 1)
    }

    // MARK: - 4. The key is bounded and stable

    /// The new key is **bounded** (an enum case returning a literal, never free text) and
    /// **stable** (spelled `gate.approvedSentenceMismatch`, the audit-log vocabulary).
    ///
    /// Bounded is asserted by the shape: the key is the return value of a switch over a closed
    /// enum, so there is nowhere for caller-supplied text to enter it. Stable is asserted by the
    /// exact spelling, which is what a persisted audit entry will hold.
    func testTheApprovedSentenceMismatchKeyIsBoundedAndStable() {
        XCTAssertEqual(
            ActionDeclineReason.approvedSentenceMismatch.reasonKey,
            "gate.approvedSentenceMismatch",
            "the audit log records the key, so the key's spelling is the contract")
        XCTAssertNotEqual(
            ActionDeclineReason.approvedSentenceMismatch.reasonKey,
            ActionDeclineReason.toolNotEnabled.reasonKey,
            "the two declines are distinct events and must not collapse into one key")
    }

    // MARK: - 5. Withheld beats mismatch

    /// **A withheld approval with a mismatched sentence is refused by the existing confirmation
    /// path** — withheld beats mismatch.
    ///
    /// Pinned, not changed: the gate's withheld behaviour is the one that exists today — for a
    /// radius that requires confirmation, a withheld approval comes back
    /// ``ActionDecision/confirmationRequired(_:)`` carrying the sentence a human would be shown.
    /// The binding compares only when ``ActionApproval/granted`` is present, so a submission that
    /// has no approval at all is decided exactly as before, whatever sentence text it carries.
    func testAWithheldApprovalWithAMismatchedSentenceIsRefusedByTheExistingConfirmationPath()
        async throws
    {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive,
            behavior: .failsTheTestIfInvoked)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]), policy: .none,
            approval: .withheld, approvedSentence: "Delete 3 files in ~/Downloads.")

        XCTAssertEqual(
            decision,
            .confirmationRequired(
                ActionSummary(sentence: stubSentence, blastRadius: .destructive)),
            "withheld is decided by the existing confirmation path — the binding adds nothing to "
                + "a submission nobody approved")
        XCTAssertFalse(
            decision.reachedTheProvider,
            "and the acting half was still not reached")
        XCTAssertEqual(provider.invokeCount, 0)
    }

    // MARK: - 6. The empty-sentence edge case

    /// **An empty `approvedSentence` is a mismatch** — no sentence, no approval.
    ///
    /// The plan's edge case, decided by test: the stub renders a non-empty sentence, so an empty
    /// shown sentence cannot be the sentence this submission would act on. An approval that
    /// carries no sentence at all must not be replayable against anything.
    func testAnEmptyApprovedSentenceIsAMismatch() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], behavior: .failsTheTestIfInvoked)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]), policy: .none,
            approval: .granted, approvedSentence: "")

        XCTAssertEqual(
            decision, .declined(.approvedSentenceMismatch),
            "an empty shown sentence approves nothing — the gate renders a sentence, and the "
                + "empty string is not it")
        XCTAssertEqual(provider.invokeCount, 0)
        XCTAssertEqual(provider.executionCount, 0)
    }
}