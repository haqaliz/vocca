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

import OSLog
import Synchronization
import VoccaActions
import VoccaCore
import VoccaUI

/// **The intent-layer voice-action composition** (`action-round-trip`, `intent-layer` PRD R5):
/// the closures the composition root assigns to the converse driver's intent slots — the
/// resolution of a cleaned utterance over the enablement catalog, and the action leg that runs
/// the existing executor → card → confirm/decline round trip from a spoken `.toolCall`.
///
/// The closures are the wiring's own vocabulary, not a parallel seam: each is the recipe's
/// answer over the shipped seams (``ActionConfigStore``, ``ActionExecutor``, ``ActionGate``, the
/// widget store's card folds), so a consumer compiles against the composition rather than
/// against the modules the composition wires.
///
/// ## The provider is the recipe's parameter, never a special case
///
/// The struct is generic over the ``ActionProvider`` the executor submits to — the same shape as
/// ``ActionWiring`` — so the shipped composition wires the real `AuditActionProvider` and a
/// probe or a test wires its own. The voice path drives ``ActionProvider`` + ``ActionGate`` and
/// nothing else.
///
/// ## The catalog is the enablement, never-read at the intent level (R3)
///
/// ``resolve`` builds the resolver's catalog from exactly the rows
/// ``ActionConfigStore/loadEnablement()`` reads — the same store call, the same construction
/// tolerance — so a disabled tool is never resolved to, never described, never called (M7
/// extends to the intent step). The resolver itself never invents a tool the catalog does not
/// name.
///
/// ## The human leg is the surface's own
///
/// ``performAction`` presents the card and speaks the terminal acks; the card's Confirm and
/// Decline are the **existing** ``ActionWiring`` closures the composition root assigns to its
/// slots — the same widget store, the same executor, the same generation guard and sentence
/// binding. The voice leg supplies no second confirmation path; it opens the same door the
/// Actions tab's arm opens.
///
/// /// ## The spoken acks are derived from the decision
///
/// A terminal decision answers the utterance: confirmed → "Done."; declined → "Cancelled.";
/// `auditRecorded == false` → the bounded failure copy, **never** a success ack; refused or
/// not-invoked → silent. The exact copy is provisional until the founder's real run (SMOKE
/// 148-149); the record aspect owns the final text.
///
/// ## The handler carries the utterance (`utterance-threading`)
///
/// ``performAction`` receives the cleaned utterance the resolution came from — the driver's
/// widened signature, the words in scope at its call site. The enrichment fills an agent
/// row's `<task>` placeholder with the **full** utterance (the trigger words stay in the
/// task; the audit records exactly what was said); a non-agent tool is enriched with
/// nothing — `taskText` nil, byte-identical to today. A placeholder row reached **without**
/// an utterance is refused before the card: the declined ack is spoken, the withheld
/// submission records the refused decision, no card is ever presented and the engine is
/// never reached (critique gap 2 — the provider's own refusal would ask a human to approve
/// a refusal).
public struct IntentWiring<Provider: ActionProvider>: Sendable {

    /// Resolves a cleaned utterance against the enabled-tool catalog — the driver's intent
    /// slot. `.none` and `.ask` fall through to the driver's existing reply handling; only a
    /// `.toolCall` is acted on.
    public let resolve: @Sendable @MainActor (String) async -> IntentResolution

    /// The action leg — the driver's handler slot. Submits the invocation through the executor
    /// with the approval withheld (the voice path never pre-grants), presents the card when the
    /// gate asks, and returns the spoken ack for a terminal decision (`nil` for silence).
    ///
    /// **Carries the utterance** (`utterance-threading`): the cleaned words the resolution
    /// came from, passed verbatim — the wiring enriches an agent row whose argv carries the
    /// `<task>` placeholder with them, and refuses before the card when a placeholder row is
    /// reached without one.
    public let performAction: @Sendable @MainActor (ActionInvocation, String) async -> String?

    /// The executor the voice path submits through — the same one caller of ``ActionGate`` the
    /// surface's closures use, exposed for the composition root's slot.
    public let executor: ActionExecutor<Provider>

    /// **Whether the composed intent wiring spawns a child process.** `false` — the declared
    /// value, the ``ActionWiring`` analogue: the voice path spawns nothing (D2), and a
    /// composition that wired a transport would declare it here rather than in a comment.
    public let spawnsSubprocess: Bool

    /// **The local radius floor, `.none`, recorded as a decision** — the `ActionWiring.swift:203`
    /// decision inherited by the voice leg: escalate-only means the floor can only raise, and a
    /// stricter *current* floor would force confirmation on genuinely read-only tools and break
    /// M3's read-only-runs-directly contract. The §8 floor (an outward-facing tool always
    /// confirms) is the gate's own branch point, pinned by `EscapeValveTests` — this value is
    /// the current policy, not the escape valve.
    public let policy: ActionRadiusPolicy

