# Spec — provider-budget

Aspect of `llm-cleanup` (C6) · `docs/planning/llm-cleanup/prd.md`
Requirements: **M1** (owned here).
Depends on: the shipped `CleanupProvider` seam (`VoccaCore`) and the shipped pipeline — both
already in this worktree (C5 merged).

## Problem slice

The pipeline enforces a hardcoded 10 ms cleanup budget (`DictationPipeline.swift:108-113`) and
cancels the provider at expiry. That is correct for rules — but an LLM round-trip is seconds,
and C6's providers declare `requiresNetwork == true`. The architecture settles the doctrine
("if an LLM is opted into, the user has knowingly bought latency", `ARCHITECTURE.md:322`) but
names no mechanism: the budget must become **provider-declared**, enforced by the caller with
the same race, never trusted to the provider (`ARCHITECTURE.md:509, 515`).

## In scope

1. **`CleanupProvider.budget: Duration`** — a protocol requirement with a protocol-extension
   default of 10 ms (`CleanupProvider.swift:45-65`), so existing conformers and test doubles
   compile unchanged. A conformer that needs more declares it.
2. **The pipeline races the provider's declared budget.** `cleanIfWired`
   (`DictationPipeline.swift:316-367`) uses `provider.budget` in place of the private constant;
   `CleanupContext.budget` carries the same value (the provider reads it as information only).
   The private `cleanupBudget` constant is removed or reduced to the default's home.
3. **Rules declares its budget explicitly** (the B10 declared-not-defaulted contract,
   `ShippingCleanup.swift:29-31`): `budget: .milliseconds(10)`.
4. **The budget race is re-tested over declared budgets.** With the injected clock, a provider
   declaring 5 s is given 5 s: the watcher fires at the declared deadline, not at 10 ms; the
   existing B1–B8 pipeline tests pass unchanged (their doubles inherit the 10 ms default).

## Out of scope

- The 5 s value itself, the providers that declare it (`ollama-provider`, `byok-provider`),
  and the chain (`cleanup-chain`).
- Any UI or config surface for the budget (`prd.md` N1 stays nice-to-have).
- Changing the raw-degrade, span-recording, or Esc re-check semantics — untouched, and B1–B8
  prove it.

## Isolation / honesty decisions

- **Enforcement stays with the caller.** The provider declares; the pipeline races with the
  injected clock and `Task.yield()` watcher exactly as today; `CleanupContext.budget` remains
  advisory to the provider.
- **The default is 10 ms, and it is the shipped rules number.** The extension default pins the
  invariant that a conformer which says nothing costs 10 ms — the C5 numbers are not silently
  re-measured by this aspect.

## Acceptance criteria (tests written first)

Failing XCTests in `Tests/HarnessTests/`:

- B1 **Protocol shape.** `CleanupProvider` requires `budget: Duration`; a fresh conformer that
  declares nothing inherits exactly `.milliseconds(10)` (seam test).
- B2 **Rules declares 10 ms explicitly** (shipping provider contract test).
- B3 **A declared 5 s budget is enforced at 5 s.** Pipeline test with a scripted provider
  declaring 5 s and the hand-moved `TableClock`: the race expires at the declared deadline —
  the provider's `clean` returns after the 10 ms mark and its result is used; a provider still
  running at the declared deadline degrades to raw, span recorded.
- B4 **The default is unchanged.** B1–B8 pipeline tests pass unedited over doubles that
  declare nothing.
- B5 **Boundary discipline.** Full suite green under the floor after every commit; Swift 6
  strict concurrency clean; no new files beyond the seam edit and tests (no new module, no
  dependency).

## Dependencies / sequencing

- First aspect in the rough shape (`prd.md:273-276`): the protocol change gates nothing else
  in C6 (conformers simply declare), but it must land first so later aspects plan against it.
- Precedent: `CleanupProvider.swift:61-65` (the `requiresNetwork` default), the B10 contract
  (`ShippingCleanup.swift:29-31`), `TableClock`/`ScriptedCleanupProvider`
  (`DictationPipelineTests.swift:1090-1166`).

## Open questions / risks

- **Should the default live in the extension or the protocol declaration?** The extension
  keeps the "says nothing ⇒ 10 ms" rule near the other defaults; declared-only would force
  every conformer to state a number. Extension default, mirroring `requiresNetwork`.
- **Naming.** `budget` vs `cleanupBudget` vs `declaredBudget` — `budget` reads as a protocol
  requirement beside `requiresNetwork`; the plan pins it.
