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

/// **The C13 action composition's surface** (`wiring` aspect, `action-surface-wiring` C13
/// slice 5): the closures the composition root assigns to its slots — the actions-tab bindings
/// (load/save config, discovery, enablement, the arm and preview paths) and the confirmation
/// card's two closures — composed over the shipped seams (`ActionExecutor`, `ActionConfigStore`,
/// the widget store's card folds).
///
/// The closures are the wiring's own vocabulary, not a parallel seam: each is the recipe's
/// answer over the shipped seams, so a consumer compiles against the composition rather than
/// against the modules the composition wires.
///
/// ## The provider is the recipe's parameter, never a special case
///
/// The struct is generic over the ``ActionProvider`` the executor submits to — the surface must
/// not special-case `MCPProvider` or `AuditActionProvider` (PRD persona 3); it drives
/// ``ActionProvider`` + ``ActionGate`` and nothing else. The shipped composition wires the real
/// `AuditActionProvider`; a probe or a test wires its own.
///
/// ## The card lifecycle is the wiring's own
///
/// ``arm`` presents the card through the widget store's shipped fold
/// (``WidgetStateStore/presentActionConfirmation(_:)``) with a generation token minted here —
/// the store compares tokens, the wiring mints them. ``confirm`` submits ``ActionApproval/granted``
/// bound to **the exact sentence shown** (the N2 binding's caller side), re-presents a fresh card
/// on a mismatch (the PRD review's re-prompt default), and clears the card through the store's
/// own confirm fold — so the stale-card guard is the store's, asserted at the only seam the
/// wiring has. ``decline`` records the refused decision (a withheld submission — the stop for
/// want of a yes, recorded like any other decision) and clears the card.
///
/// ``confirmationPresented`` / ``confirmationDismissed`` are the wiring's card-lifecycle
/// signals — fired when the widget card appears and clears, wired into the tab's bindings so the
/// surface's arm path has its two-way channel (the page's own optimistic signal and the wiring's
/// fact share it). The card's lifecycle itself is the store's and the executor's; the signals
/// carry no state, because nothing downstream may stand in for a human saying yes (M4a).
public struct ActionWiring<Provider: ActionProvider>: Sendable {

    /// The config as the Actions tab edits it — servers and enablement, one draft, so what the
    /// table shows and what `action-config.json` holds cannot drift. The empty draft is the
    /// honest first-launch answer: no server is configured out of the box (D2).
    public let loadConfig: @Sendable @MainActor () async -> ActionsConfigDraft

    /// Writes the whole draft back — servers and enablement in one save. Throws what the store
    /// throws: a server the user believes configured must be configured.
    public let saveConfig: @Sendable @MainActor (ActionsConfigDraft) async throws -> Void

    /// Discovers the tools of one server — the explicit, user-initiated spawn (R4). **This
    /// wiring cannot spawn**: the stdio transport is unwired by the D2 decision (naming it is a
    /// reviewed edit that breaks the transport confinement), so the honest answer is the
    /// bounded refusal — discovery is a later slice's reviewed move, never an accident here.
    public let discoverTools: @Sendable @MainActor (String) async -> ActionsDiscoveryResult

    /// Flips one tool's enablement row. Persisted as membership; absent is off (PRD M7).
    public let setToolEnabled: @Sendable @MainActor (String, String, Bool) async throws -> Void

    /// Arms an enabled tool through the gate — the wiring's half of the arm path, behind the
    /// confirmation card. Refused while a session is in flight (R2, the C11 in-flight
    /// precedent); the gate decides everything else, and a `confirmationRequired` answer is
    /// presented as the widget card with the gate's sentence verbatim (M5a).
    public let arm: @Sendable @MainActor (String, String) async throws -> Void

    /// Renders the provider's sentence for one tool, without acting — the dry-run half of the
    /// seam (M5): `invoke` is reached zero times. `nil` when nothing can be said (a disabled or
    /// nameless tool).
    public let preview: @Sendable @MainActor (String, String) async -> String?

    /// The confirmation card's Confirm — **the only route to `invoke` in the shipped
    /// configuration**: submits ``ActionApproval/granted`` bound to the exact sentence the card
    /// showed; a sentence that changed between show and confirm is refused by the gate and a
    /// fresh card is presented (the binding's refusal is a re-prompt, never a dead end).
    public let confirm: @Sendable @MainActor () async -> Void

    /// The confirmation card's Decline: records the refused decision (the stop for want of a
    /// yes) and clears the card.
    public let decline: @Sendable @MainActor () async -> Void