    public init(
        resolve: @escaping @Sendable @MainActor (String) async -> IntentResolution,
        performAction: @escaping @Sendable @MainActor (ActionInvocation, String) async -> String?,
        executor: ActionExecutor<Provider>,
        policy: ActionRadiusPolicy,
        spawnsSubprocess: Bool
    ) {
        self.resolve = resolve
        self.performAction = performAction
        self.executor = executor
        self.policy = policy
        self.spawnsSubprocess = spawnsSubprocess
    }
}

extension AppBootstrap {

    /// The generation tokens the card's stale-guard compares — minted here, at presentation.
    ///
    /// The ``ActionWiring`` recipe's mint, file-local: the closures are `@Sendable`, and a
    /// captured `var` would be shared mutable state the strict-concurrency checker refuses.
    /// Plain `Sendable` state; carries no content — a token is a comparison, nothing more.
    private final class IntentGeneration: Sendable {
        private let value = Mutex(0)

        func next() -> Int {
            value.withLock { $0 &+= 1; return $0 }
        }
    }

    /// **The intent wiring recipe** (`action-round-trip` + `probe`): the resolution and
    /// action-leg closures, composed over the shipped seams — the ``ActionExecutor`` (the
    /// composition's parameter: the shipped composition passes the **shared**
    /// `root.actionExecutor` — the same instance the surface's closures submit through, R5 —
    /// while the probe and tests pass their own over temp-directory stores), the ``ActionConfigStore``
    /// (also the composition's parameter — the shipped composition passes the real store, the
    /// probe and tests pass temp-directory stores), the injected ``ActionProvider`` (the
    /// re-render's describe source — the shipped composition passes the same instance the
    /// executor was built over; `ActionExecutor` keeps its provider private, so the recipe
    /// takes the seam it renders through), the injected ``IntentResolver``, and the widget
    /// store's card folds.
    ///
    /// ## The executor leg
    ///
    /// ``performAction`` submits with `approval: .withheld, approvedSentence: nil, mode: .live`
    /// — the voice path never pre-grants, so an outward-facing tool always reaches the
    /// confirmation gate. On `.confirmationRequired` the card is presented with the sentence
    /// **re-rendered after the record** (the count-bearing precedent, `ActionWiring.swift:291`):
    /// the executor records the decision after the gate's describe, so a provider whose sentence
    /// names the log renders a card one entry behind the truth the moment the record lands — the
    /// re-render presents the current sentence, and the existing confirm closure binds to exactly
    /// this.
    ///
    /// ## The card-up guard
    ///
    /// While the store's confirmation is non-nil, a second voice action **refuses to present** —
    /// the replacement-card hazard is the same class as the in-flight dictation guard. The
    /// refusal is read lazily from the store, per call, and records nothing: no submission, no
    /// decision, no card swap.
    ///
    /// ## The recording-failure rule
    ///
    /// A decision whose record failed (`auditRecorded == false`) is **never presented as a card
    /// and never acknowledged as a success**: the failure copy is the answer, because a card
    /// that could be approved through a log the record did not land in would be a second hole on
    /// top of the lost record. The executor has already logged loudly; this is the spoken half.
    ///
    /// ## Probe-safe by construction (the ``ActionWiring`` doc contract)
    ///
    /// Nothing here starts, reads or provisions at composition time: the executor's construction
    /// is I/O-free, the stores are consulted per call — never at composition — the resolver is
    /// obtained per call, and the card-up guard is a store read at call time, never here. The recipe names no transport, no
    /// `Process`, and no `TextInjector`; the driver's slots are filled, nothing is composed into
    /// the dictation path.
    @MainActor
    public static func composeIntentWiring<Provider: ActionProvider>(
        configStore: ActionConfigStore,
        provider: Provider,
        executor: ActionExecutor<Provider>,
        resolver: any IntentResolver,
        root: DictationLoopRoot,
        activeProjectDirectory: @escaping @Sendable () async -> String? = { nil }
    ) -> IntentWiring<Provider> {
        composeIntentWiring(
            configStore: configStore, provider: provider, executor: executor,
            resolverProvider: { resolver }, root: root,
            activeProjectDirectory: activeProjectDirectory)
    }

