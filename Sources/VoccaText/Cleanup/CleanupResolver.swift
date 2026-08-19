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

/// **One cleanup provider for the process**, resolved once at launch from the hand-edited
/// `cleanup-config.json` — the `DictationEngineResolver` resolve-once shape (`prd.md` M7,
/// `DictationEngineResolver.swift:50-149`).
///
/// The resolver is the single source of "which provider runs": the composition root holds its
/// answer, nothing else reads the file, and a mid-session re-read is structurally impossible
/// (resolve-once), so a provider swap can never happen mid-dictation — the
/// `EngineSelectionConsumptionTests` never-swap precedent (`spec.md:55-58`).
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
/// ## Why an actor
///
/// The resolver holds mutable state — the resolved provider, the in-flight build — and the
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

    /// The one provider this process resolved — set once, returned forever after.
    private var resolved: (any CleanupProvider)?

    /// The build currently in flight, if any — the one-flight guard.
    private var inFlight: Task<any CleanupProvider, Never>?

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

    /// Resolves the cleanup provider — at most once.
    ///
    /// Safe to call from anywhere at any time: concurrent calls share one build (the in-flight
    /// guard), and a call after success returns the cached provider without re-reading the file.
    /// Declared `throws` for signature symmetry with the engine resolver; the resolver never
    /// throws — every invalid configuration degrades to the rules provider with a loud log,
    /// never an error.
    public func resolve() async throws -> any CleanupProvider {
        if let resolved {
            return resolved
        }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.build() }
        inFlight = task
        defer { inFlight = nil }
        let provider = await task.value
        resolved = provider
        return provider
    }

    /// Build the provider from the config — never throws; invalid blocks degrade to rules.
    private func build() async -> any CleanupProvider {
        let config = await store.load()
        let rulesProvider = ShippingRulesCleanupProvider(
            store: FileSystemDictionaryStore(directory: store.directory))

        switch config.provider {
        case .rules:
            return rulesProvider
        case .ollama:
            guard let ollama = config.ollama,
                CleanupConfig.isDialableEndpoint(ollama.endpoint),
                let endpoint = URL(string: ollama.endpoint)
            else {
                log("cleanup-config: cannot resolve the ollama block; using the rules provider")
                return rulesProvider
            }
            return ChainedCleanupProvider(
                rules: rulesProvider,
                llm: OllamaCleanupProvider(
                    endpoint: endpoint, model: ollama.model, transport: transport()))
        case .byok:
            guard let byok = config.byok,
                CleanupConfig.isDialableEndpoint(byok.endpoint),
                let endpoint = URL(string: byok.endpoint)
            else {
                log("cleanup-config: cannot resolve the byok block; using the rules provider")
                return rulesProvider
            }
            return ChainedCleanupProvider(
                rules: rulesProvider,
                llm: BYOKCleanupProvider(
                    endpoint: endpoint,
                    model: byok.model,
                    keyProvider: keyProvider(),
                    transport: transport()))
        }
    }
}
