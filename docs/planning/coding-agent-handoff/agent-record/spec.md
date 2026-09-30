# Aspect spec: agent-record

> Source: `docs/planning/coding-agent-handoff/prd.md` R9 + the unit record · Date
> 2026-09-30.

## Problem slice and user outcome

The unit's closing half: SMOKE rows the founder can actually run (recorded, never gated),
the honest record of what shipped and what did not (the interactive session, the
`{{utterance}}` seeding, the mayEgress question's resolution as "copy is enough"), and the
docs sync the repo's front-door rule demands (`CLAUDE.md`, `CAPABILITY_ROADMAP.md` C13
amendment, `STATUS.md`, `SMOKE_CHECKLIST.md`, and `README.md`'s D2 line if it names the
spawn promise). User outcome: the next unit and a skeptical reviewer can read exactly what
this slice did and did not prove, without re-reading the code.

## In-scope requirements

- **SMOKE rows (~157–159)** in `docs/SMOKE_CHECKLIST.md`, the established shape
  (numbered title → *Gesture* → *Verify the state was entered* → *Pass* → *Void — not
  fail — if* → *Failure*):
  - 157 — the real-binary handoff: configure a real agent row (the founder's chosen CLI),
    arm → card shows the argv-derived sentence verbatim → confirm → the agent runs in the
    project directory → the audit entry reconstructs the action.
  - 158 — the voice leg: a phrase row naming `dev.vocca.agent` + the enabled tool →
    spoken round trip → the card → confirm → the run.
  - 159 — the D2 copy and the timeout path: the Agents-tab section reads the honest copy;
    a hung agent row dies at its timeout with the loud failure, no orphan
    (the `ESCH` check on the founder's machine).
  - The ground rule: no agent-success rate may be quoted until a real run exists.
- **The unit record** (`docs/STATUS.md`, newest entry): what shipped per aspect, the
  decisions (Q1–Q6 + the planning refinements: the `environment` field, the arguments-
  refusal pin, the gap-3 stale-row reconcile, the mayEgress "copy is enough" resolution,
  the **no third transport entry** outcome — the lint stays at exactly two files), the
  deferrals with blockers (interactive session; `{{utterance}}`; parameters), the G5
  re-anchor record, the test floor.
- **Docs sync**: the `CLAUDE.md` status paragraph (the unit's one-paragraph entry), the
  `CAPABILITY_ROADMAP.md` C13 amendment (remaining-machinery list shrinks to
  reply-text rendering + the composite resolver + audit-tools arm + the intent-seam shell
  leg + §8 trust deferrals), `ARCHITECTURE.md` only if a seam fact changed (expected: the
  ActionProvider implementation list gains a row — the `phrase-resolver` precedent's
  "the seam's implementation list" REFACTOR).
- **Commit discipline**: `record:` commit, docs-only, after the probe GREEN.

## Out-of-scope

- Any code change (docs-only aspect), any gating of the SMOKE rows.

## Acceptance criteria

1. `docs/STATUS.md`'s newest entry is append-only and matches the tree it ships in (the
   repo rule: "describe the state of the tree this file ships in").
2. Every shipped claim in the record is a file the tree contains; every deferral names its
   blocker.
3. `CLAUDE.md` and `CAPABILITY_ROADMAP.md` no longer name coding-agent handoff as
   unbuilt; the remaining-machinery lists match the code.
4. SMOKE 157–159 follow the recorded-never-gated shape with the ground rule.

## Dependencies / sequencing

Last — after `agent-probe` GREEN.

## Open questions

- Which agent binary the founder arms first is the SMOKE rows' precondition, not a code
  question; the rows must say what configuring it entails (absolute path, env key).