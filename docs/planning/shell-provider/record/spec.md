# Aspect spec: record

> Source: `docs/planning/shell-provider/prd.md` R7, S2 + the unit's record obligations
> (the intent-layer record precedent) · Date 2026-09-22.

## Problem slice and user outcome

The unit's honesty obligations: the record says exactly what shipped and what did not, the
docs stay in sync (CLAUDE.md / STATUS.md / CAPABILITY_ROADMAP.md / ARCHITECTURE.md), the
SMOKE rows are written and runnable, and the floor ratchet lands in the same commit as the
tests.

## In-scope requirements

- Unit record in `docs/STATUS.md` (head entry) + the `CLAUDE.md` paragraph, following the
  slice-record shape: what shipped per aspect, the decisions (destructive-by-default,
  argv-derived sentence, arm-surface-only, self-contained registry, the transport-permit
  widening with its D2 answer), the R8-amplified / N2 / D2 caveats stated, the
  no-gate-passes posture, the floor.
- `docs/technical/CAPABILITY_ROADMAP.md` — the C13 amendment: ShellProvider ships; what
  remains unbuilt (coding-agent handoff, reply rendering, S1 PhraseIntentResolver, time-boxed
  trust, the intent-seam shell leg).
- `docs/technical/ARCHITECTURE.md` — the shell row (provider, engine, config file, the
  transport-permit widening).
- `docs/SMOKE_CHECKLIST.md` — steps written and runnable, recorded never gated:
  (151) configure + enable a read-only command, arm → card shows the argv-derived sentence →
  confirm → command runs → audit reconstructs; (152) the destructive command is refused
  without confirmation by attempting the call; (153) dry-run records but never invokes.
  Each row under rule 1 (verify the state was entered). No rate is ever recorded.
- `Scripts/test-with-floor.sh` — `MINIMUM_EXECUTED_TESTS` raised in the same commit as the
  tests that grew the count (the ratchet rule).
- Commit the planning artifacts (card, understanding, PRD, specs, plans) with the unit.

## Out-of-scope boundaries

- No SMOKE execution (recorded, never gated; the founder runs them). No new SMOKE numbers.
  No gate claims.

## Acceptance criteria

1. The STATUS head entry names every decision in the PRD and the honest claim for each
   inherited caveat (R8/N2, D2).
2. CLAUDE.md's top paragraph is in sync with the tree state at the tip.
3. SMOKE 151-153 exist in the checklist, runnable, each with a rule-1 precondition and a
   pass/failure line, all marked recorded-never-gated.
4. The floor ratchet commit is the suite's growth commit (one commit, not two).

## Dependencies and sequencing

Last aspect — depends on the code aspects' true outcomes. Written from the record of what
actually landed.