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

/// One application as the Apps tab was handed it: the strategy the ladder reads, the name a
/// person recognises it by, whether the seeded allowlist blesses it, and whether the user
/// granted Vocca context consent for it (C12, M4 — the tab is the consent UI's recorded
/// home, `consent-store`'s hand-off).
///
/// `isAllowlisted` travels in the snapshot rather than being looked up, because the seeded
/// allowlist lives in `VoccaInject` and this module may import only `VoccaCore`
/// (`ModuleBoundaryTests`). The wiring knows both and answers once, per application, at read
/// time — which is also what makes the whole tab testable with no store at all.
public struct AppStrategyEntry: Sendable, Equatable {
    /// The application, as every other part of the system identifies it.
    public var bundleID: String
    /// What to call it on screen. The bundle identifier when nothing better resolved — never
    /// blank, so a row is never nameless.
    public var displayName: String
    /// What Vocca has learned, or what the user pinned.
    public var strategy: InjectionStrategy
    /// Whether the seeded accessibility allowlist blesses this application.
    public var isAllowlisted: Bool
    /// Whether the user granted per-app context consent — **off by default** (M4): off is
    /// both the fresh-install truth and the safe direction, and a grant is a user decision
    /// that reset ("what Vocca learned") must never clear.
    public var isContextConsented: Bool

    public init(
        bundleID: String, displayName: String, strategy: InjectionStrategy, isAllowlisted: Bool,
        isContextConsented: Bool = false
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.strategy = strategy
        self.isAllowlisted = isAllowlisted
        self.isContextConsented = isContextConsented
    }
}

/// One row of the Apps table.
public struct AppsRow: Sendable, Equatable, Identifiable {
    /// The row's identity — one row per application, always.
    public let bundleID: String
    /// The name shown in the first column.
    public let displayName: String
    /// How Vocca types into this application, in the health vocabulary.
    public let health: AppsTabHealth
    /// Whether the user pinned this application, rather than Vocca working it out.
    public let isOverridden: Bool
    /// The pin, when it is one of the three the picker offers. `nil` for a learned row — and
    /// also for an overridden row whose stored order is something the picker does not know,
    /// which a hand-edited `strategies.json` can produce.
    public let method: AppsTabMethod?
    /// Whether the user granted context consent for this application (C12, M4).
    public let isContextConsented: Bool

    public var id: String { bundleID }

    public init(
        bundleID: String, displayName: String, health: AppsTabHealth, isOverridden: Bool,
        method: AppsTabMethod?, isContextConsented: Bool = false
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.health = health
        self.isOverridden = isOverridden
        self.method = method
        self.isContextConsented = isContextConsented
    }
}

/// What the Apps tab is showing.
public struct AppsTabState: Sendable, Equatable {
    /// The rows, sorted by display name.
    public var rows: [AppsRow]
    /// Whether the snapshot has landed. `false` with no rows is "we haven't looked yet"; `true`
    /// with no rows is the empty state, and the two must not render the same
    /// (the ``SettingsCopy/dictionaryEmpty`` guard).
    public var isLoaded: Bool
    /// The last write failure, in the store's own words. `nil` once a write succeeds.
    public var saveError: String?
    /// The truth the rows are derived from, keyed by bundle identifier.
    public var entries: [String: AppStrategyEntry]

    /// The state the window opens in.
    public static let initial = AppsTabState(
        rows: [], isLoaded: false, saveError: nil, entries: [:])

    public init(
        rows: [AppsRow], isLoaded: Bool, saveError: String?,
        entries: [String: AppStrategyEntry]
    ) {
        self.rows = rows
        self.isLoaded = isLoaded
        self.saveError = saveError
        self.entries = entries
    }
}

/// Everything that can happen to the Apps tab. A closed set, folded exhaustively, with no
/// time-based transition in it — the widget's never-auto-dismiss discipline, applied to a
/// settings surface for the same reason: nothing here should change while a user is reading it.
public enum AppsTabAction: Sendable, Equatable {
    /// The store was read; these are its applications, with names and allowlist answers.
    case snapshotLoaded([AppStrategyEntry])
    /// The consent store was read; these are the consented bundle IDs. The rows render the
    /// store's truth — grants are never remembered by the tab.
    case contextConsentLoaded([String])
    /// The user flipped an application's consent toggle.
    case contextConsentSet(bundleID: String, consented: Bool)
    /// The user pinned an application to a method.
    case overrideSet(bundleID: String, method: AppsTabMethod)
    /// The user removed a pin, returning the application to what Vocca learned.
    case overrideCleared(bundleID: String)
    /// "Reset what Vocca learned."
    case resetLearned
    /// The write-through landed.
    case saveSucceeded
    /// The write-through failed, with the store's message.
    case saveFailed(String)
}

/// The Apps tab's decisions — pure, clock-free, and holding no memory logic of its own.
public enum AppsTabReducer {

