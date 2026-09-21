# Spec: record (unit record, SMOKE rows, floor)

> Aspect of `action-surface-wiring` (C13 slice 5). Source: PRD R10, the card caveat, the
> repo's record conventions (`record/spec.md` precedent from the spine unit).

## Problem slice

Every C13 record ends with "nothing is wired" and "steps stop at 143". This aspect closes
both sentences honestly: the record that the surface exists, the SMOKE rows that observe
it, and the floor ratchet.

## In scope

- **Unit record** in `docs/STATUS.md` (head entry): what shipped per aspect, the honesty
  block (no gate passes; ninth unit ahead of the gates; **N2's limit stated** — an
  approval asserts a human said yes and cannot verify it, per the card caveat; R8
  mitigated, not retired; the D2 copy; the `.none` policy floor decision recorded as a
  decision; the card is executed by nothing in CI), the floor, the G5 re-anchor record.
- **`CLAUDE.md` preamble**: the `action-surface-wiring` status entry (the STATUS-first
  convention — the preamble carries the current state; STATUS.md carries the full record).
- **`CAPABILITY_ROADMAP.md`**: amend the C13 entry — slice 5 shipped; the "nothing is
  wired" sentence retires; remaining C13 machinery named (intent layer, ShellProvider,
  coding-agent handoff, reply rendering).
- **`SMOKE_CHECKLIST.md`**: steps 144-147 (recorded, never gated):
  - 144: Actions tab shows the D2 copy; no default server exists.
  - 145: arm → confirm → invoke → audit row reconstructs through the real surface
    (the founder's real-machine observation of the card).
  - 146: enablement survives relaunch.
  - 147: the widget card shows the gate's sentence verbatim before invoke.
- **`ARCHITECTURE.md`**: the actions policy row — the `.none` floor decision, the executor,
  the config store file name.
- **Floor ratchet**: `Scripts/test-with-floor.sh` `MINIMUM_EXECUTED_TESTS` raised to the
  executed count in the same commit as the final test additions (convention:
  the raise commits with the tests that grew the suite; the record aspect executes the
  final ratchet and verifies `N == E`).
- **README.md** if the promise sentence changes (it should not: "zero network calls and
  spawns no child process" still holds — verify and leave).

## Out of scope

- New capability prose beyond the amendment notes; anything not in the tree.

## Acceptance (tests written first — the "tests" here are the doc pins)

1. `CLAUDE.md`, `STATUS.md`, `CAPABILITY_ROADMAP.md`, `SMOKE_CHECKLIST.md`,
   `ARCHITECTURE.md` all describe the same state: the surface exists, nothing is gated,
   N2's limit is stated, the D2 copy is on the surface.
2. The floor executes at the ratcheted number (`N == E` via `test-with-floor.sh`).
3. The G5 pin is green on the final tree (computed, not edited-to-match).
4. The dictation promise sentence in README is unchanged (no claim widened).

## Dependencies & sequencing

- Last aspect: everything else must be merged into the branch first.