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

/// The confirmation gate (`action-safety-spine` PRD M4/M5/M7, C13's structural refusal), pinned
/// before it exists.
///
/// R8 — a destructive action running unintended — is the unit's Fatal (trust) risk, and C13's
/// acceptance is unusually specific about how it must be closed: **by attempting the bypass and
/// requiring refusal**, never by observing that no prompt appeared. An assertion that watches for
/// the absence of something passes just as well when the mechanism was deleted. So every claim
/// below is made by making a call and reading what came back.
///
/// ## What the tests can and cannot reach
///
/// This file imports `VoccaCore` plainly, so it cannot mint an ``ActionConfirmation`` — the
/// initializer is `internal` and `ActionSeamBoundaryTests`' Family B forbids the `@testable` route
/// across `Tests/` as well as `Sources/`. That inaccessibility is not an obstacle to testing the
/// gate; it *is* the property under test. A caller holding no token has exactly one way to reach a
/// provider's acting half — through the gate — which is why "submitted without a confirmation" is
/// expressible here as an ordinary call.
///
/// ## The instrument
///
/// ``RecordingActionProvider`` supplies the non-empty domain (`action-seam` PRD M10): it serves
/// tools, it genuinely executes, and it logs `describe` and `invoke` as separate entries. Every
/// zero asserted below is read from an instrument that has been watched reporting non-zero
/// (``ActionProviderStubsTests``), which is what keeps "invoked zero times" from being the vacuous
/// green of a provider that could never have been invoked at all. Where a call must not reach the
/// acting half, the stub is additionally configured with
/// ``RecordingActionProvider/InvokeBehavior/failsTheTestIfInvoked``, so a regression fails at the
/// violation rather than at the assertion afterwards.
final class ActionGateTests: XCTestCase {

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

    /// The order the escalate-only rule is stated in, written out **here** rather than read from
    /// the implementation.
    ///
    /// A monotonicity test that borrowed the production ordering would agree with the gate by
    /// construction and prove nothing. This is the spec's table (`spec.md` — `readOnly` may be
    /// raised to either of the others, `outwardFacing` may be lowered to neither), restated
    /// independently. The switch is exhaustive so a fourth ``BlastRadius`` case has to be placed in
    /// this order by hand before the sweep below can run over it.
    private func reach(_ radius: BlastRadius) -> Int {
        switch radius {
        case .readOnly: return 0
        case .destructive: return 1
        case .outwardFacing: return 2
        }
    }

    // MARK: - 1. The load-bearing refusal