    /// The instant the health column is computed at — unused, and that is the point.
    ///
    /// The column must report what an application has **settled** into, not whether a re-probe
    /// happens to be due this second: a probe is scheduled, nothing has been learned yet, and a
    /// settings table that changed its answer because a week elapsed while it was open would be
    /// reporting a scheduling detail as a fact about the app. So the projection is asked with the
    /// re-probe windows stripped, which makes eligibility structurally impossible
    /// (a demoted rung with no window is never re-included — Core's M4 rule) rather than merely
    /// unlikely. With no window to compare against, the instant cannot matter.
    private static let unusedInstant: UInt64 = 0

    public static func reduce(_ state: AppsTabState, _ action: AppsTabAction) -> AppsTabState {
        var next = state
        switch action {
        case .snapshotLoaded(let entries):
            next.entries = Dictionary(
                entries.map { ($0.bundleID, $0) }, uniquingKeysWith: { _, last in last })
            next.isLoaded = true

        case .contextConsentLoaded(let consented):
            // The store's answer folded both ways: a consented app the strategies store
            // knows nothing about gets its row created (the `overrideSet` creation
            // precedent — consent is a user decision, never hidden because Vocca has not
            // typed into the app), and an entry whose grant the store no longer holds
            // loses it (the toggle renders the store's truth, never a remembered grant).
            let granted = Set(consented)
            for bundleID in granted {
                var entry =
                    next.entries[bundleID]
                    ?? AppStrategyEntry(
                        bundleID: bundleID, displayName: bundleID, strategy: InjectionStrategy(),
                        isAllowlisted: false)
                entry.isContextConsented = true
                next.entries[bundleID] = entry
            }
            for (bundleID, entry) in next.entries where !granted.contains(bundleID) {
                var updated = entry
                updated.isContextConsented = false
                next.entries[bundleID] = updated
            }
            next.saveError = nil

        case .contextConsentSet(let bundleID, let consented):
            // One app at a time — never a blanket allow (M4): the toggle folds exactly the
            // application it sits on, and an entry nothing is known about cannot be granted
            // from a row that does not exist.
            if var entry = next.entries[bundleID] {
                entry.isContextConsented = consented
                next.entries[bundleID] = entry
            }
            next.saveError = nil

        case .overrideSet(let bundleID, let method):
            // An override on an application nothing is known about creates it: the pin *is* a
            // strategy, so there is now something to remember. The bundle identifier stands in
            // as the name until a snapshot resolves a better one.
            var entry =
                next.entries[bundleID]
                ?? AppStrategyEntry(
                    bundleID: bundleID, displayName: bundleID, strategy: InjectionStrategy(),
                    isAllowlisted: false)
            entry.strategy.bundleID = bundleID
            entry.strategy.overrideRungs = method.rungs
            next.entries[bundleID] = entry
            next.saveError = nil

        case .overrideCleared(let bundleID):
            if var entry = next.entries[bundleID] {
                entry.strategy.overrideRungs = nil
                next.entries[bundleID] = entry
            }
            next.saveError = nil

        case .resetLearned:
            // Everything learned goes, row and all — not an emptied row. An entry that survived
            // as an empty strategy would also survive the launch-time hostile seed, which mints
            // only for applications with no entry at all, so a seeded-hostile app would come
            // back quietly *un*-seeded. What the user pinned is not learning and stays, with the
            // learned fields around it cleared — and so does what the user **consented** (C12,
            // M4): consent is a user decision, never learning, and a reset that hid the grant
            // from the very table that manages it would read as if the grant had been lost.
            next.entries = next.entries.compactMapValues { entry in
                if let override = entry.strategy.overrideRungs {
                    var kept = entry
                    kept.strategy = InjectionStrategy(
                        bundleID: entry.bundleID, overrideRungs: override)
                    return kept
                }
                guard entry.isContextConsented else { return nil }
                var kept = entry
                kept.strategy = InjectionStrategy(bundleID: entry.bundleID)
                return kept
            }
            next.saveError = nil

        case .saveSucceeded:
            next.saveError = nil

        case .saveFailed(let message):
            next.saveError = message
        }
        next.rows = rows(from: next.entries)
        return next
    }

    /// The rows an entry set produces: one per application, sorted by the name a person reads,
    /// with the bundle identifier as a stable tiebreak — a table whose order changed between
    /// openings looks like the data changed.
    private static func rows(from entries: [String: AppStrategyEntry]) -> [AppsRow] {
        entries.values
            .map(row(for:))
            .sorted {
                $0.displayName == $1.displayName
                    ? $0.bundleID < $1.bundleID
                    : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    private static func row(for entry: AppStrategyEntry) -> AppsRow {
        var settled = entry.strategy
        settled.reprobeWindows = [:]
        let projected = StrategyMemory.orderedRungs(
            for: settled, allowlisted: entry.isAllowlisted, now: unusedInstant)
        // The projection is never empty — clipboard is exempt from demotion (PRD R2/X3) — but
        // the fallback is spelled rather than force-unwrapped: a crash in a settings table is a
        // poor way to learn that an invariant moved.
        let health = AppsTabHealth(firstRung: projected.first ?? .clipboardPaste)
        let override = entry.strategy.overrideRungs
        return AppsRow(
            bundleID: entry.bundleID,
            displayName: entry.displayName,
            health: health,
            isOverridden: override != nil,
            method: override.flatMap(AppsTabMethod.init(rungs:)),
            isContextConsented: entry.isContextConsented)
    }
}