    /// The wiring's card-appeared signal — fired when the widget card is presented (arm, and
    /// the mismatch re-prompt). The tab's binding maps to it.
    public let confirmationPresented: @Sendable @MainActor () -> Void

    /// The wiring's card-cleared signal — fired when the card goes away (confirm and decline).
    /// The tab's binding maps to it.
    public let confirmationDismissed: @Sendable @MainActor () -> Void

    /// The executor the wiring submits through — the one caller of ``ActionGate`` in the
    /// shipped configuration, exposed for the composition root's slot.
    public let executor: ActionExecutor<Provider>

    /// **Whether the composed default spawns a child process.** `false` — the declared value,
    /// the ``requiresNetwork`` analogue: the default configuration cannot create a child (D2),
    /// and a composition that wired a transport would declare it here rather than in a comment.
    public let spawnsSubprocess: Bool

    public init(
        loadConfig: @escaping @Sendable @MainActor () async -> ActionsConfigDraft,
        saveConfig: @escaping @Sendable @MainActor (ActionsConfigDraft) async throws -> Void,
        discoverTools: @escaping @Sendable @MainActor (String) async -> ActionsDiscoveryResult,
        setToolEnabled: @escaping @Sendable @MainActor (String, String, Bool) async throws -> Void,
        arm: @escaping @Sendable @MainActor (String, String) async throws -> Void,
        preview: @escaping @Sendable @MainActor (String, String) async -> String?,
        confirm: @escaping @Sendable @MainActor () async -> Void,
        decline: @escaping @Sendable @MainActor () async -> Void,
        confirmationPresented: @escaping @Sendable @MainActor () -> Void,
        confirmationDismissed: @escaping @Sendable @MainActor () -> Void,
        executor: ActionExecutor<Provider>,
        spawnsSubprocess: Bool
    ) {
        self.loadConfig = loadConfig
        self.saveConfig = saveConfig
        self.discoverTools = discoverTools
        self.setToolEnabled = setToolEnabled
        self.arm = arm
        self.preview = preview
        self.confirm = confirm
        self.decline = decline
        self.confirmationPresented = confirmationPresented
        self.confirmationDismissed = confirmationDismissed
        self.executor = executor
        self.spawnsSubprocess = spawnsSubprocess
    }
}

/// What the wiring refuses with, when it refuses at all.
///
/// One case today: the arm is refused while a session is in flight (R2) — a confirmation card
/// cannot land mid-dictation. A second case is a reviewed edit here, never a string invented at
/// a call site.
public enum ActionWiringError: Error, Equatable {
    /// Arming while a session is in flight — the card cannot appear on a live session.
    case sessionInFlight
}

extension AppBootstrap {

    /// The generation tokens the card's stale-guard compares — minted here, at presentation.
    ///
    /// A `Mutex`-backed counter (the `ContextRevocation` shape): the recipe's closures are
    /// `@Sendable`, and a captured `var` would be shared mutable state the strict-concurrency
    /// checker refuses. Plain `Sendable` state; carries no content — a token is a comparison,
    /// nothing more.
    private final class ActionGeneration: Sendable {
        private let value = Mutex(0)

        func next() -> Int {
            value.withLock { $0 &+= 1; return $0 }
        }
    }

