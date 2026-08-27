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

/// The in-memory ``InjectionStrategyStore`` — the store every headless test and every
/// non-persisting composition path uses (`prd.md` R1's "EphemeralStore in every headless
/// test"). No disk, no seam, no throws: nothing can fail in memory, so `update`'s throw channel
/// is never exercised here.
///
/// The held set is an **ordered** array, not a dictionary, because the file's declared order is
/// load-bearing (the dictionary's order-survives-reload contract): the store preserves the
/// order strategies were updated in, and `save` replaces it wholesale.
///
/// The cap is ``InjectionStrategyStoreConstants.maximumRememberedApps`` by default — refusal,
/// never eviction: at capacity, `update` of a new bundle ID returns `false` and is not held;
/// updates of known apps always succeed (S1).
public actor EphemeralInjectionStrategyStore: InjectionStrategyStore {
    private let capacity: Int
    private var held: [InjectionStrategy] = []

    /// A store holding at most `capacity` remembered apps — injectable at a tiny value so the
    /// refusal is testable, defaulting to the Core-owned cap.
    public init(capacity: Int = InjectionStrategyStoreConstants.maximumRememberedApps) {
        self.capacity = capacity
    }

    // MARK: - InjectionStrategyStore

    /// The held strategies, in update order — initially the empty set.
    public func load() async -> [InjectionStrategy] {
        held
    }

    /// Upsert `strategy` by its bundle ID. A new app at capacity is refused loudly (`false` and
    /// not held); a new app under the cap, and every update of a known app, is held and
    /// `true`. Never throws.
    public func update(_ strategy: InjectionStrategy) async throws -> Bool {
        if let index = held.firstIndex(where: { $0.bundleID == strategy.bundleID }) {
            held[index] = strategy
            return true
        }
        guard held.count < capacity else { return false }
        held.append(strategy)
        return true
    }

    /// Replace the whole held set — uncapped: the deliberate reset/edit write is not subject
    /// to the learning cap.
    public func save(_ strategies: [InjectionStrategy]) async throws {
        held = strategies
    }
}