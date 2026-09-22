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
/// ## The spoken acks are derived from the decision
///
/// A terminal decision answers the utterance: confirmed → "Done."; declined → "Cancelled.";
/// `auditRecorded == false` → the bounded failure copy, **never** a success ack; refused or
/// not-invoked → silent. The exact copy is provisional until the founder's real run (SMOKE
/// 148-149); the record aspect owns the final text.
public struct IntentWiring<Provider: ActionProvider>: Sendable {

    /// Resolves a cleaned utterance against the enabled-tool catalog — the driver's intent
    /// slot. `.none` and `.ask` fall through to the driver's existing reply handling; only a
    /// `.toolCall` is acted on.
    public let resolve: @Sendable @MainActor (String) async -> IntentResolution

    /// The action leg — the driver's handler slot. Submits the invocation through the executor
    /// with the approval withheld (the voice path never pre-grants), presents the card when the
    /// gate asks, and returns the spoken ack for a terminal decision (`nil` for silence).
    public let performAction: @Sendable @MainActor (ActionInvocation) async -> String?

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
        performAction: @escaping @Sendable @MainActor (ActionInvocation) async -> String?,
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
    /// is I/O-free, the stores are consulted per call — never at composition — and the card-up
    /// guard is a store read at call time, never here. The recipe names no transport, no
    /// `Process`, and no `TextInjector`; the driver's slots are filled, nothing is composed into
    /// the dictation path.
    @MainActor
    public static func composeIntentWiring<Provider: ActionProvider>(
        configStore: ActionConfigStore,
        provider: Provider,
        executor: ActionExecutor<Provider>,
        resolver: any IntentResolver,
        root: DictationLoopRoot
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
            return resolver.resolve(utterance, against: catalog)
        }

        let performAction: @Sendable @MainActor (ActionInvocation) async -> String? = {
            invocation in
            // The card-up guard, read lazily per call: one card at a time, and a second voice
            // action while a card is up refuses to present — no submission, no record, no swap.
            guard root.widgetStore.state.confirmation == nil else {
                logger.error(
                    "intent-wiring: refusing a second voice action while a confirmation card is up")
                return nil
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
                        toolID: invocation.toolID, generation: generation.next()))
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
}