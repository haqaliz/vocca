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

/// The seam C8's learning writes through and reads from — the store of per-app injection
/// strategies, separated from `TextInjector` so the learning is testable without real apps
/// (`prd.md` R1). The protocol is the only Core surface of the store; the decisions stay out of
/// it — the store moves strategies, it never decides about them.
///
/// ## Concurrency contract
///
/// Single process, one writer: `load()` once at launch (the custody-chain load, `prd.md` T-2),
/// then `update`/`save` mutate the held set and persist the **whole set** atomically — a racing
/// pair of updates ends with one complete file, and the in-memory set carries the other entry
/// forward to the next persist. Implementations are actors; the atomic rename means a
/// concurrent read sees the old or the new complete file, never a partial one.
///
/// ## Persistence contract
///
/// ``load()`` never throws: a missing file is the empty set silently; a corrupt element is
/// skipped with one loud log; the file is never rewritten by a load. ``update(_:)`` throws when
/// the persist fails — the file was *not* updated while the held set says it was, and the
/// caller (memory-order's recorder, in its detached task) must be able to see and log it — and
/// returns `false` for a cap refusal (a loud refusal, never an eviction). ``save(_:)`` is the
/// deliberate wholesale write — the reset-learned and future editing paths — and is not subject
/// to the learning cap.
///
/// ## Privacy constraint
///
/// A strategy carries only its bundle ID, `InjectionRung` identifiers and integer epoch
/// seconds — no text, no transcripts, nothing content-shaped (`prd.md` "Privacy"). The schema
/// is that boundary, and the value type's own shape is what keeps it.
public protocol InjectionStrategyStore: Sendable {
    /// The strategies held, loaded from the store's backing (the empty set on first run).
    /// Never throws. For the persistent store: missing → empty silently; corrupt → the readable
    /// remainder with one loud log per skipped element; the file is never rewritten.
    func load() async -> [InjectionStrategy]

    /// Upsert `strategy` by its bundle ID into the held set and persist.
    /// Returns `false` when at capacity and `strategy` is a new app — a loud refusal, never an
    /// eviction; the file is untouched. Updates of known apps always succeed. Throws when the
    /// persist fails (the caller owns the fire-and-forget and must log — T-2).
    func update(_ strategy: InjectionStrategy) async throws -> Bool

    /// Replace the whole held set and persist — the reset-learned and future editing paths.
    /// Deliberate wholesale writes are not subject to the learning cap.
    func save(_ strategies: [InjectionStrategy]) async throws
}

/// The one named table of the store's bounded-memory claim (`prd.md` S1): at this many held
/// strategies, `update` of a *new* bundle ID is refused loudly — never evicted (the
/// ``LatencyLedger.maximumRetainedRecords`` cap-512 precedent, in exactly one place, pinned by a
/// single-source scan). `load` and `save` are uncapped: the file is user-owned, and
/// reset-learned is the user's own eviction mechanism.
public enum InjectionStrategyStoreConstants {
    /// The cap on remembered apps (PRD S1).
    public static let maximumRememberedApps = 512
}