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

/// **The shell composition's surface** (`wiring` aspect, `shell-provider` slice): the closures
/// the composition root assigns to its slots — the Actions tab's shell leg (the registry's
/// commands as tool rows, the arm and preview paths) and the confirmation card's two closures —
/// composed over the shipped seams (`ActionExecutor`, `ActionConfigStore`, `ShellCommandRegistry`,
/// the widget store's card folds).
///
/// The closures are the wiring's own vocabulary, not a parallel seam: each is the recipe's
/// answer over the shipped seams, so a consumer compiles against the composition rather than
/// against the modules the composition wires.
///
/// ## The provider is the recipe's parameter, never a special case
///
/// The struct is generic over the ``ActionProvider`` the executor submits to — the ``ActionWiring``
/// shape — so the shipped composition wires the real `ShellProvider` and a probe or a test wires
/// its own. The surface drives ``ActionProvider`` + ``ActionGate`` and nothing else.
///
/// ## The card lifecycle is the wiring's own
///
/// ``arm`` presents the card through the widget store's shipped fold
/// (``WidgetStateStore/presentActionConfirmation(_:)``) with a generation token minted here —
/// the store compares tokens, the wiring mints them. ``confirm`` submits ``ActionApproval/granted``
/// bound to **the exact sentence shown** (the N2 binding's caller side), re-presents a fresh card
/// on a mismatch, and clears the card through the store's own confirm fold. ``decline`` records
/// the refused decision and clears the card. The composition root routes the card's Confirm and
/// Decline to this wiring by the card's own `providerID` — a shell card is answered here, every
/// other card by ``ActionWiring``'s closures; the card is one surface, the routing is the
/// composition's.
///
/// ## The enablement is the shared store's
///
/// ``listCommands`` reads the registry and the config store at call time — the rows are the
/// configured commands with `isEnabled` folded from the persisted enablement (providerID
/// `dev.vocca.shell` + command id), **absent is off** (M7). An absent `shell-commands.json` is
/// the empty registry — nothing is configured out of the box, and the row source is a registry
/// read, never a discovery and never a spawn.
///
/// ## The sentence is the provider's own
///
/// The arm and preview paths submit through the executor and present the gate's sentence
/// verbatim — the argv-derived rendering the provider owns, re-rendered after the record exactly
/// as ``ActionWiring`` does. Nothing here derives, paraphrases or re-words a sentence.
///
/// ## `spawnsSubprocess` is declared for the configuration, not the capability
///
/// The provider this wiring carries can spawn — its engine is the real ``ShellExecutor``. The
/// declared value is the **composed default's**: `false`, because an absent registry is zero
/// commands and a default configuration with zero commands cannot create a child (the D2
/// narrowed promise, the `requiresNetwork` analogue — the pin: capability vs configuration, and
/// the probe reads the configuration). A composition that wired commands by default would declare
/// it here rather than in a comment.
public struct ShellWiring<Provider: ActionProvider>: Sendable {

    /// The shell leg's row source: the registry's configured commands as the tab's tool rows,
    /// with enablement folded in (default off). The empty answer is the honest first-launch
    /// answer — no command is configured out of the box (D2).
    public let listCommands: @Sendable @MainActor () async -> [ActionsToolRow]

    /// Arms an enabled command through the gate — the wiring's half of the arm path, behind the
    /// confirmation card. Refused while a session is in flight (the C11 in-flight precedent);
    /// the gate decides everything else, and a `confirmationRequired` answer is presented as the
    /// widget card with the gate's sentence verbatim (M5a).
    public let arm: @Sendable @MainActor (String, String) async throws -> Void

    /// Renders the provider's sentence for one command, without acting — the dry-run half of the
    /// seam (M5): `invoke` is reached zero times. `nil` when nothing can be said (a disabled or
    /// nameless command).
    public let preview: @Sendable @MainActor (String, String) async -> String?

    /// The confirmation card's Confirm — **the only route to `invoke` for a shell command in the
    /// shipped configuration**: submits ``ActionApproval/granted`` bound to the exact sentence
    /// the card showed; a sentence that changed between show and confirm is refused by the gate
    /// and a fresh card is presented (the binding's refusal is a re-prompt, never a dead end).
    public let confirm: @Sendable @MainActor () async -> Void

