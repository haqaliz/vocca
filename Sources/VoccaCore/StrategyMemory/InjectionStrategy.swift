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

/// The per-app injection strategy C8's memory is made of — the state the ladder's outcomes fold
/// into and the next dictation's rung order projects from (`core-memory/spec.md` M1).
///
/// The invariants that make the strategy safe are **not** enforced by the type — it is a plain
/// value a store, a seed or a test may construct by hand — they are enforced by
/// ``StrategyMemory/record(result:attempted:now:allowlisted:into:)`` and guarded by the
/// projection:
///
/// - `.clipboardPaste` can never be demoted: it is the workhorse (`ROADMAP.md:47`), so no
///   strategy ever empties (X3);
/// - `.widgetFailsafe` never appears in a strategy at all (`injector-seam` plan) — it is the
///   floor under I1, not a rung to learn from;
/// - `overrideRungs != nil` freezes learning: the projection returns it verbatim and the record
///   fold leaves the strategy unchanged (S2 — a user pin is absolute).
public struct InjectionStrategy: Sendable, Equatable {
    /// The rungs demoted for this app. Never contains `.clipboardPaste` or `.widgetFailsafe` —
    /// enforced by ``StrategyMemory/record(result:attempted:now:allowlisted:into:)``, guarded by
    /// ``StrategyMemory/orderedRungs(for:allowlisted:now:)``.
    public var demotedRungs: Set<InjectionRung>
    /// Whether this app learned its way onto the accessibility allowlist — set only by a
    /// **read-back-verified** AX success on a non-allowlisted app (X1), never by the seed.
    public var learnedAllowlist: Bool
    /// For each demoted rung, the epoch second at which it may be re-probed once
    /// (`now >= window`, inclusive). A demoted rung with no entry is never re-probed.
    public var reprobeWindows: [InjectionRung: UInt64]
    /// A user-pinned rung order (the Apps tab), or `nil` while learning. When set, the projection
    /// returns it verbatim and the record fold is frozen for this app (M7).
    public var overrideRungs: [InjectionRung]?

    /// The plain memberwise init with empty defaults — the state a fresh, never-seen app starts
    /// as. A seed (a hostile app's starting demotion) constructs this by hand: seeds are data.
    public init(
        demotedRungs: Set<InjectionRung> = [],
        learnedAllowlist: Bool = false,
        reprobeWindows: [InjectionRung: UInt64] = [:],
        overrideRungs: [InjectionRung]? = nil
    ) {
        self.demotedRungs = demotedRungs
        self.learnedAllowlist = learnedAllowlist
        self.reprobeWindows = reprobeWindows
        self.overrideRungs = overrideRungs
    }
}