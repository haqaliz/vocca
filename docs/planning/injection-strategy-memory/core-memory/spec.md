# Spec — core-memory (aspect 1 of injection-strategy-memory)

## Problem slice

The ladder (C4) does not learn: `DefaultInjectionStrategyOrder` recomputes the same rung order
from the seeded allowlist on every dictation, so a rung that failed for an app is retried every
time (`CAPABILITY_ROADMAP.md:180`), and a non-allowlisted app can never reach the accessibility
rung at all — the seeded allowlist's own comment promises that path only through "C8's learned
memory" (`SeededInjectionAllowlist.swift:30`). None of the learning vocabulary exists yet: there
is no per-bundleID strategy value, no demotion rule, no re-probe schedule, no promotion flag —
and the PRD's mechanism (R2–R6) is entirely pure decisions over exactly that vocabulary.

## User outcome

After this aspect, the *decisions* the memory is made of exist as tested, stdlib-only code in
`VoccaCore`: a failed rung is demoted for that app, a demoted rung is re-tried once after a
re-probe window instead of being written off, a verified AX success promotes a non-allowlisted
app, and no strategy ever empties (clipboard is the floor). No store, no wiring, no UI — but
every later aspect (`store-seam`, `memory-order`) builds on functions that are already proven
headless in CI rather than on prose.

## In-scope

All of it lives in `Sources/VoccaCore/StrategyMemory/` — stdlib-only, no Foundation (the
`CoreBoundaryTests` rule; timestamps are integer epoch seconds, `UInt64`), headless-tested in
`Tests/HarnessTests/`.