    /// The confirmation card's Decline: records the refused decision (the stop for want of a
    /// yes) and clears the card.
    public let decline: @Sendable @MainActor () async -> Void

    /// The wiring's card-appeared signal — fired when the widget card is presented. The tab's
    /// binding maps to it.
    public let confirmationPresented: @Sendable @MainActor () -> Void

    /// The wiring's card-cleared signal — fired when the card goes away (confirm and decline).
    /// The tab's binding maps to it.
    public let confirmationDismissed: @Sendable @MainActor () -> Void

    /// The executor the wiring submits through — the shell leg's own caller of ``ActionGate``
    /// (the executor is per-provider by construction), exposed for the composition root's slot.
    public let executor: ActionExecutor<Provider>

    /// **Whether the composed default spawns a child process.** `false` — the declared value,
    /// the ``ActionWiring`` analogue, for the **configuration**: the provider's engine can spawn
    /// (the capability), but an absent registry is zero commands, and a default configuration
    /// with zero commands cannot create a child (D2). A composition that wired commands by
    /// default would declare it here rather than in a comment.
    public let spawnsSubprocess: Bool

    public init(
        listCommands: @escaping @Sendable @MainActor () async -> [ActionsToolRow],
        arm: @escaping @Sendable @MainActor (String, String) async throws -> Void,
        preview: @escaping @Sendable @MainActor (String, String) async -> String?,
        confirm: @escaping @Sendable @MainActor () async -> Void,
        decline: @escaping @Sendable @MainActor () async -> Void,
        confirmationPresented: @escaping @Sendable @MainActor () -> Void,
        confirmationDismissed: @escaping @Sendable @MainActor () -> Void,
        executor: ActionExecutor<Provider>,
        spawnsSubprocess: Bool
    ) {
        self.listCommands = listCommands
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
/// One case today: the arm is refused while a session is in flight — a confirmation card cannot
/// land mid-dictation. A second case is a reviewed edit here, never a string invented at a call
/// site.
public enum ShellWiringError: Error, Equatable {
    /// Arming while a session is in flight — the card cannot appear on a live session.
    case sessionInFlight
}

extension AppBootstrap {

    /// The generation tokens the card's stale-guard compares — minted here, at presentation.
    ///
    /// The ``ActionWiring`` recipe's mint, file-local: the recipe's closures are `@Sendable`,
    /// and a captured `var` would be shared mutable state the strict-concurrency checker
    /// refuses. Plain `Sendable` state; carries no content — a token is a comparison, nothing
    /// more.
    private final class ShellGeneration: Sendable {
        private let value = Mutex(0)

        func next() -> Int {
            value.withLock { $0 &+= 1; return $0 }
        }
    }

    /// **The shell wiring recipe** (`wiring` aspect, `shell-provider` R6): the Actions tab's
    /// shell leg and the confirmation-card closures, composed over the shipped seams — the
    /// ``ActionExecutor`` (the gate's caller, built here over the real audit store and the
    /// injected provider), the ``ActionConfigStore`` and the ``ShellCommandRegistry`` (the
    /// composition's parameters — the shipped composition passes the real stores, the probe and
    /// tests pass temp-directory ones), and the widget store's card folds.
    ///
    /// ## The policy floor — `.none`, the recorded decision
    ///
    /// The ``ActionWiring.swift:203`` decision inherited: the F1/F2 fail-safes already force
    /// confirmation on anything without a genuine `readOnly` claim (absent means unsafe), so a
    /// stricter floor — say `.destructive` — would force confirmation even on commands the file
    /// declared read-only and break M3's read-only-runs-directly contract. Escalate-only means
    /// the floor can only raise; `.none` is the minimal honest floor. Shell is the highest blast
    /// radius in the roadmap, and its whole mitigation is the gate's own branch point
    /// (`BlastRadius.requiresConfirmation`), not a stricter current floor.
    ///
    /// ## Probe-safe by construction (the ``ActionWiring`` doc contract)
    ///
    /// Nothing here starts, reads or provisions at composition time: the executor's construction
    /// is I/O-free, the stores and the registry are consulted per call — never at composition —
    /// and the session-active flag is a closure read lazily at arm time, never here. The recipe
    /// names no transport and spawns nothing; `spawnsSubprocess` is the declared `false` of the
    /// composed default — zero commands, nothing to spawn.
    @MainActor
    public static func composeShellWiring<Provider: ActionProvider>(
        configStore: ActionConfigStore,
        auditStore: FileSystemActionAuditStore,
        registry: ShellCommandRegistry,
        provider: Provider,
        sessionActive: @escaping @Sendable @MainActor () -> Bool,
        root: DictationLoopRoot
    ) -> ShellWiring<Provider> {
        let executor = ActionExecutor(provider: provider, store: auditStore)
        let generation = ShellGeneration()
        let logger = Logger(subsystem: "dev.vocca.Vocca", category: "shell-wiring")

        // The recorded floor decision — see the recipe's documentation (`ActionWiring.swift:203`).
        let policy = ActionRadiusPolicy.none

        // The card-lifecycle signals: fired when the widget card appears and clears, wired into
        // the tab's bindings so the surface's arm path has its two-way channel. They carry no
        // state — the card's lifecycle is the store's and the executor's own, and nothing
        // downstream may stand in for a human saying yes (M4a).
        let confirmationPresented: @Sendable @MainActor () -> Void = {}
        let confirmationDismissed: @Sendable @MainActor () -> Void = {}

        // The shell leg's row source: the registry's commands, with `isEnabled` folded from the
        // shared enablement (providerID `dev.vocca.shell` + command id, absent is off). The
        // radius is the file's own claim — read-only only when the file declared it (R2,
        // destructive by default) — and the summary is the fixed argv, never authored prose.
        let listCommands: @Sendable @MainActor () async -> [ActionsToolRow] = {
            let file = await registry.load()
            let config = await configStore.load()
            return file.commands.map { command in
                ActionsToolRow(
                    providerID: ShellProvider.providerID,
                    toolID: command.id,
                    summary: command.command.joined(separator: " "),
                    radius: command.readOnly ? .readOnly : .destructive,
                    isEnabled: config.enablement.contains(
                        ActionConfigEnablementRow(
                            providerID: ShellProvider.providerID, toolID: command.id)))
            }
        }

        let arm: @Sendable @MainActor (String, String) async throws -> Void = {
            providerID, toolID in
            // The C11 in-flight refusal: the flag is read lazily at arm time — never at
            // composition — so a confirmation card cannot land mid-dictation.
            guard !sessionActive() else {
                logger.error(
                    "shell-wiring: refusing to arm \(providerID)/\(toolID) while a session is in flight")
                throw ShellWiringError.sessionInFlight
            }
            guard let invocation = ActionInvocation(providerID: providerID, toolID: toolID)
            else { return }
            let enablement = await configStore.loadEnablement()
            let decision = await executor.submit(
                invocation, enablement: enablement, policy: policy,
                approval: .withheld, approvedSentence: nil, mode: .live)
            switch decision.decision {
            case .confirmationRequired:
                // The card, with the sentence **re-rendered after the record** — the
                // count-bearing precedent (`ActionWiring.swift:291`): the executor records the
                // decision after the gate's describe, so the shown sentence is the current
                // truth the confirm's own render will match.
                let fresh: ActionSummary = await provider.describe(invocation)
                root.widgetStore.presentActionConfirmation(
                    WidgetConfirmationSignal(
                        sentence: fresh.sentence, providerID: providerID, toolID: toolID,
                        generation: generation.next()))
                confirmationPresented()
            case .invoked, .previewed, .declined:
                // A read-only command ran directly (M3), or the gate declined before any card —
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
                // not the sentence the gate now renders. The re-prompt is a **render**, not a
                // decision — it reads the provider's current sentence directly, so no record
                // moves the sentence between this card and the next confirm.
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

        return ShellWiring(
            listCommands: listCommands,
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