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

import Synchronization
import VoccaCore
import os

/// **Where a ladder run is remembered** — the write half of C8's strategy memory, as a seam.
///
/// Separate from ``TextInjector`` on purpose (PRD R1): the learning is then testable without real
/// applications, and an injector built without a recorder is byte-for-byte the injector that
/// shipped in C4 (the ``PartialTranscriptSink`` precedent).
///
/// ## The contract callers depend on
///
/// `record` **must not await the persist.** It applies the outcome to the in-memory snapshot —
/// value arithmetic, microseconds — and returns; the disk write is the implementation's own
/// detached business. The ladder's ≤100 ms budget (`ARCHITECTURE.md:318`) is measured around the
/// synchronous inject, and a recorder that awaited a file write would put a disk on the latency
/// path of every dictation.
///
/// It is called on **every** ladder outcome, including the ones that must write nothing: the
/// rung-0 refusals (Secure Input, no focused field) carry `attempted == []`, and the implementation
/// — not the caller — is what decides that no rung was attempted and so nothing was learned
/// (`SMOKE_CHECKLIST.md` step 27).
public protocol InjectionStrategyRecording: Sendable {
    /// Remember one ladder run.
    ///
    /// - Parameters:
    ///   - bundleID: The focused application, or `nil` when nothing was focused — in which case
    ///     there is nothing to remember it against.
    ///   - orderedRungs: The order this run was given, as the ladder asked for it.
    ///   - result: The full outcome, whose `attempted` trace is what the demotion is derived from.
    func record(
        bundleID: String?, orderedRungs: [InjectionRung], result: InjectionResult) async
}

