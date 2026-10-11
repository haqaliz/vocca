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

/// **The MCP composition's surface** (`mcp-composition` aspect): the per-server recipe the
/// `intent-and-surface` aspect will route to — a providerID resolves to one server's wiring, and
/// that wiring carries the same card lifecycle the Shell and Coding-agent recipes own
/// (``arm``, ``performAction``, ``confirm``, ``decline``), composed over the shipped seams
/// (``ActionExecutor``, ``ActionConfigStore``, ``MCPProvider``, the widget store's card folds).
///
/// ## One wiring per server, because the executor is per-provider
///
/// ``ActionExecutor`` holds **one** provider, and MCP has **one provider per configured server**
/// (one ``MCPSession`` each). So the recipe is not one executor over one provider — it is a
/// **lookup**: given a `providerID`, it finds the matching ``MCPServerConfiguration``, launches a
/// transport through the injected factory, discovers once, and builds the server's own executor.
/// The result is cached for the process, so discovery runs **at most once per server** and Confirm
/// reuses it (no second spawn) — the PRD's decided lazy-and-cached policy.
///
/// ## The factory is named, never the transport
///
/// The recipe takes an injectable `transportFactory` of ``MCPTransportLaunch``'s shape and never
/// names ``StdioMCPTransport``: the shipped composition passes
/// ``MCPStdioTransportFactory/make(_:)`` (defined inside the transport's own file, so the D2 pin
/// stays green), while a test or a probe substitutes ``InMemoryMCPTransport``. Nothing here
/// spawns at composition — the factory is called lazily, at lookup, and only for a configured
/// server.
///
/// ## The card lifecycle is the wiring's own
///
/// ``arm`` and ``performAction`` present the card through the widget store's shipped fold with a
/// generation token minted here; ``confirm`` submits ``ActionApproval/granted`` bound to **the
/// exact sentence shown** and re-presents on a mismatch; ``decline`` records the refused decision
/// and clears the card. A card belonging to another providerID is left alone — the per-server
/// wiring answers only its own card. The composition root routes Confirm/Decline by the card's
/// own `providerID`, so an MCP card is answered here.
///
/// ## The policy floor — `.none`, the recorded decision
///
/// The ``ShellWiring``/``CodingAgentWiring`` decision inherited: the F1/F2 fail-safes already
/// force confirmation on anything without a genuine `readOnly` claim (absent means unsafe), so a
/// stricter floor would break M3's read-only-runs-directly contract. Escalate-only means the floor
/// can only raise; `.none` is the minimal honest floor.
///
/// ## `spawnsSubprocess` is the configuration's fact, read per call
///
/// The provider this wiring carries can spawn — its transport is the real ``StdioMCPTransport``.
/// The declared value is the **configuration's**: `false` with zero servers configured, `true`
/// once one is. It is read lazily (the stores are consulted per call, never at composition — the
/// probe-safe contract), so a config edit moves it without a relaunch.
public struct MCPWiring: Sendable {

    /// **The per-server lookup.** Given a `providerID`, the matching server's wiring — launched,
    /// discovered and cached once per process — or `nil` when no server matches, the launch fails
    /// or discovery fails (the caller fails closed).
    public let lookup: @Sendable @MainActor (String) async -> MCPServerWiring?

    /// Whether the **configured** MCP arm spawns a child process: `false` with zero configured
    /// servers, `true` once one is. Read lazily from the config store, never at composition.
    public let spawnsSubprocess: @Sendable @MainActor () async -> Bool

    public init(
        lookup: @escaping @Sendable @MainActor (String) async -> MCPServerWiring?,
        spawnsSubprocess: @escaping @Sendable @MainActor () async -> Bool
    ) {
        self.lookup = lookup
        self.spawnsSubprocess = spawnsSubprocess
    }
}

/// One configured server's wiring — the closures the composition root's slots route to once the
/// card's (or the phrase's) providerID names this server.
public struct MCPServerWiring: Sendable {

    /// The per-server provider id (``MCPProvider/providerID(forServer:)``) this wiring serves.
    public let providerID: String

    /// Arms an enabled tool through the gate — the tab's half of the arm path. Refused while a
    /// session is in flight; the gate decides everything else, and a `confirmationRequired`
    /// answer is presented as the widget card with the gate's sentence verbatim.
    public let arm: @Sendable @MainActor (String) async throws -> Void

    /// The voice leg: submits the invocation through the executor with the approval withheld,
    /// presents the card when the gate asks, and returns the spoken ack for a terminal decision
    /// (`nil` for silence or a card).
    public let performAction: @Sendable @MainActor (ActionInvocation, String) async -> String?

    /// The confirmation card's Confirm — **the only route to `invoke` for an MCP tool**: submits
    /// ``ActionApproval/granted`` bound to the exact sentence the card showed; a sentence that
    /// changed between show and confirm is refused by the gate and a fresh card is presented.
    public let confirm: @Sendable @MainActor () async -> Void

    /// The confirmation card's Decline: records the refused decision and clears the card.
    public let decline: @Sendable @MainActor () async -> Void

