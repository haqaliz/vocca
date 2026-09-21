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

// MARK: - The human's answer

/// Whether a human said yes to **this one** invocation (`action-safety-spine` PRD M4a).
///
/// The caller supplies it, because only the layer that drew a prompt knows what the person
/// answered. That is not the bypass it might look like: granting an approval is not the same as
/// reaching a provider. The only thing that can hand ``ActionProvider/invoke(_:confirmation:)`` the
/// ``ActionConfirmation`` it demands is ``ActionGate``, so an approval is a request to open the
/// gate, never a way around it — and the gate still applies enablement, the mode and the local
/// radius policy before it mints anything.
///
/// **It carries no payload, deliberately.** An approval asserts that a human said yes to **this**
/// invocation; it cannot verify it (N2). `sentence-binding` (C13 slice 5) narrows what the
/// assertion can be *replayed against* — ``ActionGate/submit(_:to:enablement:policy:approval:mode:approvedSentence:)``
/// takes the exact sentence the person was shown as an argument, and refuses the moment its own
/// freshly-rendered sentence differs. The binding lives on the submission, not in this type, so
/// per-invocation stays structural: the approval is an *argument*, existing for the duration of
/// one call, and a second invocation that wants to act needs a second argument. "Don't ask me
/// again" has no representation in this type.
public enum ActionApproval: Sendable {
    /// No one has said yes. **The default**, and the answer a caller that forgot to ask gives.
    case withheld

    /// A human was shown the sentence and approved this invocation.
    case granted
}

// MARK: - Per-tool enablement

/// Which tools may act at all — **default off, and off is the empty set** (PRD M7 / N1).
///
/// A pure value passed into the gate rather than state the gate owns, for the same reason
/// ``ContextGrantGate`` owns nothing: a gate that remembered would have two answers to "is this
/// tool enabled" — the one it was told and the one it kept — and the older one would eventually
/// win. Enabling and disabling produce new values, so "enabled a moment ago" cannot leak into the
/// next decision.
///
/// Membership is by whole ``ActionInvocation``, not by tool id alone: two providers may serve the
/// same tool name, and enabling one of them must not enable the other. It is an array rather than
/// a `Set` because `ActionInvocation` is `Equatable` and not `Hashable`, and this aspect is not the
/// place to widen the seam's vocabulary for a membership test over a handful of tools.
public struct ActionEnablement: Sendable, Equatable {

    /// Nothing is enabled. The shipped posture, and what a caller with nothing to say should pass.
    public static let none = ActionEnablement()

    private let enabled: [ActionInvocation]

    /// - Parameter enabled: The invocations that may act. Defaults to none — the safe default is
    ///   the one a caller that omitted the argument gets.
    public init(_ enabled: [ActionInvocation] = []) {
        self.enabled = enabled
    }

    /// Whether `invocation` may act. **Absent is off** — there is no third state between enabled
    /// and disabled for a decision to fall through.
    public func isEnabled(_ invocation: ActionInvocation) -> Bool {
        enabled.contains(invocation)
    }

    /// The same set with `invocation` enabled. Enabling twice is enabling once.
    public func enabling(_ invocation: ActionInvocation) -> ActionEnablement {
        guard !isEnabled(invocation) else { return self }
        return ActionEnablement(enabled + [invocation])
    }

    /// The same set with `invocation` disabled.
    public func disabling(_ invocation: ActionInvocation) -> ActionEnablement {
        ActionEnablement(enabled.filter { $0 != invocation })
    }
}

// MARK: - The local radius policy

/// The local floor under a provider's blast-radius claim — **escalate-only** (`spec.md`, added
/// 2026-09-19).
///
/// ``ActionSummary/blastRadius`` is the provider's own claim about its own tool, and nothing
/// verifies it. A gate that trusts the thing it gates is not a gate, so the radius the gate acts on
/// is the claim raised by whatever local floor applies, and **never lowered by anything**.
///
/// ## Why the monotonicity is structural rather than stated
///
/// ``escalated(_:by:)`` returns one of its two arguments and returns the floor only when the floor
/// reaches strictly further, so its result can never rank below the claim — whatever the floors
/// table happens to contain, however a later edit fills it in. The table decides *how far up*, and
/// that is all it can decide; there is no path by which a lookup returns a value and that value
/// becomes the answer. The safety argument this buys, in one line: **a lying provider can only
/// cause the user to be asked more often than necessary, never less.**
public struct ActionRadiusPolicy: Sendable, Equatable {

    /// One local floor: a tool, and the radius it is treated as reaching **at least**.
    public struct Floor: Sendable, Equatable {
        /// The invocation this floor names. A floor applies to that tool and to no other.
        public let invocation: ActionInvocation

