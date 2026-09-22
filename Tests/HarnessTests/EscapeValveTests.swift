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

/// **The §8 floor — the never-silenceable blast-radius floor** (`intent-layer` PRD R6; spec
/// acceptance 6): an outward-facing tool always confirms. No approval value, policy floor, mode,
/// or future trust mechanism can auto-run it — the floor is pinned at the gate level, the
/// `BlastRadius.requiresConfirmation` single branch point named by name
/// (`BlastRadius.swift:56-63`), and enumerated over every shape a submission can take.
///
/// ## What "never auto-runs" means, precisely
///
/// The gate is the escape valve: the only route from an utterance to a provider's acting half.
/// The enumeration asserts that an outward-facing invocation is `.invoked` **iff** the submission
/// carries a human's granted approval and a live mode — the sanctioned human-yes shape — and that
/// every other shape stops (`confirmationRequired` / `previewed` / `declined`). A future trust
/// mechanism that wanted to auto-run an outward-facing tool would have to change
/// ``BlastRadius/requiresConfirmation`` (pinned by name below), or reach the provider without
/// ``ActionGate`` (which the family lint already refuses structurally), or grant without a human —
/// the one thing ``ActionApproval`` cannot express.
///
/// ## Why the wiring's own floor stays `.none` (the recorded decision)
///
/// The §8 floor is not today's local policy. The wiring's floor is
/// ``ActionRadiusPolicy/none`` — the recorded decision `ActionWiring.swift:203` — because a
/// stricter *current* floor would force confirmation on genuinely read-only tools and break M3's
/// read-only-runs-directly contract. What the §8 floor pins is that **the radius itself** can
/// never be silenced: the floor's escalation can only ever raise a claim
/// (``ActionRadiusPolicy/escalated(_:by:)``), so the raising-floor leg below is included in the
/// enumeration to show that even the strongest policy the wiring may ever carry cannot push an
/// outward-facing claim down to auto-run.
@MainActor
final class EscapeValveTests: XCTestCase {

    /// The fixture invocation the outward-facing stub serves.
    private static let invocation = ActionInvocation(
        providerID: "dev.vocca.stub", toolID: "delete-downloads")!

    /// **The branch point, pinned by name** — the §8 floor's whole claim in one property: an
    /// outward-facing radius requires a confirmation; read-only is the one case that may run
    /// directly (M3).
    func testTheOutwardFacingRadiusRequiresConfirmationByName() {
        XCTAssertTrue(
            BlastRadius.outwardFacing.requiresConfirmation,
            "the §8 floor: an outward-facing tool always confirms — this single branch point "
                + "(BlastRadius.swift:56-63) is the floor, and no policy, approval or mode may "
                + "silence it")
        XCTAssertTrue(
            BlastRadius.destructive.requiresConfirmation,
            "destructive is treated identically today — the floor covers it by the same branch")
        XCTAssertFalse(
            BlastRadius.readOnly.requiresConfirmation,
            "read-only is the one case that may run directly (M3) — the floor is that the "
                + "outward-facing claim is never among them")
    }

    /// **The enumeration: an outward-facing invocation never auto-runs.** Every approval value
    /// (`.withheld` / `.granted`), every policy floor (`.none` and a raising floor), every mode
    /// (`.live` / `.dryRun`) — the acting half is reached exactly when a human granted **and**
    /// the mode is live, and not one other shape.
    func testAnOutwardFacingInvocationNeverAutoRunsUnderAnyShape() async throws {
        let invocation = Self.invocation
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .outwardFacing)
        let enablement = ActionEnablement([invocation])
        let raising = ActionRadiusPolicy([
            ActionRadiusPolicy.Floor(invocation: invocation, radius: .outwardFacing)
        ])
        let policies: [(name: String, policy: ActionRadiusPolicy)] = [
            ("none", .none), ("raising", raising),
        ]
        let approvals: [(name: String, approval: ActionApproval)] = [
            ("withheld", .withheld), ("granted", .granted),
        ]
        let modes: [(name: String, mode: ActionGate.Mode)] = [
            ("live", .live), ("dryRun", .dryRun),
        ]

        for (policyName, policy) in policies {
            for (approvalName, approval) in approvals {
                for (modeName, mode) in modes {
                    let decision = await ActionGate.submit(
                        invocation, to: provider, enablement: enablement,
                        policy: policy, approval: approval, mode: mode)
                    let label = "approval=\(approvalName) policy=\(policyName) mode=\(modeName)"
                    if approval == .granted && mode == .live {
                        guard case .invoked = decision else {
                            XCTFail(
                                "\(label): the granted+live shape is the one sanctioned "
                                    + "shape — the human's yes, bound to the shown sentence")
                            continue
                        }
                    } else {
                        XCTAssertFalse(
                            decision.reachedTheProvider,
                            "\(label): an outward-facing invocation never auto-runs — no "
                                + "approval value, policy floor or mode may reach invoke "
                                + "without a human yes")
                    }
                }
            }
        }

        XCTAssertEqual(
            provider.invokeCount, 2,
            "exactly the two human-yes shapes reached the acting half — granted + live under "
                + "both policy floors; every other shape stopped")
    }

    /// **The raising-floor leg, made observable**: a floor can only escalate a provider's claim
    /// (``ActionRadiusPolicy/escalated(_:by:)`` returns one of its two arguments), so a
    /// read-only-claiming tool that a floor raises to destructive must confirm — the escalation
    /// that turns a lying claim into an ask is the same direction the §8 floor relies on, and
    /// the floor can never push outward-facing down.
    func testARaisingFloorEscalatesAReadOnlyClaimIntoConfirmation() async throws {
        let invocation = Self.invocation
        let provider = RecordingActionProvider(
            toolIDs: ["delete-downloads"], describedRadius: .readOnly)
        let enablement = ActionEnablement([invocation])

        // M3's sanctioned direct run: with no floor, a genuinely read-only claim runs without
        // being asked — the one case `requiresConfirmation` answers false for.
        let direct = await ActionGate.submit(
            invocation, to: provider, enablement: enablement, policy: .none,
            approval: .withheld, mode: .live)
        guard case .invoked = direct else {
            return XCTFail("read-only is the one case that may run directly (M3)")
        }

        // The same claim under a raising floor: escalated to destructive, it confirms — a lying
        // provider can only cause the user to be asked more often, never less, and the §8 floor
        // is the same monotonicity at the top of the range.
        let raising = ActionRadiusPolicy([
            ActionRadiusPolicy.Floor(invocation: invocation, radius: .destructive)
        ])
        let escalated = await ActionGate.submit(
            invocation, to: provider, enablement: enablement, policy: raising,
            approval: .withheld, mode: .live)
        guard case .confirmationRequired = escalated else {
            return XCTFail(
                "a raising floor must escalate a readOnly claim into confirmation — the "
                    + "escalate-only rule, measured")
        }
    }
}