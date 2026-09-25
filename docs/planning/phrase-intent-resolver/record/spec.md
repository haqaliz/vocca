# Aspect: record

## Problem slice

Keep the narrative docs true to the tree: what shipped, what did not, and what changed in
the default's posture.

## In scope

- `docs/STATUS.md`: a new top entry in the shell-provider shape (per-aspect, measured (nothing),
  honesty block).
- `CLAUDE.md`: the status paragraph for this unit, and the test floor.
- `docs/technical/CAPABILITY_ROADMAP.md`: the C13 amendment. S1 is shipped, and the D3-shaped
  caveat is retired **with the stated limit** (two real classifiers, not composed together).
- `docs/SMOKE_CHECKLIST.md`: rows 154-156 (PRD S1), written and runnable, recorded and never
  gated.
- F-A and F-B (PRD gate findings): the missing audit rows in the Actions tab, and SMOKE 148's
  gesture corrected to the `action-config.json` hand-edit. The correction is recorded as a
  correction, with the original wording kept in the record.
- The N1 finding: `KeywordIntentResolver.jsonEscaped` emits `\u{XX}`, which is invalid JSON.
  Recorded, not fixed.

## Honesty block must state

- No gate passes; this is the twelfth unit built ahead of the uncleared gates.
- **The unwired posture narrowed.** The shipped app can now voice-act, but only after the user
  both writes a phrase file **and** enables the tool. With neither, it is identical to Null
  (`intentResolved=0`).
- R8 is mitigated, not retired. N2 is restated. No resolution rate exists.
- Shell stays arm-surface-only (refused at load).
- G5 was re-anchored once, deliberately; the dictation digests are unchanged.

## Acceptance

The floor ratchet in `Scripts/test-with-floor.sh` equals the executed count (`N == E`).