    /// The executor this server submits through — per-server by construction.
    public let executor: ActionExecutor<MCPProvider>

    /// The local radius floor, `.none` — the recorded decision (see ``MCPWiring``).
    public let policy: ActionRadiusPolicy

    public init(
        providerID: String,
        arm: @escaping @Sendable @MainActor (String) async throws -> Void,
        performAction: @escaping @Sendable @MainActor (ActionInvocation, String) async -> String?,
        confirm: @escaping @Sendable @MainActor () async -> Void,
        decline: @escaping @Sendable @MainActor () async -> Void,
        executor: ActionExecutor<MCPProvider>,
        policy: ActionRadiusPolicy
    ) {
        self.providerID = providerID
        self.arm = arm
        self.performAction = performAction
        self.confirm = confirm
        self.decline = decline
        self.executor = executor
        self.policy = policy
    }
}

/// What the MCP wiring refuses with, when it refuses at all.
///
/// One case today: the arm is refused while a session is in flight — a confirmation card cannot
/// land mid-dictation. A second case is a reviewed edit here, never a string invented at a call
/// site.
public enum MCPWiringError: Error, Equatable {
    /// Arming while a session is in flight — the card cannot appear on a live session.
    case sessionInFlight
}

extension AppBootstrap {

    /// The generation tokens the card's stale-guard compares — minted per server, at presentation.
    ///
    /// The ``ShellWiring`` recipe's mint: the recipe's closures are `@Sendable`, and a captured
    /// `var` would be shared mutable state the strict-concurrency checker refuses. Plain
    /// `Sendable` state; carries no content — a token is a comparison, nothing more.
    private final class MCPGeneration: Sendable {
        private let value = Mutex(0)

        func next() -> Int {
            value.withLock { $0 &+= 1; return $0 }
        }
    }

    /// The process-lifetime discovery cache, keyed by server id: at most one launch and one
    /// discovery per server, and Confirm reuses the entry (no second spawn).
    private final class MCPWiringCache: Sendable {
        private let entries = Mutex<[String: MCPServerWiring]>([:])

        func wiring(for providerID: String) -> MCPServerWiring? {
            entries.withLock { $0[providerID] }
        }

        func store(_ wiring: MCPServerWiring, for providerID: String) {
            entries.withLock { $0[providerID] = wiring }
        }
    }