    /// **The intent wiring recipe over a per-turn resolver** (`phrase-intent-resolver` R5): the
    /// same recipe as the fixed-resolver form above, with the resolver obtained from
    /// `resolverProvider` **once per resolution, never at composition**. A resolver built over a
    /// file (the composed default's ``PhraseIntentResolver`` over `intent-phrases.json`) picks up
    /// an edit on the next turn without a relaunch, and composing the recipe reads nothing. The
    /// catalog is built first, from the enablement, so a disabled tool is filtered whatever the
    /// resolver holds.
    ///
    /// `activeProjectDirectory` is the arm-time resolution's twin (`agent-wiring-cwd` S2) —
    /// the same injected closure the agent arm rides, with the same nil-shaped default: the
    /// action leg enriches an empty-row invocation with the focused app's working directory,
    /// one resolution per turn, and a composition that does not wire it is byte-identical to
    /// today. The row is read through the root's `agentRegistry` slot per call — never at
    /// composition — and an explicit row is never re-resolved (G2).
    @MainActor
    public static func composeIntentWiring<Provider: ActionProvider>(
        configStore: ActionConfigStore,
        provider: Provider,
        executor: ActionExecutor<Provider>,
        resolverProvider: @escaping @Sendable @MainActor () async -> any IntentResolver,
        root: DictationLoopRoot,
        activeProjectDirectory: @escaping @Sendable () async -> String? = { nil }
    ) -> IntentWiring<Provider> {
        let generation = IntentGeneration()
        let logger = Logger(subsystem: "dev.vocca.Vocca", category: "intent-wiring")

        // The recorded floor decision — inherited from the action surface's recipe (see the
        // struct's documentation and `ActionWiring.swift:203`).
        let policy = ActionRadiusPolicy.none

        let resolve: @Sendable @MainActor (String) async -> IntentResolution = { utterance in
            // R3: the catalog is the enablement, never-read at the intent level. The rows are
            // exactly the ones `loadEnablement()` reads, with the same construction tolerance —
            // a row that cannot name an invocation is skipped, and a disabled tool has no row
            // at all, so the resolver never receives it.
            let config = await configStore.load()
            var catalog: [ToolReference] = []
            catalog.reserveCapacity(config.enablement.count)
            for row in config.enablement {
                guard
                    ActionInvocation(providerID: row.providerID, toolID: row.toolID) != nil
                else { continue }
                catalog.append(
                    ToolReference(
                        providerID: row.providerID, toolID: row.toolID, displayName: ""))
            }
            let resolver = await resolverProvider()
            return resolver.resolve(utterance, against: catalog)
        }

        let performAction: @Sendable @MainActor (ActionInvocation, String) async -> String? =
        { submitted, utterance in
            // The card-up guard, read lazily per call: one card at a time, and a second voice
            // action while a card is up refuses to present — no submission, no record, no swap.
            guard root.widgetStore.state.confirmation == nil else {
                logger.error(
                    "intent-wiring: refusing a second voice action while a confirmation card is up")
                return nil
            }

            // The S2 enrichment (`agent-wiring-cwd`, PRD R3/S1): a row whose project
            // directory is nil — the absent or blank spelling, a valid row of the file's
            // shape — is resolved **once per turn** and the invocation is rebuilt with the
            // detection; an explicit row is never re-resolved (G2). The row source is the
            // root's `agentRegistry` slot, read lazily per call — a nil read (a composition
            // that never filled the slot) enriches nothing, so the voice leg degrades to
            // the provider's own render.
            //
            // The utterance enrichment (`utterance-threading`, PRD R3) rides the same read:
            // a row whose argv carries the `<task>` placeholder is rebuilt with
            // `taskText: utterance` — the FULL utterance, trigger words and all, so the
            // audit records exactly what was said; any other tool is rebuilt with `taskText`
            // nil, byte-identical to today. A placeholder row reached **without** an
            // utterance is refused before the card — the wiring's own stop, never the
            // provider's refusal sentence asked of a human (critique gap 2).
            //
            // Both ride an **agent** invocation only (`intent-provider-routing` P2): the guard
            // below makes the row lookup the agent provider's id AND the agent's id (outside
            // the lookup, because an unmatched row still reads as blank), so another
            // provider's tool whose id collides with an agent's is never enriched, refused or
            // handed the utterance — it reaches its own provider as the resolver built it.
            var invocation = submitted
            if submitted.providerID == CodingAgentProvider.providerID,
                let registry = root.agentRegistry
            {
                let file = await registry.load()
                let agent = file.agents.first { $0.id == submitted.toolID }
                let blank = agent.map { $0.projectDirectory == nil } ?? true
                if blank,
                    let resolved = await activeProjectDirectory(),
                    let rebuilt = ActionInvocation(
                        providerID: submitted.providerID, toolID: submitted.toolID,
                        resolvedDirectory: resolved)
                {
                    invocation = rebuilt
                }
                if let agent,
                    CodingAgentSentences.argumentsContainPlaceholder(agent.arguments)
                {
                    guard !utterance.isEmpty else {
                        // The pre-card refusal: a withheld submission is the stop for want
                        // of a yes — the R8 every-decision rule (the decline-path shape),
                        // never a card and never a run. The spoken answer is the declined
                        // ack.
                        logger.error(
                            "intent-wiring: refusing a placeholder row without an utterance: \(submitted.providerID)/\(submitted.toolID)")
                        let enablement = await configStore.loadEnablement()
                        _ = await executor.submit(
                            invocation, enablement: enablement, policy: policy,
                            approval: .withheld, approvedSentence: nil, mode: .live)
                        return "Cancelled."
                    }
                    if let rebuilt = ActionInvocation(
                        providerID: submitted.providerID, toolID: submitted.toolID,
                        resolvedDirectory: invocation.resolvedDirectory,
                        taskText: utterance)
                    {
                        invocation = rebuilt
                    }
                }
            }

            let enablement = await configStore.loadEnablement()
            let decision = await executor.submit(
                invocation, enablement: enablement, policy: policy,
                approval: .withheld, approvedSentence: nil, mode: .live)

            // The loud fact first: a decision whose record failed is never presented and never
            // acknowledged as a success — the failure copy is the answer (see the recipe's
            // documentation).
            guard decision.auditRecorded else {
                logger.error(
                    "intent-wiring: the decision for \(invocation.providerID)/\(invocation.toolID) was not recorded")
                return "Something went wrong — the action was not recorded."
            }

            switch decision.decision {
            case .confirmationRequired:
                // The card, with the sentence **re-rendered after the record** — the count-bearing
                // precedent: the executor's record landed between the gate's describe and this
                // card, so the shown sentence is the current truth the confirm's own render will
                // match. The human leg is the existing confirm/decline closures over the same
                // store; nothing is spoken, the card is the answer.
                let fresh = await provider.describe(invocation)
                root.widgetStore.presentActionConfirmation(
                    WidgetConfirmationSignal(
                        sentence: fresh.sentence, providerID: invocation.providerID,
                        toolID: invocation.toolID, generation: generation.next(),
                        resolvedDirectory: invocation.resolvedDirectory,
                        taskText: invocation.taskText))
                return nil
            case .invoked(_, let outcome):
                // A read-only tool ran directly (M3) — the voice path's confirmed shape. The
                // ack derives from the outcome; the record is on disk either way.
                switch outcome {
                case .succeeded:
                    return "Done."
                case .failed:
                    return "Something went wrong."
                case .notInvoked:
                    return nil
                }
            case .declined:
                // The gate refused before any provider call (a stale enablement, a binding
                // refusal) — recorded like any other decision; the declined ack is spoken.
                return "Cancelled."
            case .previewed:
                // Unreachable from `.live`; exhaustive for the enum's own sake.
                return nil
            }
        }

        return IntentWiring(
            resolve: resolve,
            performAction: performAction,
            executor: executor,
            policy: policy,
            spawnsSubprocess: false)
    }