    /// **The C13 action wiring recipe** (`wiring` aspect, `action-surface-wiring` C13 slice 5):
    /// the actions-tab bindings, the arm/preview paths and the confirmation-card closures,
    /// composed over the shipped seams — the ``ActionExecutor`` (the gate's one caller, built
    /// here over the real audit store and the injected provider), the ``ActionConfigStore``
    /// (the composition's parameter — the shipped composition passes the real store, the probe
    /// and tests pass temp-directory stores), and the widget store's card folds.
    ///
    /// ## The policy floor — `.none`, the recorded decision (PRD S1)
    ///
    /// The wiring supplies `ActionRadiusPolicy.none` and the choice is **recorded as a decision,
    /// not an unexamined default**: the F1/F2 fail-safes already force confirmation on anything
    /// without a genuine `readOnlyHint` (absent means unsafe), so a stricter floor — say
    /// `.destructive` — would force confirmation even on genuinely read-only tools and break
    /// M3's read-only-runs-directly contract. Escalate-only means the floor can only raise;
    /// `.none` is the minimal honest floor (`docs/planning/action-surface-wiring/prd.md` S1).
    ///
    /// ## Probe-safe by construction (the `ContextWiring` doc contract)
    ///
    /// Nothing here starts, reads or provisions at composition time: the executor's construction
    /// is I/O-free, the stores are consulted per call — never at composition — and the
    /// session-active flag is a closure read lazily at arm time, never here. The recipe names no
    /// transport and spawns nothing; `spawnsSubprocess` is the declared `false` of a composition
    /// that wired none.
    @MainActor
    public static func composeActionWiring<Provider: ActionProvider>(
        configStore: ActionConfigStore,
        auditStore: FileSystemActionAuditStore,
        provider: Provider,
        sessionActive: @escaping @Sendable @MainActor () -> Bool,
        root: DictationLoopRoot
    ) -> ActionWiring<Provider> {
        let executor = ActionExecutor(provider: provider, store: auditStore)
        let generation = ActionGeneration()
        let logger = Logger(subsystem: "dev.vocca.Vocca", category: "action-wiring")

        // The recorded floor decision — see the recipe's documentation (PRD S1).
        let policy = ActionRadiusPolicy.none

        // The card-lifecycle signals: fired when the widget card appears and clears (the arm,
        // the mismatch re-prompt, the confirm and the decline), wired into the tab's bindings
        // so the surface's arm path has its two-way channel. They carry no state — the card's
        // lifecycle is the store's and the executor's own, and nothing downstream may stand in
        // for a human saying yes (M4a).
        let confirmationPresented: @Sendable @MainActor () -> Void = {}
        let confirmationDismissed: @Sendable @MainActor () -> Void = {}

        let loadConfig: @Sendable @MainActor () async -> ActionsConfigDraft = {
            let config = await configStore.load()
            return ActionsConfigDraft(
                servers: config.servers.map {
                    ActionsServerRow(id: $0.id, name: $0.name, path: $0.executablePath)
                },
                enablement: Set(
                    config.enablement.map {
                        ActionsToolKey(providerID: $0.providerID, toolID: $0.toolID)
                    }))
        }

        let saveConfig: @Sendable @MainActor (ActionsConfigDraft) async throws -> Void = {
            draft in
            let config = ActionConfig(
                servers: draft.servers.map {
                    MCPServerConfiguration(id: $0.id, name: $0.name, executablePath: $0.path)
                },
                enablement: draft.enablement.map {
                    ActionConfigEnablementRow(providerID: $0.providerID, toolID: $0.toolID)
                }
                // A `Set` has no order; the file is byte-stable, so the rows are sorted into one.
                .sorted { ($0.providerID, $0.toolID) < ($1.providerID, $1.toolID) })
            try await configStore.save(config)
        }

        let discoverTools: @Sendable @MainActor (String) async -> ActionsDiscoveryResult = {
            serverID in
            // D2, spoken by the wiring that cannot spawn: tool discovery runs the server's
            // executable, and the stdio transport is unwired by decision — the transport's own
            // confinement test says "wiring it is a later slice with its own review, not an
            // import". The honest answer of this wiring is the bounded refusal.
            logger.error("action-wiring: discovery for server \(serverID) is not wired (D2)")
            return .failed("discovery.unwired")
        }

        let setToolEnabled: @Sendable @MainActor (String, String, Bool) async throws -> Void = {
            providerID, toolID, enabled in
            let loaded = await configStore.load()
            let row = ActionConfigEnablementRow(providerID: providerID, toolID: toolID)
            let enablement: [ActionConfigEnablementRow]
            if enabled {
                enablement = loaded.enablement.contains(row)
                    ? loaded.enablement : loaded.enablement + [row]
            } else {
                enablement = loaded.enablement.filter { $0 != row }
            }
            try await configStore.save(
                ActionConfig(servers: loaded.servers, enablement: enablement))
        }

        let arm: @Sendable @MainActor (String, String) async throws -> Void = {
            providerID, toolID in
            // The C11 in-flight refusal (R2): the flag is read lazily at arm time — never at
            // composition — so a confirmation card cannot land mid-dictation, and the probe's
            // composition (whose flag always answers false) is unaffected by the read's shape.
            guard !sessionActive() else {
                logger.error(
                    "action-wiring: refusing to arm \(providerID)/\(toolID) while a session is in flight")
                throw ActionWiringError.sessionInFlight
            }
            guard let invocation = ActionInvocation(providerID: providerID, toolID: toolID)
            else { return }
            let enablement = await configStore.loadEnablement()
            let decision = await executor.submit(
                invocation, enablement: enablement, policy: policy,
                approval: .withheld, approvedSentence: nil, mode: .live)
            switch decision.decision {
            case .confirmationRequired:
                // The card, with the sentence **re-rendered after the record**. The executor
                // records the decision after the gate's describe, so a provider whose sentence
                // names the log — `AuditActionProvider`'s count — renders a card that is one
                // entry behind the truth the moment the record lands, and the first confirm
                // would mismatch forever. The re-render (a read, never a decision) presents the
                // current sentence; the confirm binds to exactly this, and the gate's own
                // fresh render at confirm time matches. The record is the gate's render; the
                // card is the current truth; the approved-sentence property holds where an
                // approval happens — the confirm.
                let fresh: ActionSummary = await provider.describe(invocation)
                root.widgetStore.presentActionConfirmation(
                    WidgetConfirmationSignal(
                        sentence: fresh.sentence, providerID: providerID, toolID: toolID,
                        generation: generation.next()))
                confirmationPresented()
            case .invoked, .previewed, .declined:
                // A read-only tool ran directly (M3), or the gate declined before any card —
                // both are recorded by the executor; neither presents anything.
                break
            }
        }

        let preview: @Sendable @MainActor (String, String) async -> String? = {
            providerID, toolID in
            guard let invocation = ActionInvocation(providerID: providerID, toolID: toolID)
            else { return nil }
            let enablement = await configStore.loadEnablement()
            let decision = await executor.submit(
                invocation, enablement: enablement, policy: policy,
                approval: .withheld, approvedSentence: nil, mode: .dryRun)
            return decision.decision.summary?.sentence
        }

        let confirm: @Sendable @MainActor () async -> Void = {
            // The card the human is answering — read off the store, the one seam the wiring
            // has. A refused read (no card, or a stale generation) makes no gate call: the
            // store's guard is the guard.
            guard let signal = root.widgetStore.state.confirmation?.signal else { return }
            guard root.widgetStore.confirmActionConfirmation(signal) else { return }
            guard
                let invocation = ActionInvocation(
                    providerID: signal.providerID, toolID: signal.toolID)
            else { return }
            let enablement = await configStore.loadEnablement()
            let decision = await executor.submit(
                invocation, enablement: enablement, policy: policy,
                approval: .granted, approvedSentence: signal.sentence, mode: .live)
            switch decision.decision {
            case .declined(.approvedSentenceMismatch):
                // The N2 binding, refused by attempting the call: the sentence the human saw is
                // not the sentence the gate now renders. The PRD review's default is a
                // re-prompt, never a dead end — and the re-prompt is a **render**, not a
                // decision: it reads the provider's current sentence directly (the same
                // describe the gate ran), so no record moves the count the sentence names
                // between this card and the next confirm. A recorded re-prompt would leave the
                // fresh card forever one entry behind its own submit — the mismatch cascade —
                // measured on the real `AuditActionProvider`, whose sentence names the count.
                let fresh: ActionSummary = await provider.describe(invocation)
                root.widgetStore.presentActionConfirmation(
                    WidgetConfirmationSignal(
                        sentence: fresh.sentence, providerID: signal.providerID,
                        toolID: signal.toolID, generation: generation.next()))
                confirmationPresented()
            case .invoked, .previewed, .confirmationRequired, .declined:
                break
            }
            // The accepted confirm cleared the card in the store's own fold; the wiring's
            // card-cleared signal follows it.
            confirmationDismissed()
        }

        let decline: @Sendable @MainActor () async -> Void = {
            guard let signal = root.widgetStore.state.confirmation?.signal else { return }
            root.widgetStore.dismissActionConfirmation()
            guard
                let invocation = ActionInvocation(
                    providerID: signal.providerID, toolID: signal.toolID)
            else { return }
            let enablement = await configStore.loadEnablement()
            // The refused decision, recorded: a withheld submission is the stop for want of a
            // yes — the R8 every-decision rule, and the audit log's honest history of an action
            // that was stopped on purpose.
            _ = await executor.submit(
                invocation, enablement: enablement, policy: policy,
                approval: .withheld, approvedSentence: nil, mode: .live)
            confirmationDismissed()
        }

        return ActionWiring(
            loadConfig: loadConfig,
            saveConfig: saveConfig,
            discoverTools: discoverTools,
            setToolEnabled: setToolEnabled,
            arm: arm,
            preview: preview,
            confirm: confirm,
            decline: decline,
            confirmationPresented: confirmationPresented,
            confirmationDismissed: confirmationDismissed,
            executor: executor,
            spawnsSubprocess: false)
    }
}