| # | Item | PRD mapping |
|---|------|-------------|
| M1 | `InjectionStrategy` value type: `demotedRungs: Set<InjectionRung>` (never `.clipboardPaste`, never `.widgetFailsafe`), `learnedAllowlist: Bool`, `reprobeWindows: [InjectionRung: UInt64]`, `overrideRungs: [InjectionRung]?` (nil = learned; a user pin, see M7). Sendable, Equatable, plain memberwise init with empty defaults (the per-app strategy a fresh app starts as). | R1's value half; R2/R3/R6 state; S2 |
| M2 | `StrategyMemoryTargets`: the two named constants in exactly one file — `reprobeWindowSeconds: UInt64 = 604_800` (PROVISIONAL, the `WarmStartTargets` single-source precedent; the founder's real run re-baselines it in exactly this place) and `canonicalRungOrder = [.accessibility, .clipboardPaste, .keystrokeSynthesis]`. | R4's decay schedule; the canonical order |
| M3 | `StrategyMemory.orderedRungs(for:allowlisted:now:) -> [InjectionRung]` — the projection: canonical order minus demoted rungs; a demoted rung is re-included when `now >= reprobeWindows[rung]` (inclusive; one-shot — see M6); `.accessibility` included only if `allowlisted || learnedAllowlist` **or** re-included by re-probe (the re-probe beats the allowlist gate — that is the R6 promotion probe's shape); `.clipboardPaste` never dropped, so the result is never empty (X3); `.widgetFailsafe` never appears. | R2 start-there-next-time, R4, R5's seed shape, R6, G5 (a pure in-memory read — `now` is an argument, no clock in Core), X3 |
| M4 | `StrategyMemory.reprobeEligibility(for:in:now:) -> Bool` — the query: demoted **and** a window exists **and** `now >= window`. A demoted rung with no window entry is never eligible (tolerant-decode strays are never re-probed — the store aspect inherits this decision). Plain formula: no special-casing of clipboard/failsafe here; the projection is the single enforcement point of the never-demote invariants. | R4 |
| M5 | `StrategyMemory.record(result:attempted:now:allowlisted:into:) -> InjectionStrategy` — the fold: demote-on-fail, promotion, re-probe restore/re-demote. `attempted` is the ladder trace (normally `result.attempted`; passed explicitly because the rung-0 rows carry `attempted: []` — the shared vocabulary's shape). `allowlisted:` is the seeded/current allowlist's answer **without** `learnedAllowlist` folded in (the projection composes the OR itself, so a first promotion is observable). | R3, R6, R8's pure half, X1 |
| M6 | One-shot re-probe is a **record-side** guarantee. The projection is idempotent (a pure function of `(strategy, allowlisted, now)` — re-including while the window is elapsed is its definition), and the record fold consumes the eligibility: success removes the rung from `demotedRungs` and drops its window; failure re-demotes with a fresh window (`now + reprobeWindowSeconds`). No counter, no flag, no timer — re-probe stays lazy (evaluated on the next dictation for that app). | R4's "re-probed **once**" |

| M7 | Overrides (S2) ARE Core vocabulary — a user pin is absolute. `overrideRungs` set → the projection returns the override verbatim (never reordered, never re-probed); the record fold returns the strategy unchanged (no demotion, no promotion, no window movement — learning is frozen for that app). An override is validated at construction: non-empty, never `.widgetFailsafe`. `.clipboardPaste` may appear anywhere in an override (it is a user pin, not a learned invariant). The Apps-tab aspect renders/sets the field; `memory-order`/`record` freeze it here, not in their own code. | S2's absolute-override + frozen-learning, in one place |

### The record fold, precisely

Rule 0 (overrides): `overrideRungs != nil` → return the strategy unchanged, before anything else.
(An overridden app is frozen — no demotion, no promotion, no window movement.)

1. `attempted == []` → return the strategy unchanged. (Rung-0 rows: Secure Input refusals and
   `bundleID == nil` — "no rung was attempted", `SMOKE_CHECKLIST.md` step 27; also any winner
   with an empty trace.)
2. Demotion candidates:
   - winner `.widgetFailsafe` → every rung in `attempted` (the failsafe always succeeds; every
     attempted rung failed).
   - winner a real rung → the strict prefix of `attempted` before the winner's index. A winner
     absent from `attempted` → no candidates (caller-error defense: do not guess — the real
     ladder always carries the winner in the trace).
   - `.clipboardPaste` and `.widgetFailsafe` are never candidates, whatever the trace says.
3. Every candidate (fresh or already demoted) lands in `demotedRungs` and gets
   `reprobeWindows[rung] = now + reprobeWindowSeconds` — a re-demotion always carries a fresh
   window.
4. If the winner is in `demotedRungs` (a successful re-probe attempt), remove it and drop its
   window entry. Unconditional on window elapsed: a rung that succeeded was demoted wrongly,
   restore it.
5. `result.rung == .accessibility && result.verified && !allowlisted` → `learnedAllowlist = true`.
   **`verified` is required** — a lying AX that passes no read-back must never be promoted (X1;
   the ladder already counts unverified AX as failure, so this guard is the pure vocabulary
   refusing to trust a malformed row). An AX win on an allowlisted app leaves the flag untouched.
6. Everything else — other apps' state is not this function's concern; the fold mutates only the
   fields above.

## Out-of-scope boundaries

- **No store.** `InjectionStrategyStore`, `EphemeralStore`, `PersistentStore`, `strategies.json`
  — the `store-seam` aspect. Codable is deliberately deferred too: the Core type is
  Sendable + Equatable per the shared vocabulary; the JSON shape is the adapter's, owned by
  `store-seam`.
- **No order.** `MemoryBackedInjectionStrategyOrder`, the `InjectionAllowlist` conformance,
  `LadderInjector` recording, `ShippingLadder.make` / `AppBootstrap` wiring, and the seeded
  hostile bundle-ID data — the `memory-order` aspect. Its R6 probe scheduling for
  non-allowlisted apps is NOT in this aspect's record fold (see open question O2).
- **No UI.** The Apps-tab surface (rendering, the override control, reset-learned) — the
  `apps-tab` aspect. The override *field and semantics* are M1/M7; the UI that sets them is not.
- **No clock.** `now` is an argument; Core cannot name a clock (the import rule would reject
  `Date()` anyway). The memory-order aspect supplies epoch seconds from a real clock.
- **No persistence, no JSON, no FileManager, no network.** `VoccaCore` imports nothing.
- **No timers.** Re-probe is lazy by construction (M6).
- **Not the ≥95% matrix number, not the seed decision, not the store's tolerant decode.**

## Acceptance criteria (testable)

Test files (all in `Tests/HarnessTests/`, `@testable import VoccaCore`, license header):

**`InjectionStrategyTests`** (M1):
1. `testTheEmptyStrategyIsTheDefault` — `InjectionStrategy()` is all-empty/false.
2. `testStrategiesCompareByValue` — Equatable over differing fields.
3. `testTheStrategyIsSendable` — compile-time: captured in a `@Sendable` closure.
4. `testMemberwiseConstructionForTheSeedShape` — the seed a hostile app starts as (AX demoted,
   window at seed-time + reprobe) is constructible by hand.

**`StrategyMemoryProjectionTests`** (M2/M3/M4):
5. `testTheProjectionStartsWithTheCanonicalOrder` — fresh strategy, allowlisted, any `now`.
6. `testAccessibilityIsExcludedForANonAllowlistedAppUntilLearned` — not allowlisted,
   `learnedAllowlist == false` → AX absent.
7. `testAccessibilityIsIncludedForAnAllowlistedApp`.
8. `testAccessibilityIsIncludedWhenLearned` — not allowlisted, learned → AX present.
9. `testADemotedRungIsDroppedUntilItsWindow` — demoted, window in future → absent.
10. `testADemotedRungIsReIncludedOnceItsWindowElapses` — `now == window` exactly (inclusive
    boundary) and past → present.
11. `testARungWhoseWindowHasNotElapsedStaysDropped`.
12. `testTheProjectionIsNeverEmpty` — all three real rungs demoted with future windows →
    `[.clipboardPaste]`.
13. `testClipboardIsNeverDroppedEvenFromAHandBuiltStrategy` — a hand-built strategy with
    clipboard in `demotedRungs` still projects clipboard (the guarantee holds against invalid
    state, not just valid).
14. `testWidgetFailsafeNeverAppearsInAProjection`.
15. `testADemotedRungWithoutAWindowIsNeverReIncluded`.
16. `testTheSeededHostileShapeExcludesAccessibilityOnTheFirstDictation` — seed shape (M1 test 4)
    at `now == seedTime` → AX absent (R5's mechanism lives in this vocabulary).
17. `testTheSeededHostileShapeIsReProbedAfterTheWindow` — `now == seedTime + 604_800` → AX
    re-included (seeds are data, not decisions — R4 applies to them).
18. `testEligibilityIsFalseForANonDemotedRung`.
19. `testEligibilityIsTrueOnlyAtAndAfterTheWindow` — inclusive boundary.
20. `testEligibilityIsFalseForADemotedRungWithoutAWindow`.
21. `testTheProvisionalReprobeWindowLivesInExactlyOneFile` — the `604_800` literal appears
    exactly once under `Sources/VoccaCore/`, in `StrategyMemory.swift` (the
    `WarmStartTargets` single-source scan precedent).
22. `testTheCanonicalRungOrderLivesInExactlyOnePlace` — the canonical list literal appears
    exactly once, in the same file.

**`StrategyMemoryRecordTests`** (M5/M6):
23. `testAFailedRungBeforeTheWinnerIsDemotedWithAFreshWindow` — AX fails, clipboard wins →
    AX demoted, `reprobeWindows[.accessibility] == now + 604_800`, clipboard intact.
24. `testTheAccessibilityWinnerIsNeverDemoted` / `testTheClipboardWinnerIsNeverDemoted` /
    `testTheKeystrokeWinnerIsNeverDemoted` — one row per real winner.
25. `testRungsAfterTheWinnerAreNotDemoted` — defensive trace (winner mid-list): post-winner
    rungs untouched.
26. `testAWidgetFailsafeWinnerDemotesEveryAttemptedRung` — all three real rungs demoted.
27. `testClipboardIsNeverDemotedEvenWhenAttempted`.
28. `testWidgetFailsafeIsNeverDemotedEvenWhenAttempted`.
29. `testARungZeroResultWritesNothing` — `attempted == []` (secure-input refusal / nil
    bundleID shape) → returned strategy equals the input (identity).
30. `testAWinnerAbsentFromTheTraceWritesNothing` — non-AX winner missing from `attempted` →
    identity (caller-error defense).
31. `testUnverifiedAccessibilitySuccessDoesNotPromote` — X1: `rung == .accessibility`,
    `verified == false` → flag stays false.
32. `testVerifiedAccessibilityOnANonAllowlistedAppPromotes` — flag → true; the next projection
    includes AX (compose with M3).
33. `testVerifiedAccessibilityOnAnAllowlistedAppLeavesTheFlagFalse` — an already-allowlisted app
    has nothing to learn.
34. `testPromotionPreservesTheRestOfTheStrategy` — the fold touches only the fields it owns.
35. `testAReProbedRungThatSucceedsIsRestored` — demoted + window elapsed → re-attempt wins →
    removed from `demotedRungs`, window entry dropped, projection includes it.
36. `testAReProbedRungThatFailsReDemotesWithAFreshWindow` — re-attempt fails → still demoted,
    window moved to `now + 604_800` (one-shot consumed; not eligible again until the fresh
    window).
37. `testAnUnattemptedDemotedRungKeepsItsWindowAndEligibility` — a different winner's fold
    leaves other demotions and their windows untouched.
38. `testTheDemotionWindowIsNowPlusTheProvisionalWindow` — the single source is the one used.
39. `testRecordNeverProducesClipboardOrFailsafeInDemotedRungs` — property over the closed
    winner × trace matrix: the invariant holds for every row the record function can produce.
40. `testThePassedTraceIsTheDemotionInput` — `attempted:` (not `result.attempted`) is what the
    fold demotes on, so a result carrying a truncated trace cannot silently change the demotion.

**`StrategyMemoryOverrideTests`** (M7 — S2's absolute override):
41. `testAnOverrideIsReturnedVerbatimByTheProjection` — override set → projection == the override,
    regardless of demotions/windows/allowlist/now.
42. `testAnOverrideIsNeverReprobedOrDemoted` — an overridden app with elapsed windows and failing
    rungs: the projection still returns the override; the record fold leaves the strategy
    byte-for-byte unchanged (the freeze is here, not in memory-order).
43. `testAnOverrideMustBeNonEmpty` — construction with `[]` refuses (nil or invalid).
44. `testAnOverrideNeverContainsWidgetFailsafe` — construction with `.widgetFailsafe` refuses.
45. `testClipboardMayAppearAnywhereInAnOverride` — a user pin is not a learned invariant.

**Exit condition:** all of the above green in CI, stdlib-only, with the test floor raised to the
measured count (estimate 1210 + ~48; see the plan — the exact number comes from the run).

## Dependencies & sequencing

- First aspect of the unit — nothing in this repository depends on it yet; it depends on
  `InjectionRung`, `InjectionResult`, `TargetContext` (all shipped, C4) and the house pure-
  decision pattern. No `Package.swift` change (SPM globs `Sources/VoccaCore/`).
- The later four aspects consume it: `store-seam` persists `InjectionStrategy`; `memory-order`
  composes M3/M5 with the allowlist and the ladder; `apps-tab` renders the fields; `matrix-smoke`
  exercises it on the founder's machine.
- Nothing here touches the zero-network probe; no probe string changes.

## Open questions / risks

- **O1 — Promotion requires read-back (`verified == true`), which the shared vocabulary's
  one-line summary ("a winning `.accessibility` … sets `learnedAllowlist`") does not state.**
  The PRD's R6 and X1 are explicit that promotion is read-back-verified, and the ladder already
  counts unverified AX as failure, so this is an interpretation, not an invention — but the
  `memory-order` aspect must pass the result through unchanged for the flag to mean what X1
  says it means. Resolved here; flagged because it is the one place this spec sharpens the
  fixed vocabulary.
- **O2 — R6's probe scheduling for non-allowlisted apps is not expressible in the shared
  record fold.** The vocabulary's only "excluded now, re-included after a window" shape is a
  demotion-with-window; M3 already supports the probe's projection side (re-probe beats the
  allowlist gate) and M5 supports its success side (verified AX → promote). The *scheduling*
  (clipboard success on a non-allowlisted app → begin the countdown) is the `memory-order`
  aspect's composition decision, recorded here so that plan resolves it explicitly rather than
  inventing a parallel mechanism.
- **O3 — Demoted-without-window is never re-probed** (M4). The store's tolerant decode
  (`store-seam`, R9/X5) must decide whether a legacy strategy can carry windowless demotions;
  if it can, those apps stay on clipboard forever — an acceptable degradation, but the store
  aspect should know it owns that consequence.
- **O4 — One-shot is record-side.** If any aspect needs to *ask* "is this re-probe still owed?"
  without recording (e.g. an Apps-tab health column), the projection's idempotence means the
  answer is "yes until recorded" — visible in the projection itself, no extra state. Confirmed
  sufficient for the aspects as planned; flagged in case the Apps tab wants a distinct
  vocabulary.
- **O5 — Overrides are Core vocabulary (M7), resolved.** The `apps-tab` aspect sets/renders the
  `overrideRungs` field; the projection and record fold own the frozen semantics, so
  `memory-order` has nothing to special-case. This sharpens the earlier draft's "no vocabulary
  here" claim — the field ships with the value type (M1), not later.