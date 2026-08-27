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

/// The one named table of the core-memory aspect's provisional target
/// (`core-memory/plan_20260827.md`; the ``WarmStartTargets`` single-source precedent).
///
/// The window is **provisional by design**: it is R4's decay schedule (`prd.md` — a demoted rung
/// is re-included once after ~7 days), recorded not proven. It lives in exactly this file — the
/// single-source scan in ``StrategyMemoryProjectionTests`` pins the literal here — and a
/// re-baseline from the founder's real matrix run lands here, in exactly one place.
public enum StrategyMemoryTargets {
    /// How long a demoted rung stays demoted before it may be re-probed once. Inclusive: at
    /// exactly `now == window` the rung is eligible again. PROVISIONAL — the `matrix-smoke` run
    /// re-baselines it in exactly this place.
    public static let reprobeWindowSeconds: UInt64 = 604_800
    /// The rung order a fresh, allowlisted app starts with — accessibility, then clipboard-paste,
    /// then keystroke synthesis, exactly `ARCHITECTURE.md:398-403`'s ladder order minus the
    /// failsafe (which never appears in a strategy). The projection's base; `memory-order` will
    /// consume it in place of the `VoccaInject` default.
    public static let canonicalRungOrder: [InjectionRung] = [.accessibility, .clipboardPaste, .keystrokeSynthesis]
}

/// The pure decisions C8's strategy memory is made of: the ordered-rungs projection and the
/// re-probe eligibility query (`core-memory/spec.md` M3/M4). No clock — `now` is an argument,
/// epoch seconds; the caller owns the real time.
public enum StrategyMemory {

    /// The rung order the next dictation for this app attempts: canonical order minus demoted
    /// rungs, with a demoted rung re-included once `now >=` its re-probe window (inclusive,
    /// one-shot — the projection is idempotent and the record fold consumes the eligibility, M6).
    ///
    /// The allowlist gate is composed here, not pre-folded into the strategy:
    /// `.accessibility` is included only when `allowlisted`, `learnedAllowlist`, **or** its
    /// re-probe is due — the elapsed re-probe beats the gate, which is the R6 promotion probe's
    /// projection shape. `.clipboardPaste` is never dropped, so the result is never empty (X3),
    /// and `.widgetFailsafe` never appears. An `overrideRungs` set is returned verbatim (M7).
    public static func orderedRungs(
        for strategy: InjectionStrategy, allowlisted: Bool, now: UInt64
    ) -> [InjectionRung] {
        if let override = strategy.overrideRungs {
            return override
        }
        var result: [InjectionRung] = []
        for rung in StrategyMemoryTargets.canonicalRungOrder {
            if rung == .clipboardPaste {
                result.append(rung)
                continue
            }
            let reProbeDue = reprobeEligibility(for: rung, in: strategy, now: now)
            if strategy.demotedRungs.contains(rung) && !reProbeDue {
                continue
            }
            if rung == .accessibility
                && !(allowlisted || strategy.learnedAllowlist || reProbeDue)
            {
                continue
            }
            result.append(rung)
        }
        return result
    }

    /// Is `rung` owed its one-shot re-probe for this app? Demoted **and** a window entry exists
    /// **and** `now >= window` (inclusive). A demoted rung with no window is never eligible —
    /// tolerant-decode strays stay on clipboard (M4, O3). No special-casing of clipboard or
    /// failsafe here: the projection is the single enforcement point of the never-demote
    /// invariants.
    public static func reprobeEligibility(
        for rung: InjectionRung, in strategy: InjectionStrategy, now: UInt64
    ) -> Bool {
        guard strategy.demotedRungs.contains(rung) else { return false }
        guard let window = strategy.reprobeWindows[rung] else { return false }
        return now >= window
    }

    /// The fold: one ladder outcome — with the trace it demotes on passed explicitly — becomes
    /// the next dictation's strategy (`core-memory/spec.md` M5/M6, "The record fold, precisely").
    ///
    /// `attempted` is normally `result.attempted`, but it is an argument because the rung-0 rows
    /// carry `attempted: []` (Secure Input refusals, `bundleID == nil`) and a result carrying a
    /// truncated trace must not silently change the demotion. `allowlisted:` is the seeded
    /// allowlist's answer **without** `learnedAllowlist` folded in — the projection composes the
    /// OR itself, so a first promotion is observable.
    ///
    /// The rules, in order: no rung attempted → unchanged; the strict prefix of `attempted`
    /// before the winner (or every attempted rung when the failsafe won — it always succeeds) is
    /// demoted with a fresh window, never clipboard, never failsafe; a demoted rung that won is
    /// restored, its window dropped — unconditional on the window having elapsed; a
    /// read-back-verified AX win on a non-allowlisted app promotes (X1). Nothing else is this
    /// function's concern.
    public static func record(
        result: InjectionResult,
        attempted: [InjectionRung],
        now: UInt64,
        allowlisted: Bool,
        into strategy: InjectionStrategy
    ) -> InjectionStrategy {
        guard !attempted.isEmpty else {
            return strategy
        }
        var updated = strategy
        switch result.rung {
        case .widgetFailsafe:
            for rung in attempted where rung != .clipboardPaste && rung != .widgetFailsafe {
                updated.demotedRungs.insert(rung)
                updated.reprobeWindows[rung] = now + StrategyMemoryTargets.reprobeWindowSeconds
            }
        case .accessibility, .clipboardPaste, .keystrokeSynthesis:
            guard let winnerIndex = attempted.firstIndex(of: result.rung) else {
                return strategy
            }
            for rung in attempted[..<winnerIndex]
            where rung != .clipboardPaste && rung != .widgetFailsafe {
                updated.demotedRungs.insert(rung)
                updated.reprobeWindows[rung] = now + StrategyMemoryTargets.reprobeWindowSeconds
            }
        }
        if updated.demotedRungs.contains(result.rung) {
            updated.demotedRungs.remove(result.rung)
            updated.reprobeWindows[result.rung] = nil
        }
        if result.rung == .accessibility && result.verified && !allowlisted {
            updated.learnedAllowlist = true
        }
        return updated
    }
}