    /// **The intent router** (`intent-provider-routing` / `provider-dispatch` R1, R2): one
    /// wiring in the root slot's type that dispatches each resolved `.toolCall` by its
    /// providerID.
    ///
    /// A `vocca.agent` call reaches the agent wiring when one is composed; **everything else**
    /// — the agent side absent (Q3), the audit tools, shell, an unknown provider — reaches the
    /// audit wiring, whose provider fails an unserved provider closed (audited, never run).
    /// `resolve`, `executor` and `policy` are the audit wiring's; `spawnsSubprocess` is the
    /// declared `false`. The reply passes through unchanged, `nil` included — the converse
    /// wrapper reads `nil` to detect the card.
    ///
    /// ## The agent side is read lazily
    ///
    /// `agent` is consulted inside ``IntentWiring/performAction`` at call time, never at
    /// construction: the agent wiring is composed in a later launch task, after the router is
    /// already in the root slot.
    public static func routeIntentWiring(
        audit: IntentWiring<AuditActionProvider>,
        agent: @escaping @Sendable @MainActor () -> IntentWiring<CodingAgentProvider>?
    ) -> IntentWiring<AuditActionProvider> {
        let performAction: @Sendable @MainActor (ActionInvocation, String) async -> String? = {
            invocation, utterance in
            if invocation.providerID == CodingAgentProvider.providerID,
               let agentWiring = agent() {
                return await agentWiring.performAction(invocation, utterance)
            }
            return await audit.performAction(invocation, utterance)
        }

        return IntentWiring(
            resolve: audit.resolve,
            performAction: performAction,
            executor: audit.executor,
            policy: audit.policy,
            spawnsSubprocess: false)
    }
}