        /// The radius the gate treats the tool as reaching at minimum, whatever the provider says.
        public let radius: BlastRadius

        public init(invocation: ActionInvocation, radius: BlastRadius) {
            self.invocation = invocation
            self.radius = radius
        }
    }

    /// No local floors: every claim stands as the provider made it.
    public static let none = ActionRadiusPolicy()

    private let floors: [Floor]

    /// - Parameter floors: The local floors. Order is immaterial — the fold only ever escalates,
    ///   so the result is the same whichever way the table is read.
    public init(_ floors: [Floor] = []) {
        self.floors = floors
    }

    /// The radius the gate acts on: `claimed`, raised by every floor naming `invocation`.
    ///
    /// - Returns: A radius that reaches **at least as far as `claimed`**, always. That is not a
    ///   promise about this table's contents; it is a property of ``escalated(_:by:)``, which
    ///   cannot return anything ranking below what it was given.
    public func effectiveRadius(for invocation: ActionInvocation, claiming claimed: BlastRadius)
        -> BlastRadius
    {
        var effective = claimed
        for floor in floors where floor.invocation == invocation {
            effective = Self.escalated(effective, by: floor.radius)
        }
        return effective
    }

    /// Whichever of the two reaches further — **the one place the escalate-only rule lives**.
    ///
    /// The result is one of the two arguments and never a third value: there is no rank-to-case
    /// mapping here that a later edit could make return something unrelated. `floor` wins only when
    /// it reaches strictly further, so `escalated(r, by: anything)` always reaches at least as far
    /// as `r`, which is the whole of the rule.
    static func escalated(_ radius: BlastRadius, by floor: BlastRadius) -> BlastRadius {
        reach(of: floor) > reach(of: radius) ? floor : radius
    }

    /// How far a radius reaches, as an order: read-only < destructive < outward-facing.
    ///
    /// The spec's table, as a total order. Exhaustive rather than `default`-terminated so a fourth
    /// ``BlastRadius`` case has to be placed in this order by hand, in review, instead of
    /// inheriting whichever rank a default returned — a new case silently ranking 0 would be a
    /// silent de-escalation of exactly the kind this type exists to make impossible.
    private static func reach(of radius: BlastRadius) -> Int {
        switch radius {
        case .readOnly: return 0
        case .destructive: return 1
        case .outwardFacing: return 2
        }
    }
}

// MARK: - The decision

/// Why the gate declined before reaching a provider at all.
///
/// A closed enum with a bounded ``reasonKey``, so the audit log records a key and never a message:
/// `VoccaCore` imports nothing to build one from, and an entry that is byte-pinned cannot carry
/// free-form text. Two cases today; a third is a reviewed edit here rather than a string invented
/// at a call site.
public enum ActionDeclineReason: Sendable, Equatable {
    /// The tool is not in the enablement set. Default off means **absent is off**.
    case toolNotEnabled

    /// A granted approval was bound to a sentence the gate no longer renders (`sentence-binding`,
    /// C13 slice 5). The approval cannot be replayed against a different action.
    case approvedSentenceMismatch

    /// The bounded key an audit entry records.
    public var reasonKey: String {
        switch self {
        case .toolNotEnabled: return "gate.toolNotEnabled"
        case .approvedSentenceMismatch: return "gate.approvedSentenceMismatch"
        }
    }
}

/// What the gate decided — **the whole of what a submission can produce**.
///
/// ## Refusal is not failure, and the type says so
///
/// Only ``invoked(summary:outcome:)`` carries an ``ActionOutcome``, because only that case reached
/// a provider. A refusal has no outcome to carry: nothing was attempted, so nothing succeeded or
/// failed. That is deliberate and load-bearing — the audit log's one real question is *did this
/// actually run*, and a refusal modelled as ``ActionOutcome/failed(reasonKey:)`` would answer "it
/// tried and something went wrong" about an action Vocca stopped on purpose (R8).
///
/// ## The summary a refusal carries, and the one it does not
///
/// ``confirmationRequired(_:)`` and ``previewed(_:)`` carry a summary because `describe` was
/// called — a person cannot be asked about a sentence nobody rendered. ``declined(_:)`` carries
/// none, and *cannot*: the provider was never asked, so no summary exists to put there. The
/// never-read property is therefore visible in the shape of the type and not only in the order of
/// the checks.
///
/// The radius on a carried summary is the radius the **gate acted on** — the provider's sentence
/// with the local policy's floor applied. Carrying the claim the gate had already refused to
/// believe would be two copies of one fact with the wrong one on display.
public enum ActionDecision: Sendable, Equatable {
    /// Declined before any provider call. Nothing was described and nothing ran.
    case declined(ActionDeclineReason)

    /// Described, and stopped: this action needs a human yes it did not have.
    case confirmationRequired(ActionSummary)

