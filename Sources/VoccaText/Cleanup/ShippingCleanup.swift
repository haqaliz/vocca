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

/// The shipping rules provider: the deterministic cleanup engine behind the ``CleanupProvider``
/// seam, over the user's dictionary (`ARCHITECTURE.md:511` — the pure function the conformer
/// composes the seam's context down to).
///
/// The provider is a plain `Sendable` struct over a `Sendable` store: it owns no main-actor
/// adapter, needs no permission, and can never block past the caller's budget — the rules path
/// is pure stdlib behind the store's file read. ``clean(_:context:)`` loads the dictionary
/// lazily on every call (a missing or unreadable `dictionary.json` is the empty rule set the
/// store guarantees, never an error) and runs ``RulesCleanup`` over it. The protocol's throwing
/// shape is unused here — the rules path cannot fail — but it stays declared because the seam
/// is the seam: other providers throw, and the caller degrades both alike.
///
/// `requiresNetwork` is **declared** `false`, not defaulted: the zero-network invariant keys on
/// the declaration, and a provider that is offline by construction should say so itself rather
/// than inherit the default (the B10 contract).
public struct ShippingRulesCleanupProvider: CleanupProvider {
    /// The user dictionary's store — the lazy-load half of the seam's context.
    public let store: FileSystemDictionaryStore

    /// The machine key the seam reserves for the rules engine (`ProviderIdentity.swift:31`).
    public let identity = ProviderIdentity(
        id: "rules-cleanup", displayName: "Deterministic rules")

    /// Declared, not defaulted — the B10 contract (`spec.md` B10a).
    public var requiresNetwork: Bool { false }

    /// Clean one transcript: load the dictionary, run the six fixed stages. Never throws — a
    /// missing dictionary is empty, and the rules themselves are pure.
    public func clean(_ transcript: Transcript, context: CleanupContext) async throws -> String {
        let rules = await store.load()
        return RulesCleanup.clean(transcript.text, dictionary: rules)
    }
}

/// The shipping cleanup's assembly: the rules provider over the user's dictionary, in the one
/// place the composition root can reach it.
///
/// The ``ShippingLadder``/``ShippingPasteboard`` factory precedent, minus the main actor:
/// nothing here composes main-actor adapters — the provider is a pure `Sendable` struct over a
/// `Sendable` store — so this factory needs no isolation domain of its own.
public enum ShippingCleanup {

    /// The shipped ``CleanupProvider``: deterministic rules over the user dictionary.
    ///
    /// - Parameter store: The dictionary's store — the default location
    ///   (`~/Library/Application Support/Vocca/dictionary.json`) at ship, any store in a test.
    ///   Lazy: no prepare step, and a missing or corrupt dictionary is an empty rule set —
    ///   local, zero network, never fatal.
    public static func make(
        store: FileSystemDictionaryStore = FileSystemDictionaryStore()
    ) -> any CleanupProvider {
        ShippingRulesCleanupProvider(store: store)
    }
}