    /// **The MCP wiring recipe** (`mcp-composition`): the per-server lookup and its card
    /// closures, composed over the shipped seams — the ``ActionConfigStore`` (the composition's
    /// parameter: the shipped composition passes the real store, tests pass temp-directory ones),
    /// the injected `transportFactory` (the real ``MCPStdioTransportFactory/make(_:)`` in the
    /// shipped composition, ``InMemoryMCPTransport`` in tests and the probe), the audit store the
    /// per-server executor records into, the lazily-read `sessionActive` flag and the widget
    /// store's card folds.
    ///
    /// ## Probe-safe by construction (the ``ActionWiring`` doc contract)
    ///
    /// Nothing here starts, reads or provisions at composition time: the config store is consulted
    /// per lookup, the factory is called per lookup (and only for a configured server), and the
    /// session-active flag and the spawn fact are closures read lazily. A composition over an
    /// absent config launches nothing and `spawnsSubprocess` answers `false`.
    @MainActor
    public static func composeMCPWiring(
        configStore: ActionConfigStore,
        auditStore: FileSystemActionAuditStore,
        transportFactory: @escaping @Sendable (MCPServerConfiguration) async -> MCPTransportLaunch,
        sessionActive: @escaping @Sendable @MainActor () -> Bool,
        root: DictationLoopRoot
    ) -> MCPWiring {
        let cache = MCPWiringCache()
        let logger = Logger(subsystem: "dev.vocca.Vocca", category: "mcp-wiring")

        // The recorded floor decision — see the recipe's documentation.
        let policy = ActionRadiusPolicy.none

        let spawnsSubprocess: @Sendable @MainActor () async -> Bool = {
            !(await configStore.load().servers.isEmpty)
        }

        let lookup: @Sendable @MainActor (String) async -> MCPServerWiring? = { providerID in
            // The cache first: discovery runs at most once per server per process, and a Confirm
            // reuses the entry rather than spawning again.
            if let cached = cache.wiring(for: providerID) { return cached }

            // The server this providerID names — the one place the per-server helper is read for
            // matching, so discovery and enablement cannot disagree about the id.
            let config = await configStore.load()
            guard
                let server = config.servers.first(where: {
                    MCPProvider.providerID(forServer: $0) == providerID
                })
            else {
                logger.error("mcp-wiring: no configured server matches \(providerID)")
                return nil
            }

            let transport: any MCPTransport
            switch await transportFactory(server) {
            case .failed(let reason):
                logger.error("mcp-wiring: launching \(providerID) failed (\(reason))")
                return nil
            case .launched(let launched):
                transport = launched
            }

            let provider: MCPProvider
            switch await MCPProvider.discover(
                session: MCPSession(transport: transport), providerID: providerID)
            {
            case .failure(let failure):
                logger.error("mcp-wiring: discovery for \(providerID) failed (\(failure))")
                return nil
            case .success(let discovered):
                provider = discovered
            }

            let executor = ActionExecutor(provider: provider, store: auditStore)
            let generation = MCPGeneration()

            // The tab's arm path: refused while a session is in flight, then the gate decides.
            let arm: @Sendable @MainActor (String) async throws -> Void = { toolID in
                guard !sessionActive() else {
                    logger.error(
                        "mcp-wiring: refusing to arm \(providerID)/\(toolID) while a session is in flight")
                    throw MCPWiringError.sessionInFlight
                }
                guard
                    let invocation = ActionInvocation(providerID: providerID, toolID: toolID)
                else { return }
                let enablement = await configStore.loadEnablement()
                let decision = await executor.submit(
                    invocation, enablement: enablement, policy: policy,
                    approval: .withheld, approvedSentence: nil, mode: .live)
                switch decision.decision {
                case .confirmationRequired:
                    // The card, with the sentence **re-rendered after the record** — the
                    // count-bearing precedent: the shown sentence is the current truth the
                    // confirm's own render will match.
                    let fresh = await provider.describe(invocation)
                    root.widgetStore.presentActionConfirmation(
                        WidgetConfirmationSignal(
                            sentence: fresh.sentence, providerID: providerID, toolID: toolID,
                            generation: generation.next()))
                case .invoked, .previewed, .declined:
                    break
                }
            }

            // The voice leg: the card-up guard, the withheld submission, the acks.
            let performAction: @Sendable @MainActor (ActionInvocation, String) async -> String? =
            { invocation, _ in
                // One card at a time: a second voice action while a card is up refuses to
                // present — no submission, no record, no swap.
                guard root.widgetStore.state.confirmation == nil else {
                    logger.error(
                        "mcp-wiring: refusing a second voice action while a confirmation card is up")
                    return nil
                }
                // This wiring answers only its own server's invocations — a foreign providerID
                // reaching it by mistake must not run against this executor.
                guard invocation.providerID == providerID else {
                    logger.error(
                        "mcp-wiring: refusing \(invocation.providerID)/\(invocation.toolID) on the \(providerID) wiring")
                    return nil
                }
                let enablement = await configStore.loadEnablement()
                let decision = await executor.submit(
                    invocation, enablement: enablement, policy: policy,
                    approval: .withheld, approvedSentence: nil, mode: .live)

                // The loud fact first: a decision whose record failed is never presented and
                // never acknowledged as a success — the failure copy is the answer.
                guard decision.auditRecorded else {
                    logger.error(
                        "mcp-wiring: the decision for \(invocation.providerID)/\(invocation.toolID) was not recorded")
                    return "Something went wrong — the action was not recorded."
                }

                switch decision.decision {
                case .confirmationRequired:
                    let fresh = await provider.describe(invocation)
                    root.widgetStore.presentActionConfirmation(
                        WidgetConfirmationSignal(
                            sentence: fresh.sentence, providerID: invocation.providerID,
                            toolID: invocation.toolID, generation: generation.next()))
                    return nil
                case .invoked(_, let outcome):
                    switch outcome {
                    case .succeeded: return "Done."
                    case .failed: return "Something went wrong."
                    case .notInvoked: return nil
                    }
                case .declined:
                    return "Cancelled."
                case .previewed:
                    return nil
                }
            }

            // The card's Confirm: only this server's card, bound to the sentence shown.
            let confirm: @Sendable @MainActor () async -> Void = {
                guard let signal = root.widgetStore.state.confirmation?.signal else { return }
                guard signal.providerID == providerID else { return }
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
                    // The N2 binding, refused by attempting the call: re-present a fresh card
                    // with the provider's current sentence (a render, not a decision).
                    let fresh = await provider.describe(invocation)
                    root.widgetStore.presentActionConfirmation(
                        WidgetConfirmationSignal(
                            sentence: fresh.sentence, providerID: signal.providerID,
                            toolID: signal.toolID, generation: generation.next()))
                case .invoked, .previewed, .confirmationRequired, .declined:
                    break
                }
            }

            // The card's Decline: the refused decision, recorded, then the card clears.
            let decline: @Sendable @MainActor () async -> Void = {
                guard let signal = root.widgetStore.state.confirmation?.signal else { return }
                guard signal.providerID == providerID else { return }
                root.widgetStore.dismissActionConfirmation()
                guard
                    let invocation = ActionInvocation(
                        providerID: signal.providerID, toolID: signal.toolID)
                else { return }
                let enablement = await configStore.loadEnablement()
                _ = await executor.submit(
                    invocation, enablement: enablement, policy: policy,
                    approval: .withheld, approvedSentence: nil, mode: .live)
            }

            let wiring = MCPServerWiring(
                providerID: providerID,
                arm: arm,
                performAction: performAction,
                confirm: confirm,
                decline: decline,
                executor: executor,
                policy: policy)
            cache.store(wiring, for: providerID)
            return wiring
        }

        return MCPWiring(lookup: lookup, spawnsSubprocess: spawnsSubprocess)
    }
}
