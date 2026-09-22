# Aspect spec: record

> Source: `docs/planning/intent-layer/prd.md` R11 + the unit's record obligations
> · Branch `feat/intent-layer/aliz` · Date 2026-09-22.

## Problem slice and user outcome

The unit's honesty obligations: the record says exactly what shipped and what did not,
the docs stay in sync (CLAUDE.md / STATUS.md / CAPABILITY_ROADMAP.md / ARCHITECTURE.md),
the SMOKE rows are written and runnable, and the floor ratchet lands in the same commit
as the tests.

## In-scope requirements

- Unit record in `docs/STATUS.md` (head entry) + the `CLAUDE.md` paragraph, following
  the slice-record shape: what shipped per aspect, the decisions (incl. §8: floor pinned,
  time-boxed/decaying trust deferred with blockers; unwired default; seeds code-level),
  the R8 voice-leg caveat (N2 stated), the D3-shaped guardrail-7 claim stated honestly
  (keyword + null default: one real implementation plus a default unless S1 lands), the
  no-gate-passes posture, the floor.
- `docs/technical/CAPABILITY_ROADMAP.md` — the C13 amendment: what remains unbuilt
  (ShellProvider, coding-agent handoff, reply rendering, S1, time-boxed trust).
- `docs/technical/ARCHITECTURE.md` — the intent row (seam, implementations, the §8
  decision in the policy row).
- `docs/SMOKE_CHECKLIST.md` — steps 148-150 written and runnable, recorded never gated:
  (148) enable `audit.clear`, converse "clear the audit log", the card shows the gate's
  sentence verbatim; (149) confirm → the audit row reconstructs; (150) an ambiguous
  utterance is answered with a spoken question, no tool touched — recording utterance
  counts (resolved/asked/missed), never a percentage. Each row under rule 1 (verify the
  state was entered).
- `Scripts/test-with-floor.sh` — `MINIMUM_EXECUTED_TESTS` raised in the same commit as
  the tests that grew the count (the ratchet rule; the count taken from the floor
  script's own parse).
- Commit the planning artifacts (card, understanding, PRD, specs, plans) with the unit.

## Out-of-scope boundaries

- No SMOKE execution (recorded never gated; the founder runs them). No new SMOKE numbers
  (a resolution rate is quoted only after a real run, and never in CI). No gate claims.

## Acceptance criteria

1. The STATUS head entry names every decision in the PRD's "Decisions made in this unit"
   and the honest claim for each inherited caveat (R8/N2, D3-shaped seam claim, D2).
2. CLAUDE.md's top paragraph is in sync with the tree state at the tip.
3. SMOKE 148-150 exist in the checklist, runnable, each with a rule-1 precondition and a
   pass/failure line, all marked recorded-never-gated.
4. The floor ratchet commit is the suite's growth commit (one commit, not two).

## Dependencies and sequencing

Last aspect — depends on the code aspects' true outcomes. Written from the record of
what actually landed.

## Open questions / risks

The spoken-ack copy ("Done."/"Cancelled.") is provisional pending the founder's real run;
the record states the provisional status rather than pinning it as final product copy.