    /// Dry-run. Described only; the acting half was not reached (PRD M5/G2).
    case previewed(ActionSummary)

    /// The provider was reached. Carries what was described and what came of it.
    case invoked(summary: ActionSummary, outcome: ActionOutcome)

    /// Whether the acting half of the seam was reached at all.
    ///
    /// The single predicate a caller — or an audit entry — should read to answer "did this run".
    /// Note that a reached provider may still have declined to serve the call: see
    /// ``ActionOutcome/notInvoked``, which is the *provider's* refusal and not the gate's.
    public var reachedTheProvider: Bool {
        switch self {
        case .invoked: return true
        case .declined, .confirmationRequired, .previewed: return false
        }
    }

    /// What the provider returned, or `nil` when it was never reached.
    ///
    /// `nil` is the honest answer for every refusal: there is no outcome, rather than an outcome
    /// meaning nothing happened.
    public var outcome: ActionOutcome? {
        switch self {
        case .invoked(_, let outcome): return outcome
        case .declined, .confirmationRequired, .previewed: return nil
        }
    }

    /// The sentence and radius the gate acted on, or `nil` when nothing was ever described.
    public var summary: ActionSummary? {
        switch self {
        case .confirmationRequired(let summary), .previewed(let summary): return summary
        case .invoked(let summary, _): return summary
        case .declined: return nil
        }
    }
}

// MARK: - The gate

/// The one decision point between an utterance and anything actually happening
/// (`action-safety-spine` PRD M4/M5/M7, C13).
///
/// A pure function of everything it is given — the `ContextGrantGate` shape: no state, no I/O,
/// nothing owned. Enablement, the local policy, the human's answer and the mode all arrive as
/// arguments, so two submissions of the same tool are two independent decisions with nothing
/// carried between them.
///
/// ## Why this is the only file in the tree that mints an ``ActionConfirmation``
///
/// ``ActionProvider/invoke(_:confirmation:)`` cannot be called without a token, the token's
/// initializer is `internal` to `VoccaCore`, and `ActionSeamBoundaryTests`' Family B confines its
/// construction to this file across `Sources/` **and** `Tests/` alike. The three together mean
/// there is no route to a provider's acting half that does not pass through ``submit(_:to:_:_:_:)``
/// — not a rule to remember and not a check to forget, but an absence of any expressible
/// alternative. R8's "Fatal (trust)" failure is closed by the type system and a lint rather than by
/// discipline.
///
/// ## No parameter of ``submit(_:to:enablement:policy:approval:mode:)`` grants by omission
///
/// Three of its arguments decide how far an action may go, and **none of them may be acquired by
/// not typing it**. `enablement` has never had a default. `approval` defaults to
/// ``ActionApproval/withheld``, because a caller that forgot to ask has not asked. `policy` had
/// defaulted to ``ActionRadiusPolicy/none`` until `mcp-provider` (2026-09-20), and that default
/// was the odd one out: it *granted*. With no floor, a provider's own blast-radius claim stands —
/// so an MCP server declaring `readOnlyHint: true` for a tool that deletes things auto-ran it,
/// and the only thing the caller had done wrong was omit an argument.
///
/// That made the escalate-only rule opt-in by omission, which is the opposite of what it is for:
/// the rule exists *because* provider claims are untrusted, and a protection that applies only
/// when someone remembers to ask for it protects the callers who were never going to be the
/// problem. ``ActionRadiusPolicy/none`` remains a legitimate answer — trusting a server is a real
/// configuration — but it is now a choice read in review rather than an absence nobody sees. The
/// absence of the default is pinned by a lint, because Swift cannot express it in a type.
///
/// `mode` keeps its default, and the asymmetry is the point: ``Mode/live`` is what a submission
/// *is*, and ``Mode/dryRun`` is the special request. A default that grants nothing extra — a live
/// submission still faces enablement, the policy and the confirmation — is not the same kind of
/// default as one that removes a floor.
///
/// ## The order of the checks, and why it is this order
///
/// 1. **Enablement, before anything is asked of the provider.** A disabled tool is declined without
///    a `describe` call — never read, rather than read and discarded (the C12 `ContextConsentGate`
///    precedent). Disabled therefore beats dry-run: a preview looks harmless, which is exactly why
///    a tool nobody enabled must not be asked what it would do.
/// 2. **Describe, then the local policy.** The radius the gate branches on is the provider's claim
///    raised by ``ActionRadiusPolicy`` and never lowered by it.
/// 3. **Mode, before the approval is read.** A dry-run does not act even when an approval was
///    granted; otherwise previewing an already-approved action would perform it.
/// 4. **The sentence binding, when the approval names one.** ``ActionApproval/granted`` with a
///    non-nil ``submit(_:to:enablement:policy:approval:mode:approvedSentence:)/approvedSentence``
///    is an approval bound to exactly that sentence, and the gate refuses it the moment its own
///    freshly-rendered sentence differs (`sentence-binding`, C13 slice 5). This is read before the
///    confirmation branch because it applies at every radius — the caller chose the binding, and
///    the binding is the caller's contract with the human, not the radius's.
/// 5. **Confirmation, last.** ``BlastRadius/requiresConfirmation`` is the one branch point, read
///    from the effective radius.
///
/// ## The suspension changes none of that
///
/// ``submit(_:to:_:_:_:)`` is `async` because the seam it calls is (`async-seam`, 2026-09-19).
/// The order above is unchanged and so is the never-read property: the enablement guard runs
/// before the first `await`, so a disabled tool is declined without the gate ever suspending into
/// the provider. The gate still owns no state — everything it decides on arrives as an argument
/// and lives in a local — so two submissions in flight at once are two independent decisions with
/// nothing observable between them, which is what keeps the refusal from becoming a race.
public enum ActionGate {