    /// **A destructive invocation submitted without a confirmation is refused.**
    ///
    /// The single most important assertion in the aspect. It is made by submitting the invocation
    /// — an enabled tool, live mode, everything else in order — and requiring that what comes back
    /// is a refusal and that the provider's acting half was never reached. The stub is in
    /// fail-if-invoked mode, so a gate that let the call through fails the test at the moment of
    /// the invocation as well as at the assertion.
    ///
    /// Note what is *not* asserted: nothing here observes that a prompt did not appear. There is no
    /// prompt in this aspect at all. The refusal is a value returned by a call that was actually
    /// made.
    func testADestructiveInvocationWithoutAConfirmationIsRefused() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive,
            behavior: .failsTheTestIfInvoked)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]))

        XCTAssertEqual(
            decision,
            .confirmationRequired(
                ActionSummary(
                    sentence: "Stub would run delete-downloads on dev.vocca.stub.",
                    blastRadius: .destructive)),
            "a destructive invocation submitted without a confirmation must come back refused, "
                + "carrying the sentence a human would be shown — this is the bypass attempted and "
                + "structurally denied (C13, PRD M4)")
        XCTAssertFalse(
            decision.reachedTheProvider,
            "the refusal never reached the acting half of the seam")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "the number C13's acceptance reads: the provider was not invoked, and the stub would "
                + "have failed this test outright if it had been")
        XCTAssertEqual(provider.executionCount, 0, "and nothing executed")
    }

    /// A refusal is **not** a failure, and the two cannot be confused by a reader of the decision.
    ///
    /// R8's audit question is "did this actually run?", and a log that recorded a gate refusal the
    /// same way it records a tool that errored could not answer it. So the refusal is its own
    /// decision value carrying no ``ActionOutcome`` at all, while a provider that tried and failed
    /// comes back as a genuine invocation whose outcome is the failure.
    func testARefusalIsDistinguishableFromAProviderFailure() async throws {
        let invocation = try makeInvocation()
        let enablement = ActionEnablement([invocation])

        let refusing = RecordingActionProvider(
            toolIDs: ["delete-downloads"], behavior: .failsTheTestIfInvoked)
        let refused = await ActionGate.submit(invocation, to: refusing, enablement: enablement)

        let failing = RecordingActionProvider(
            toolIDs: ["delete-downloads"],
            behavior: .executes(.failed(reasonKey: "stub.diskFull")))
        let failed = await ActionGate.submit(
            invocation, to: failing, enablement: enablement, approval: .granted)

        XCTAssertNil(
            refused.outcome,
            "a refused action has no outcome: the provider never ran, so there is nothing for it "
                + "to have returned")
        XCTAssertEqual(
            failed.outcome, .failed(reasonKey: "stub.diskFull"),
            "an action that ran and failed carries the provider's own outcome")
        XCTAssertNotEqual(
            refused, failed,
            "'we stopped this' and 'the tool errored' are different events — the distinction the "
                + "audit log turns on (R8)")
        XCTAssertFalse(refused.reachedTheProvider)
        XCTAssertTrue(failed.reachedTheProvider, "a failed action still reached the provider")
        XCTAssertEqual(failing.executionCount, 1)
    }

    // MARK: - 2. Outward-facing behaves exactly as destructive — pinned

    /// `outwardFacing` and `destructive` are treated **identically** by the gate today.
    ///
    /// Pinned so that PRD C4's open decision — collapse the two cases or let them diverge — has to
    /// be a visible edit to this test rather than a behaviour that drifted apart while nobody was
    /// reading. Both legs are driven: refused without a confirmation, invoked with one.
    func testOutwardFacingBehavesExactlyAsDestructive() async throws {
        let invocation = try makeInvocation(toolID: "send-message")
        let enablement = ActionEnablement([invocation])

        for radius in [BlastRadius.destructive, .outwardFacing] {
            let refusing = RecordingActionProvider(
                toolIDs: ["send-message"], describedRadius: radius,
                behavior: .failsTheTestIfInvoked)
            let refused = await ActionGate.submit(invocation, to: refusing, enablement: enablement)
            XCTAssertFalse(
                refused.reachedTheProvider,
                "\(radius) must be refused without a confirmation, exactly like the other")
            XCTAssertEqual(refusing.invokeCount, 0)

            let running = RecordingActionProvider(
                toolIDs: ["send-message"], describedRadius: radius)
            let ran = await ActionGate.submit(
                invocation, to: running, enablement: enablement, approval: .granted)
            XCTAssertEqual(
                ran.outcome, .succeeded,
                "\(radius) must run once confirmed, exactly like the other")
            XCTAssertEqual(running.invokeCount, 1)
        }
    }

    // MARK: - 3. Dry-run invokes nothing

    /// A dry-run **describes and stops**: `invoke` is reached zero times.
    ///
    /// The claim is narrower than "the provider was not touched" — a preview that could not render
    /// the sentence would have nothing to preview, so `describe` is expected. The stub logs the two
    /// operations separately precisely so this is expressible (`action-seam` PRD M10).
    func testADryRunDescribesAndInvokesNothing() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], behavior: .failsTheTestIfInvoked)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            mode: .dryRun)

        XCTAssertEqual(
            decision,
            .previewed(
                ActionSummary(
                    sentence: "Stub would run delete-downloads on dev.vocca.stub.",
                    blastRadius: .destructive)),
            "a dry-run returns the rendered preview and nothing else")
        XCTAssertEqual(provider.describeCount, 1, "describing is what a dry-run is for")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "PRD M5/G2: a dry-run invokes zero times — read from an instrument that has been "
                + "watched reporting non-zero")
    }

    /// A dry-run does not act **even when a confirmation has been given**.
    ///
    /// Without this leg, "dry-run invokes nothing" would hold only for the path that was refused
    /// anyway, and a preview of an already-approved action would quietly perform it — the exact
    /// shape of an unintended destructive run.
    func testADryRunDoesNotActEvenWhenApprovalWasGranted() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], behavior: .failsTheTestIfInvoked)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            approval: .granted, mode: .dryRun)

        XCTAssertFalse(
            decision.reachedTheProvider,
            "an approved action previewed is still only previewed — the mode decides before the "
                + "approval is read")
        XCTAssertEqual(provider.invokeCount, 0)
        XCTAssertEqual(provider.executionCount, 0)
    }

    // MARK: - 4. Per-tool enablement, default off, never-read

    /// A disabled tool is declined **before `describe` and before `invoke`** — zero calls of
    /// either kind.
    ///
    /// The `ContextConsentGate` precedent (C12): declined, never called-then-discarded. Reading the
    /// provider and throwing the answer away would pass a naive "it did not run" check while
    /// having asked a tool nobody enabled what it would do. The stub's call log is asserted empty,
    /// which is the only assertion that can tell the two apart.
    func testADisabledToolIsDeclinedBeforeDescribeAndBeforeInvoke() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], behavior: .failsTheTestIfInvoked)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: .none, approval: .granted)

        XCTAssertEqual(
            decision, .declined(.toolNotEnabled),
            "a tool that was never enabled is declined by the gate, with a bounded reason the "
                + "audit log can record")
        XCTAssertEqual(
            provider.calls, [],
            "zero calls of either kind: the provider was never asked what it would do, which is "
                + "the never-read property rather than read-then-discard")
        XCTAssertEqual(provider.describeCount, 0)
        XCTAssertEqual(provider.invokeCount, 0)
    }

    /// An **unknown** tool — one no enablement set ever mentioned — is declined exactly like a
    /// disabled one. Default off means absent is off.
    func testAnUnknownToolIsDeclinedLikeADisabledOne() async throws {
        let known = try makeInvocation(toolID: "list-files")
        let unknown = try makeInvocation(toolID: "delete-downloads")
        let provider = RecordingActionProvider(
            toolIDs: ["list-files", "delete-downloads"], behavior: .failsTheTestIfInvoked)

        let decision = await ActionGate.submit(
            unknown, to: provider, enablement: ActionEnablement([known]), approval: .granted)

        XCTAssertEqual(
            decision, .declined(.toolNotEnabled),
            "absent from the enablement set is off — there is no third state between enabled and "
                + "disabled for the gate to fall through")
        XCTAssertEqual(provider.calls, [])
    }

    /// Enablement is per tool, not per provider: enabling one tool does not enable its neighbour.
    func testEnablingOneToolDoesNotEnableAnother() throws {
        let enabled = try makeInvocation(toolID: "list-files")
        let other = try makeInvocation(toolID: "delete-downloads")
        let enablement = ActionEnablement([enabled])

        XCTAssertTrue(enablement.isEnabled(enabled))
        XCTAssertFalse(
            enablement.isEnabled(other),
            "two tools of the same provider are enabled separately — a blanket allow is the thing "
                + "this set exists not to be")
        XCTAssertFalse(
            ActionEnablement.none.isEnabled(enabled),
            "the default is off, and the default is the empty set")
    }

    /// **Disabled beats dry-run:** previewing a tool nobody enabled still declines before
    /// `describe`.
    ///
    /// A preview looks harmless, which is exactly why the ordering has to be pinned: if dry-run
    /// were checked first, a disabled tool could be asked what it would do by anyone who asked
    /// politely.
    func testADryRunOfADisabledToolIsDeclinedBeforeDescribe() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], behavior: .failsTheTestIfInvoked)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: .none, mode: .dryRun)

        XCTAssertEqual(decision, .declined(.toolNotEnabled))
        XCTAssertEqual(
            provider.calls, [],
            "the enablement check runs before the mode is consulted — a disabled tool is not "
                + "describable either")
    }

    /// Enable, invoke, disable — and the next invocation is refused. **No carry-over.**
    ///
    /// The gate owns no state (enablement is passed in), so this is a statement about the gate
    /// reading the set it was handed on every call rather than remembering an earlier one.
    func testEnablingThenDisablingRefusesTheNextInvocation() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(toolIDs: ["delete-downloads"])
        let enabled = ActionEnablement().enabling(invocation)

        let first = await ActionGate.submit(
            invocation, to: provider, enablement: enabled, approval: .granted)
        XCTAssertEqual(first.outcome, .succeeded, "the enabled tool ran once")
        XCTAssertEqual(provider.invokeCount, 1)

        let disabled = enabled.disabling(invocation)
        let second = await ActionGate.submit(
            invocation, to: provider, enablement: disabled, approval: .granted)

        XCTAssertEqual(
            second, .declined(.toolNotEnabled),
            "disabling takes effect on the very next invocation — a tool that ran a moment ago "
                + "carries no permission forward")
        XCTAssertEqual(
            provider.invokeCount, 1, "the second submission never reached the acting half")
    }

    // MARK: - 5. Confirmation is per invocation

    /// Confirming once does **not** confirm twice: two invocations require two confirmations.
    ///
    /// PRD M4a — no "don't ask me again", no per-tool and no per-session carry-over. Asserted by
    /// running the same tool twice, granting only the first: the second must come back refused
    /// with the acting half untouched.
    func testConfirmingOnceDoesNotConfirmTwice() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(toolIDs: ["delete-downloads"])
        let enablement = ActionEnablement([invocation])

        let first = await ActionGate.submit(
            invocation, to: provider, enablement: enablement, approval: .granted)
        XCTAssertEqual(first.outcome, .succeeded)
        XCTAssertEqual(provider.invokeCount, 1)

        let second = await ActionGate.submit(invocation, to: provider, enablement: enablement)

        XCTAssertFalse(
            second.reachedTheProvider,
            "the second invocation needs its own confirmation — the first one authorised one "
                + "action, not a tool and not a session")
        XCTAssertEqual(
            provider.invokeCount, 1,
            "exactly one invocation reached the provider, for exactly one confirmation")
    }

    // MARK: - 6. The read-only direct path

    /// A `readOnly` invocation of an **enabled** tool runs without a confirmation.
    ///
    /// The other side of the gate: it exists to stop what must be stopped, not everything. Read-only
    /// is the one radius ``BlastRadius/requiresConfirmation`` lets through, and this is the call
    /// that proves the gate is not simply refusing everything — which is the failure mode a suite of
    /// refusal tests alone would happily pass.
    func testAReadOnlyInvocationOfAnEnabledToolRunsWithoutAConfirmation() async throws {
        let invocation = try makeInvocation(toolID: "list-files")
        let provider = RecordingActionProvider(
            toolIDs: ["list-files"], describedRadius: .readOnly)

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]))

        XCTAssertEqual(
            decision,
            .invoked(
                summary: ActionSummary(
                    sentence: "Stub would run list-files on dev.vocca.stub.",
                    blastRadius: .readOnly),
                outcome: .succeeded),
            "read-only runs directly, and the decision carries both what was described and what "
                + "came of it")
        XCTAssertEqual(provider.invokeCount, 1)
        XCTAssertEqual(provider.executionCount, 1, "it genuinely executed")
    }

    /// "May run directly" is a statement about **permission**, never a promise the provider will
    /// serve the call: the shipped default is reached through the gate and still does nothing.
    func testTheShippedDefaultIsReachedAndStillDoesNothing() async throws {
        let invocation = try XCTUnwrap(
            ActionInvocation(providerID: "dev.vocca.null", toolID: "noop"))

        let decision = await ActionGate.submit(
            invocation, to: NullActionProvider(),
            enablement: ActionEnablement([invocation]), approval: .granted)

        XCTAssertEqual(
            decision.outcome, .notInvoked,
            "the gate permitted the call and the provider declined it — permission and service are "
                + "different answers, and only the provider gives the second")
        XCTAssertTrue(
            decision.reachedTheProvider,
            "it did reach the provider: `.notInvoked` here is the provider's own refusal, not the "
                + "gate's")
    }

    // MARK: - 7. The escalate-only policy

    /// **Escalate-only, positive:** a provider claiming `readOnly` for a tool local policy marks
    /// `destructive` is confirmed, not auto-run.
    ///
    /// The gate must not trust the thing it gates (`spec.md`). The auto-run path is *attempted* —
    /// submitted with no confirmation, exactly as a read-only action legitimately would be — and
    /// required to come back refused. A gate that read the provider's claim and stopped there would
    /// invoke here, and the stub would fail the test at the invocation.
    func testAReadOnlyClaimIsConfirmedWhenLocalPolicyMarksTheToolDestructive() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .readOnly,
            behavior: .failsTheTestIfInvoked)
        let policy = ActionRadiusPolicy([
            ActionRadiusPolicy.Floor(invocation: invocation, radius: .destructive)
        ])

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]), policy: policy)

        XCTAssertEqual(
            decision,
            .confirmationRequired(
                ActionSummary(
                    sentence: "Stub would run delete-downloads on dev.vocca.stub.",
                    blastRadius: .destructive)),
            "the under-declared tool is confirmed rather than run, and the decision carries the "
                + "radius the gate acted on — the provider's sentence with the policy's floor, not "
                + "the claim the gate refused to believe")
        XCTAssertEqual(
            provider.invokeCount, 0,
            "a provider that under-declares to skip confirmation does not skip it")
    }

    /// **Escalate-only, negative:** no input produces a radius below the provider's claim, over
    /// every combination of claim and floor.
    ///
    /// This is the safety argument stated so it can be checked rather than believed: a lying
    /// provider can only cause the user to be asked *more* often than necessary, never less. The
    /// sweep is exhaustive over ``BlastRadius/allCases`` squared — nine combinations plus the
    /// no-policy case — and the ordering it measures against is written independently at the top of
    /// this file.
    func testNoPolicyInputEverProducesARadiusBelowTheProvidersClaim() throws {
        let invocation = try makeInvocation()

        for claimed in BlastRadius.allCases {
            XCTAssertEqual(
                ActionRadiusPolicy.none.effectiveRadius(for: invocation, claiming: claimed),
                claimed,
                "with no local floor the claim stands unchanged")

            for floor in BlastRadius.allCases {
                let policy = ActionRadiusPolicy([
                    ActionRadiusPolicy.Floor(invocation: invocation, radius: floor)
                ])
                let effective = policy.effectiveRadius(for: invocation, claiming: claimed)

                XCTAssertGreaterThanOrEqual(
                    reach(effective), reach(claimed),
                    "a floor of \(floor) under a claim of \(claimed) produced \(effective), which "
                        + "reaches less far than the claim — the policy de-escalated, and a gate "
                        + "that can be talked down is not a gate")
                XCTAssertEqual(
                    reach(effective), max(reach(claimed), reach(floor)),
                    "the effective radius is whichever of the two reaches further, and never a "
                        + "third value")
                if effective.requiresConfirmation {
                    XCTAssertTrue(
                        claimed.requiresConfirmation || floor.requiresConfirmation,
                        "confirmation is never demanded out of nowhere")
                }
                if claimed.requiresConfirmation {
                    XCTAssertTrue(
                        effective.requiresConfirmation,
                        "a claim that required confirmation still does — the one direction that "
                            + "would be a bypass")
                }
            }
        }
    }

    /// A floor applies to the tool it names and to no other.
    ///
    /// Without this the escalate-only rule could be satisfied by a policy that escalated
    /// everything, which would be monotone, useless, and would make every read-only action prompt.
    func testALocalFloorAppliesOnlyToTheToolItNames() throws {
        let floored = try makeInvocation(toolID: "delete-downloads")
        let other = try makeInvocation(toolID: "list-files")
        let policy = ActionRadiusPolicy([
            ActionRadiusPolicy.Floor(invocation: floored, radius: .outwardFacing)
        ])

        XCTAssertEqual(
            policy.effectiveRadius(for: floored, claiming: .readOnly), .outwardFacing,
            "the named tool is escalated to its floor")
        XCTAssertEqual(
            policy.effectiveRadius(for: other, claiming: .readOnly), .readOnly,
            "an unnamed tool keeps the provider's claim — the floor is per tool, not a blanket")
    }

    /// A policy the gate is handed does not lower a claim the provider made: a `destructive` tool
    /// with a `readOnly` floor still confirms.
    ///
    /// The negative sweep above proves this of the policy in isolation; this proves it of the gate,
    /// which is where a de-escalation would actually cause harm.
    func testAReadOnlyFloorCannotLowerADestructiveClaimAtTheGate() async throws {
        let invocation = try makeInvocation()
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive,
            behavior: .failsTheTestIfInvoked)
        let policy = ActionRadiusPolicy([
            ActionRadiusPolicy.Floor(invocation: invocation, radius: .readOnly)
        ])

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]), policy: policy)

        XCTAssertFalse(
            decision.reachedTheProvider,
            "a local policy is a floor, never a ceiling — the destructive claim is the thing that "
                + "stands")
        XCTAssertEqual(provider.invokeCount, 0)
    }

    // MARK: - 8. A provider whose work is genuinely asynchronous (`async-seam`)

    /// **A provider that genuinely suspends can be driven through the gate** — the capability
    /// this aspect exists to add, asserted directly rather than inferred from a signature.
    ///
    /// ``SuspendingActionProvider`` is an `actor`: its isolated operations are reachable only
    /// through an `await`, so under the previous synchronous seam this conformance could not be
    /// written at all — which is precisely why a second real provider, backed by the audit store
    /// (itself an actor), could not be written either. Both halves are exercised: the gate
    /// awaits `describe` for the sentence it branches on, and awaits `invoke` for the outcome it
    /// reports, and the suspension count says the suspensions actually happened rather than
    /// merely being spelled.
    ///
    /// The configured outcome is a *failure*, deliberately: a suspending provider that could
    /// only succeed would leave "the outcome survives the suspension" resting on the one value
    /// a dropped result might plausibly default to.
    func testAProviderThatGenuinelySuspendsIsDrivenThroughTheGate() async throws {
        let invocation = try makeInvocation()
        let provider = SuspendingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive,
            outcome: .failed(reasonKey: "suspending.diskFull"))

        let decision = await ActionGate.submit(
            invocation, to: provider, enablement: ActionEnablement([invocation]),
            approval: .granted)

        XCTAssertEqual(
            decision,
            .invoked(
                summary: ActionSummary(
                    sentence: "Suspending stub would run delete-downloads on dev.vocca.stub.",
                    blastRadius: .destructive),
                outcome: .failed(reasonKey: "suspending.diskFull")),
            "the gate awaited both halves of an actor-backed provider and reported what each "
                + "returned — the whole of what the asynchronous seam buys")
        let describeCount = await provider.describeCount
        let invokeCount = await provider.invokeCount
        let suspensionCount = await provider.suspensionCount
        XCTAssertEqual(describeCount, 1, "the sentence came from the provider, once")
        XCTAssertEqual(invokeCount, 1, "and the acting half really was reached")
        XCTAssertEqual(
            suspensionCount, 2,
            "both operations genuinely suspended — 'asynchronous' here is behaviour, not a "
                + "keyword a synchronous body could have worn")
    }

    /// **Suspension does not turn the refusal into a race.**
    ///
    /// The load-bearing refusal, re-asserted against a provider that suspends inside the gate's
    /// own call, and against eight submissions in flight at once. A gate that had become
    /// re-entrant across its suspension points — deciding on state observed before an `await`
    /// and acting on it after — would show up here as an acting count above zero. The refusal is
    /// still made by *attempting the call*: each submission is a destructive invocation of an
    /// enabled tool with no approval, exactly the bypass C13 requires to be denied.
    ///
    /// `describeCount` is asserted at eight rather than ignored: it is the vacuity guard. Eight
    /// submissions that never reached the provider at all would report an invoke count of zero
    /// for the wrong reason.
    func testASuspendingProviderIsStillRefusedWithoutAConfirmation() async throws {
        let invocation = try makeInvocation()
        let provider = SuspendingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .destructive)
        let enablement = ActionEnablement([invocation])
        let submissions = 8

        let decisions = await withTaskGroup(of: ActionDecision.self) { group in
            for _ in 0..<submissions {
                group.addTask {
                    await ActionGate.submit(invocation, to: provider, enablement: enablement)
                }
            }
            var collected: [ActionDecision] = []
            for await decision in group {
                collected.append(decision)
            }
            return collected
        }

        let refusal = ActionDecision.confirmationRequired(
            ActionSummary(
                sentence: "Suspending stub would run delete-downloads on dev.vocca.stub.",
                blastRadius: .destructive))
        XCTAssertEqual(decisions.count, submissions, "every submission came back")
        XCTAssertEqual(
            decisions, Array(repeating: refusal, count: submissions),
            "every one of them was refused, carrying the sentence a human would be shown — the "
                + "refusal is a property of each decision, not of there having been only one in "
                + "flight")

        let invokeCount = await provider.invokeCount
        let describeCount = await provider.describeCount
        XCTAssertEqual(
            invokeCount, 0,
            "the number C13's acceptance reads, unchanged by the provider suspending inside the "
                + "gate's own call")
        XCTAssertEqual(
            describeCount, submissions,
            "vacuity guard: the provider really was asked what each one would do — a zero read "
                + "from a provider nothing ever reached would be evidence of nothing")
    }
}
