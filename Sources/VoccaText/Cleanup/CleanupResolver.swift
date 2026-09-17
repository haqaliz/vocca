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

import Foundation
import OSLog
import VoccaCore

/// **One cleanup provider per mode**, resolved once at launch from the hand-edited
/// `cleanup-config.json` — the `DictationEngineResolver` resolve-once shape (`prd.md` M7,
/// `DictationEngineResolver.swift:50-149`), now serving both halves of the product's dual mode
/// (C11, D2): ``resolve(mode:)`` answers the selection the file names for dictation and for
/// conversations, and the no-arg forms are the dictate half exactly as before.
///
/// The resolver is the single source of "which provider runs": the composition root holds its
/// answer, nothing else reads the file, and a mid-session re-read is structurally impossible
/// (resolve-once per mode), so a provider swap can never happen mid-dictation or mid-conversation —
/// the `EngineSelectionConsumptionTests` never-swap precedent (`spec.md:55-58`), extended to the
/// pair.
///
/// ## One file read, both halves
///
/// The single-flight guard holds a ``ResolvedPair`` — the first resolve (either mode) reads the
/// file once and builds both halves, and a resolve of the other mode returns the cached half
/// without re-reading. The B4 pin holds even when both modes are resolved (`fileExists == 1`).
///
/// ## The decision table
///
/// - `rules` (or an absent file — the default) ⇒ the shipped rules provider;
/// - `ollama` ⇒ ``ChainedCleanupProvider``(rules + `OllamaCleanupProvider` at the configured
///   endpoint/model);
/// - `byok` ⇒ a chain over `BYOKCleanupProvider` at the configured endpoint/model, reading its
///   key through the injected key-provider factory;
/// - any invalid block already degraded to `.rules` in ``CleanupConfig/tolerantDecode(_:log:)``
///   with a loud log — the resolver never silently differs from the file, and its own defensive
///   guard (a block that somehow survived with an undialable endpoint) degrades the same way.
///
/// The dictate half runs this table over `provider`; the converse half runs the identical table
/// over `converseProvider`, with the per-mode degrade of D1 (an invalid converse selection
/// degrades only the converse half).
///
/// ## Why an actor
///
/// The resolver holds mutable state — the resolved pair, the in-flight build — and the
/// single-flight guard is the `DictationEngineResolver`/`ModelStore` one-flight shape: concurrent
/// callers share one build, and a call after success returns the cached provider without
/// re-reading the file.
public actor CleanupResolver {

    /// How a transport is built — injected so the probe wires a stub (`root-wiring`).
    public typealias TransportFactory = @Sendable () -> any LLMTransport

    /// How a key provider is built — injected so the probe wires a stub (`root-wiring`).
    public typealias KeyProviderFactory = @Sendable () -> any KeyProvider

    /// The config's store — the read path, driven at most once.
    private let store: CleanupConfigStore

    /// The transport factory the LLM stages are built with.
    private let transport: TransportFactory

    /// The key-provider factory the BYOK stage is built with.
    private let keyProvider: KeyProviderFactory

    /// The loud half of the degrade policy — an injectable log for tests.
    private let log: @Sendable (String) -> Void

    /// The two providers this process resolved — one per ``SessionMode``, set once, returned
    /// forever after.
    private var resolved: ResolvedPair?

    /// The build currently in flight, if any — the one-flight guard, now pair-shaped.
    private var inFlight: Task<ResolvedPair, Never>?

    /// - Parameters:
    ///   - store: The config store to read. The rules provider's dictionary store is derived
    ///     from the same directory (both files live in the same Application Support/Vocca
    ///     folder), so a test's temp directory isolates both.
    ///   - transport: The transport the LLM stages are built with.
    ///   - keyProvider: The key provider the BYOK stage is built with.
    ///   - log: The degrade-policy log, injectable in tests.
    public init(
        store: CleanupConfigStore,
        transport: @escaping TransportFactory,
        keyProvider: @escaping KeyProviderFactory,
        log: @escaping @Sendable (String) -> Void = {
            Logger(subsystem: "dev.vocca.Vocca", category: "cleanup").error("\($0)")
        }
    ) {
        self.store = store
        self.transport = transport
        self.keyProvider = keyProvider
        self.log = log
    }

    /// Resolves the cleanup provider for `mode` — at most once per mode.
    ///
    /// Safe to call from anywhere at any time: concurrent calls share one build (the in-flight
    /// guard), and a call after success returns the cached provider without re-reading the file.
    /// Declared `throws` for signature symmetry with the engine resolver; the resolver never
    /// throws — every invalid configuration degrades to the rules provider with a loud log,
    /// never an error.
    public func resolve(mode: SessionMode) async throws -> any CleanupProvider {
        let pair = await resolvedPair()
        switch mode {
        case .dictation: return pair.dictation
        case .conversing: return pair.conversing
        }
    }

    /// The dictate half of ``resolve(mode:)`` — today's single-provider surface, byte-identical.
    public func resolve() async throws -> any CleanupProvider {
        try await resolve(mode: .dictation)
    }

    /// The endpoint `mode`'s resolved provider sends text to — `nil` when rules is selected (or
    /// before a resolve). The composition root folds the egress badge from this
    /// (`WidgetEgressState/fromResolvedProvider(requiresNetwork:end point:)`); never the key.
    public func egressEndpoint(mode: SessionMode) async -> String? {
        switch mode {
        case .dictation: return resolved?.dictationEndpoint
        case .conversing: return resolved?.conversingEndpoint
        }
    }

    /// The dictate half of ``egressEndpoint(mode:)``.
    public func egressEndpoint() async -> String? {
        await egressEndpoint(mode: .dictation)
    }

    /// **What the Cleanup tab reports for `mode`** — the resolved provider's name and egress,
    /// derived rather than read off the file (F3).
    ///
    /// Resolves first, so the answer is about the provider that is actually running: an `ollama`
    /// selection with an undialable endpoint has already degraded to rules here, and a tab echoing
    /// the file would tell a user their text goes to a machine nothing ever dials. Safe to call
    /// at any time — ``resolve(mode:)`` is single-flight and resolve-once, so asking costs one
    /// dictionary-store construction on the first call and nothing afterwards.
    public func summary(mode: SessionMode) async -> CleanupSummary {
        guard let provider = try? await resolve(mode: mode) else {
            // Unreachable: `resolve(mode:)` never throws (every invalid configuration degrades
            // to the rules provider). Spelled as the safe direction rather than force-unwrapped,
            // and the safe direction here is the local one — a settings page must not invent
            // egress.
            return CleanupSummary(
                name: ShippingRulesCleanupProvider(
                    store: FileSystemDictionaryStore(directory: store.directory)
                ).identity.displayName,
                sendsTextOffTheMac: false,
                endpoint: nil)
        }
        return CleanupSummary.resolved(
            identity: provider.identity,
            requiresNetwork: provider.requiresNetwork,
            endpoint: await egressEndpoint(mode: mode))
    }

    /// The dictate half of ``summary(mode:)``.
    public func summary() async -> CleanupSummary {
        await summary(mode: .dictation)
    }

    /// The single-flight guard, pair-shaped: one file read builds both halves.
    private func resolvedPair() async -> ResolvedPair {
        if let resolved {
            return resolved
        }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.build() }
        inFlight = task
        defer { inFlight = nil }
        let pair = await task.value
        resolved = pair
        return pair
    }

    /// Build both halves from one config read — never throws; invalid blocks degrade to rules.
    private func build() async -> ResolvedPair {
        let config = await store.load()
        let rulesProvider = ShippingRulesCleanupProvider(
            store: FileSystemDictionaryStore(directory: store.directory))
        let dictation = build(selection: config.provider, config: config, rules: rulesProvider)
        let conversing = build(
            selection: config.converseProvider, config: config, rules: rulesProvider)
        return ResolvedPair(
            dictation: dictation.provider,
            dictationEndpoint: dictation.endpoint,
            conversing: conversing.provider,
            conversingEndpoint: conversing.endpoint)
    }

    /// The decision table for one selection — the dictate and converse halves run the identical
    /// table, each over its own key.
    private func build(
        selection: CleanupProviderKind,
        config: CleanupConfig,
        rules: ShippingRulesCleanupProvider
    ) -> (provider: any CleanupProvider, endpoint: String?) {
        switch selection {
        case .rules:
            return (rules, nil)
        case .ollama:
            guard let ollama = config.ollama,
                CleanupConfig.isDialableEndpoint(ollama.endpoint),
                let endpoint = URL(string: ollama.endpoint)
            else {
                log("cleanup-config: cannot resolve the ollama block; using the rules provider")
                return (rules, nil)
            }
            return (
                ChainedCleanupProvider(
                    rules: rules,
                    llm: OllamaCleanupProvider(
                        endpoint: endpoint, model: ollama.model, transport: transport())),
                ollama.endpoint)
        case .byok:
            guard let byok = config.byok,
                CleanupConfig.isDialableEndpoint(byok.endpoint),
                let endpoint = URL(string: byok.endpoint)
            else {
                log("cleanup-config: cannot resolve the byok block; using the rules provider")
                return (rules, nil)
            }
            return (
                ChainedCleanupProvider(
                    rules: rules,
                    llm: BYOKCleanupProvider(
                        endpoint: endpoint,
                        model: byok.model,
                        keyProvider: keyProvider(),
                        transport: transport())),
                byok.endpoint)
        }
    }
}

/// The one flight's answer — both modes' providers and their endpoints, resolved together.
private struct ResolvedPair {
    let dictation: any CleanupProvider
    let dictationEndpoint: String?
    let conversing: any CleanupProvider
    let conversingEndpoint: String?
}