/// **The ladder's memory: one object in three roles.**
///
/// It is the ``InjectionStrategyOrder`` the ladder asks for a rung order, the
/// ``InjectionAllowlist`` the accessibility rung asks for permission, and the
/// ``InjectionStrategyRecording`` the injector reports outcomes to. The composition root hands
/// the *same instance* to all three slots (``ShippingLadder/makeWithMemory(memory:handoff:clock:)``),
/// which is the design's load-bearing decision (PRD R6): the two gates cannot disagree about what
/// has been learned, because they are one decision asked two questions.
///
/// ## Why `contains` must answer the projection, not a membership test
///
/// The obvious implementation — `contains` = seeded ∪ promoted — deadlocks promotion. A candidate
/// reaches the accessibility rung only by being *offered* it, and the rung declines anything
/// `contains` rejects before making a single AX call (`AccessibilityRungStrategy.swift:98-100`).
/// The projection would offer the probe, the rung would refuse it, and the refusal would be
/// recorded as the rung losing — so no application outside the three seeded ones could ever be
/// promoted, and the seed's own comment promises they reach the rung "only through C8's learned
/// memory". Both questions therefore route through
/// ``StrategyMemory/orderedRungs(for:allowlisted:now:)``: `contains` is "does the projection offer
/// accessibility", and a window-elapsed candidate answers yes without yet being trusted — its
/// probe failing re-demotes it with a fresh window.
///
/// ## The candidate marker, which is this adapter's own decision
///
/// Core's fold demotes what was attempted and lost. A non-allowlisted application that delivers by
/// clipboard never attempts accessibility, so the fold has nothing to record and no promotion
/// could ever become due. This type mints the missing state: a clipboard delivery for an
/// application that is neither seeded nor learned marks accessibility demoted with a re-probe
/// window, which is exactly "a candidate, to be probed once, later". It is minted only when no
/// window already exists, so a rung that genuinely failed keeps the window its failure earned.
///
/// ## Isolation
///
/// A `final class` guarding its snapshot with a `Mutex`, rather than the `@MainActor` the rest of
/// the latency path uses. The reason is the allowlist question: ``AccessibilityRungStrategy`` is
/// an actor, and it asks `contains(bundleID:)` **synchronously from its own isolation** — a
/// main-actor-isolated witness could not answer it at all. The lock is held for the length of a
/// dictionary lookup and a pure projection; it is never held across an `await`.
public final class MemoryBackedInjectionStrategyOrder:
    InjectionStrategyOrder, InjectionAllowlist, InjectionStrategyRecording, Sendable
{
    /// The strategies held, by bundle identifier. Loaded once at launch, mutated by `record`, and
    /// read by both projections.
    private let strategies: Mutex<[String: InjectionStrategy]>
    /// The tail of the persist chain, so rapid dictations cannot land out of order.
    private let persistChain: Mutex<Task<Void, Never>?>
    /// The seeded accessibility allowlist — the three blessed native applications.
    private let seed: any InjectionAllowlist
    /// Where the snapshot is persisted. Never read after the launch load.
    private let store: any InjectionStrategyStore
    /// Epoch seconds. The re-probe window's clock, and the only way time enters the memory.
    private let now: @Sendable () -> UInt64
    /// The applications whose accessibility rung starts demoted, kept so the fold can be redone
    /// when the whole set is replaced (the Apps tab's reset).
    private let hostileBundleIDs: Set<String>

    private static let log = Logger(subsystem: "dev.vocca.Vocca", category: "strategy-memory")

    /// - Parameters:
    ///   - seed: The seeded accessibility allowlist — ``SeededInjectionAllowlist`` at ship.
    ///   - strategies: The snapshot loaded from the store, off the session path (PRD T-2). Empty
    ///     is a fresh install, and must project the shipped C4 order.
    ///   - hostileBundleIDs: The applications whose accessibility rung starts demoted, folded in
    ///     here — at load, launch-minted — for every entry the snapshot does not already know.
    ///   - store: Where `record` persists to, in a detached task the caller never awaits.
    ///   - now: Epoch seconds.
    public init(
        seed: any InjectionAllowlist,
        strategies: [InjectionStrategy] = [],
        hostileBundleIDs: Set<String> = SeededHostileApps.hostileBundleIDs,
        store: any InjectionStrategyStore,
        now: @escaping @Sendable () -> UInt64
    ) {
        self.seed = seed
        self.store = store
        self.now = now
        self.hostileBundleIDs = hostileBundleIDs
        self.persistChain = Mutex(nil)
        self.strategies = Mutex(
            Self.folding(strategies, hostileBundleIDs: hostileBundleIDs, now: now()))
    }

    /// The loaded set with the hostile seed folded in: a seeded demotion with a re-probe window
    /// minted from `now`, and **only** where nothing is already known. A learned entry always
    /// wins — the seed is what an application starts as, never a correction applied to what it
    /// became, so a verified promotion is not re-demoted at the next launch.
    private static func folding(
        _ strategies: [InjectionStrategy], hostileBundleIDs: Set<String>, now: UInt64
    ) -> [String: InjectionStrategy] {
        var held: [String: InjectionStrategy] = [:]
        for strategy in strategies where !strategy.bundleID.isEmpty {
            held[strategy.bundleID] = strategy
        }
        for identifier in hostileBundleIDs where held[identifier] == nil {
            held[identifier] = InjectionStrategy(
                bundleID: identifier,
                demotedRungs: [.accessibility],
                reprobeWindows: [
                    .accessibility: now &+ StrategyMemoryTargets.reprobeWindowSeconds
                ])
        }
        return held
    }

    // MARK: - The read side

    /// The rungs the next dictation into `bundleID` attempts. A pure in-memory lookup and a pure
    /// projection — no I/O, on the latency path (PRD X4/G5).
    public func orderedRungs(for bundleID: String?) -> [InjectionRung] {
        guard let bundleID else {
            // Nothing is focused. The decision refuses at rung 0 before reading this at all; the
            // answer matches ``DefaultInjectionStrategyOrder``'s so the two can be compared.
            return [.clipboardPaste, .keystrokeSynthesis]
        }
        return project(bundleID)
    }

    /// Whether the accessibility rung may be attempted for `bundleID` — the rung's own gate.
    ///
    /// The same question the projection answers, asked the other way round: "is accessibility in
    /// the order I would give this application right now". See the type comment for why it cannot
    /// be a membership test.
    public func contains(bundleID: String) -> Bool {
        project(bundleID).contains(.accessibility)
    }

    /// The strategies as they stand — the Apps tab's read and the suite's inspection point.
    public func snapshot() -> [InjectionStrategy] {
        strategies.withLock { Array($0.values) }
    }

    private func project(_ bundleID: String) -> [InjectionRung] {
        let strategy = strategies.withLock { $0[bundleID] } ?? InjectionStrategy(bundleID: bundleID)
        return StrategyMemory.orderedRungs(
            for: strategy, allowlisted: seed.contains(bundleID: bundleID), now: now())
    }

    // MARK: - The write side

    public func record(
        bundleID: String?, orderedRungs: [InjectionRung], result: InjectionResult
    ) async {
        guard let bundleID, !bundleID.isEmpty else { return }
        let instant = now()
        let allowlisted = seed.contains(bundleID: bundleID)

        let updated: InjectionStrategy? = strategies.withLock { held -> InjectionStrategy? in
            let current = held[bundleID] ?? InjectionStrategy(bundleID: bundleID)
            var folded = StrategyMemory.record(
                result: result,
                attempted: result.attempted,
                now: instant,
                allowlisted: allowlisted,
                into: current)
            folded.bundleID = bundleID
            folded = Self.markingPromotionCandidate(
                folded, result: result, allowlisted: allowlisted, now: instant)
            // Compared against `current`, not against the stored entry: for an application
            // nothing is known about, `current` is a freshly synthesised default, and a fold
            // that changed nothing must not turn that default into a stored row. That is the
            // rung-0 refusals' path — Secure Input and no-focused-field attempt nothing, so
            // they learn nothing, so they leave no trace of the application at all.
            guard folded != current else { return nil }
            held[bundleID] = folded
            return folded
        }

        // Nothing changed — the rung-0 refusals land here, and so does a run that only confirmed
        // what was already known. Neither is worth a disk write.
        guard let updated else { return }
        persist(updated)
    }

    /// The candidate marker (see the type comment): a clipboard delivery for an application that
    /// is neither seeded nor learned schedules one accessibility probe, a window from now.
    ///
    /// Deliberately conservative. It never touches an overridden application (a user pin freezes
    /// learning, PRD S2), never re-mints over an existing window — a rung that failed keeps the
    /// window its failure earned — and never applies to an application that is already allowed
    /// through, since there is nothing left to promote.
    private static func markingPromotionCandidate(
        _ strategy: InjectionStrategy,
        result: InjectionResult,
        allowlisted: Bool,
        now: UInt64
    ) -> InjectionStrategy {
        guard result.rung == .clipboardPaste,
            strategy.overrideRungs == nil,
            !allowlisted,
            !strategy.learnedAllowlist,
            strategy.reprobeWindows[.accessibility] == nil,
            !strategy.demotedRungs.contains(.accessibility)
        else {
            return strategy
        }
        var candidate = strategy
        candidate.demotedRungs.insert(.accessibility)
        candidate.reprobeWindows[.accessibility] =
            now &+ StrategyMemoryTargets.reprobeWindowSeconds
        return candidate
    }

    /// Fire and forget, in order. Each write awaits the previous one *inside* the detached task,
    /// so the caller returns immediately and two dictations a keystroke apart still land in the
    /// order they happened.
    private func persist(_ strategy: InjectionStrategy) {
        persistChain.withLock { chain in
            let previous = chain
            chain = Task.detached { [store] in
                await previous?.value
                do {
                    let accepted = try await store.update(strategy)
                    if !accepted {
                        Self.log.error(
                            """
                            Refused to remember \(strategy.bundleID, privacy: .public): the \
                            strategy store is at capacity. Vocca will keep working and keep \
                            re-learning this application every launch; resetting what Vocca has \
                            learned clears the store.
                            """)
                    }
                } catch {
                    Self.log.error(
                        """
                        Could not persist the injection strategy for \
                        \(strategy.bundleID, privacy: .public): \
                        \(String(describing: error), privacy: .public). What was learned this run \
                        still applies until Vocca quits.
                        """)
                }
            }
        }
    }

    /// **Replaces the whole memory** — the Apps tab's write path (PRD R7), and the only one that
    /// is not a consequence of a dictation.
    ///
    /// Unlike `record`, this one *is* awaited: the user pressed a button and is owed either a
    /// saved file or an error on screen, so the failure is thrown rather than logged. It is off
    /// the latency path by construction — a settings window, not a ladder run.
    ///
    /// What is persisted is exactly what the caller decided; the hostile seed is folded into the
    /// **in-memory** set only. Writing the seed to disk would turn it into a stored row, and the
    /// launch-time fold mints only for applications with no entry — so a seeded application
    /// would come back un-seeded at the next launch, quietly, one release later.
    public func replaceAll(_ strategies: [InjectionStrategy]) async throws {
        let folded = Self.folding(
            strategies, hostileBundleIDs: hostileBundleIDs, now: now())
        self.strategies.withLock { $0 = folded }
        try await store.save(strategies)
    }

    /// Awaits every persist spawned so far. The shutdown and test seam — nothing on the latency
    /// path calls it, which is the whole point of the chain it drains.
    public func drainPendingPersists() async {
        await persistChain.withLock { $0 }?.value
    }
}
