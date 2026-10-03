# Aspect spec: agent-record

> Source: `docs/planning/agent-auth-baseline/prd.md` R6 + the unit record · Date
> 2026-10-01.

## Problem slice and user outcome

The unit's closing half: SMOKE 163 (the subscription flow — a logged-in CLI with NO key
on the founder's machine), the unit record, the docs sync, and the N2 record's rewrite
carried into the docs. User outcome: the next unit reads exactly what this slice proved.

## In-scope requirements

- **SMOKE 163** in `docs/SMOKE_CHECKLIST.md` (the established shape): a logged-in CLI
  (e.g. `claude` with the subscription login working in a terminal), an agent row with
  EMPTY environment → arm → card → confirm → the run authenticates with the
  subscription; plus the key-mode control (a row with `ANTHROPIC_API_KEY` still runs);
  plus the D2 baseline line observed on the surface. Ground rules: recorded never
  gated; no rate quoted.
- **The unit record** (`docs/STATUS.md`): per-aspect summary; the decisions (D1
  executor-level every-child, D2 HOME-only, D3 auth hints; the explicit-wins-even-empty
  merge edge; the shell consequence named; the probe's temp-HOME posture); the N2
  rewrite recorded (the old scrub wording retired); the G5 re-anchor record; the floor
  (3023 → new).
- **Docs sync**: `CLAUDE.md` status paragraph; `CAPABILITY_ROADMAP.md` C13 amendment;
  `ARCHITECTURE.md` (the ShellExecutor row's scrub wording if it quotes the old N2
  line — check and correct); `README.md` only if the D2 copy quotes the scrub.

## Out-of-scope

- Any code change (docs-only); any gating of SMOKE 163.

## Acceptance criteria

1. STATUS.md's newest entry is append-only and matches the tree it ships in.
2. Every claim cites a file; deferrals name blockers; the floor is the script's parse.
3. The N2 scrub wording is retired/rewritten wherever the docs carried it.

## Dependencies / sequencing

Last — after `agent-pins`.

## Open questions

- None.