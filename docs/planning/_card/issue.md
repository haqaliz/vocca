# Card: feat/injection-matrix-record

> Inline brief — no GitHub issue exists. Source: `vocca-next` handoff, 2026-09-01.

## Brief

First recorded run of the injection matrix per `docs/SMOKE_CHECKLIST.md` steps 87-93, in
the landed `p2-gate-measurement` shape: execute the already-written acceptance and record;
code changes only if a first-execution defect surfaces. Prerequisites: install the six
missing matrix apps (Pages, Notion, Ghostty, IntelliJ, Zed, 1Password) or swap same-class
per step 87, then run `Scripts/injection-matrix.sh --verify-bundle-ids` to zero mismatches.

Acceptance:

- Every installed row produces a recorded observation with machine evidence — the first
  run's failure was zero sessions in the run windows (STATUS.md:101-107).
- The tracked table's first row lands at SMOKE_CHECKLIST.md:1877-1879 with the ≥95% FMS
  number recorded or explicitly "not closeable on this machine".
- Zero bundle-id mismatches after `--verify-bundle-ids`; every **guess** row that is now
  installed becomes confirmed or corrected in the harness table and the shipped seed if
  seeded.
- Suite floor 1755 never drops (`Scripts/test-with-floor.sh`).

Caveat: this is a measurement unit, not a build — the founder's machine is the harness;
code changes only if a first-execution defect surfaces (the `p2-gate-measurement` pattern:
every prior first-execution found defects CI cannot catch). The ≥95% FMS bar may not be
closeable on this machine's app set. No number claimed as a gate pass; the P2 gate's third
leg (≥5 external users) is untouched by this unit.