    /// Whether a submission may act, or is only rehearsing.
    public enum Mode: Sendable {
        /// The action runs if everything permits it.
        case live

        /// Describe only. ``ActionProvider/invoke(_:confirmation:)`` is reached zero times,
        /// whatever else is true of the submission (PRD M5/G2).
        case dryRun
    }

    /// Submits an invocation to a provider, and decides.
    ///
    /// - Parameters:
    ///   - invocation: The provider and tool being asked for.
    ///   - provider: The seam the call would reach. Its ``ActionProvider/describe(_:)`` is called
    ///     only once the tool is known to be enabled.
    ///   - enablement: Which tools may act. No default: a caller must say, and default off is what
    ///     they should usually say.
    ///   - policy: The local floors under the provider's claim. Escalate-only. **No default,
    ///     for the same reason `enablement` has none** — a floor the caller did not choose is not
    ///     a floor. ``ActionRadiusPolicy/none`` is a legitimate answer and means the provider's
    ///     claim stands unraised; it is simply one that has to be said out loud.
    ///   - approval: Whether a human said yes to **this** invocation. Defaults to
    ///     ``ActionApproval/withheld`` — a caller that forgot to ask has not asked.
    ///   - approvedSentence: The exact sentence the human was shown when they approved, or `nil`
    ///     for no binding. With a non-nil value and ``ActionApproval/granted``, the gate refuses
    ///     the moment its own freshly-rendered sentence differs — the approval cannot be replayed
    ///     against a different action. The N2 narrowing, stated: the approval asserts a human
    ///     said yes; the binding narrows what that yes can be replayed against; that the human
    ///     *saw* the sentence is asserted by the UI layer that drew the card, which the gate
    ///     cannot verify. `nil` grants nothing: the gate decides exactly as it did before this
    ///     parameter existed.
    ///   - mode: Live or dry-run. Defaults to live, because a caller that means to rehearse says so.
    /// - Returns: The decision. Only ``ActionDecision/invoked(summary:outcome:)`` reached the
    ///   provider.
    public static func submit(
        _ invocation: ActionInvocation,
        to provider: some ActionProvider,
        enablement: ActionEnablement,
        policy: ActionRadiusPolicy,
        approval: ActionApproval = .withheld,
        approvedSentence: String? = nil,
        mode: Mode = .live
    ) async -> ActionDecision {
        // 1. Never-read: an unenabled tool is not asked what it would do. Before the first
        //    `await` — the gate does not suspend into a provider it has already declined.
        guard enablement.isEnabled(invocation) else {
            return .declined(.toolNotEnabled)
        }

        // 2. The provider's sentence, with the radius the gate will actually act on.
        let described = await provider.describe(invocation)
        let summary = ActionSummary(
            sentence: described.sentence,
            blastRadius: policy.effectiveRadius(
                for: invocation, claiming: described.blastRadius))

        // 3. A rehearsal stops here, approved or not.
        guard case .live = mode else {
            return .previewed(summary)
        }

        // 4. The sentence binding: a granted approval that names a sentence is bound to it. The
        //    comparison is against the decision's own summary — the sentence this submission
        //    would act on — so no provider call is added. Withheld approvals carry no binding;
        //    the existing confirmation path decides them.
        if approval == .granted, let approvedSentence, approvedSentence != summary.sentence {
            return .declined(.approvedSentenceMismatch)
        }

        // 5. The one branch point, read from the effective radius.
        if summary.blastRadius.requiresConfirmation {
            guard case .granted = approval else {
                return .confirmationRequired(summary)
            }
        }

        return .invoked(
            summary: summary,
            outcome: await provider.invoke(invocation, confirmation: ActionConfirmation()))
    }
}
