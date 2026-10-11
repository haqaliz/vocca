# unit-record — aspect spec

Aspect 4 of `turn-history` (last). Source: `../prd.md` (approved 2026-10-11), aspects 1-3
shipped. No production code: the floor, the docs sync, the SMOKE row, and the honesty block.

## Problem slice / outcome

The unit's bookkeeping, done the way every unit before it did it: the test floor raised to the
real executed count, the docs that name the shipped state updated (keeping dated history), one
new SMOKE row written/runnable/never-gated, and a STATUS.md entry with an honesty block that
states what is unmeasured.

## In scope

- `Scripts/test-with-floor.sh`: `MINIMUM_EXECUTED_TESTS` raised 3161 → the real count from the
  full gate run, arithmetic listed in the comment.
- Docs sync: `ARCHITECTURE.md` (the storage list gains `conversation.json` with its
  bounded/purged semantics; the module map/list gains `VoccaConversation`; the seam table's
  persistence row), `PRODUCT_SPEC.md` (the Settings tab list gains Conversation; §12 gains the
  reconciling sentence — the bounded recent-turns window is not the banned transcript browser),
  `CLAUDE.md` (one compact paragraph, not a balloon), `CAPABILITY_ROADMAP.md` (the four
  "separate, unclaimed P3 item" pointers resolve to this unit, keeping the dated history),
  `STATUS.md` (the unit entry).
- `SMOKE_CHECKLIST.md` row **167** (append after 166): a spoken exchange appears in the
  Conversation tab; a barge-in'd turn shows the interrupted marker; Forget from the tab and from
  the menu row clears both surfaces and the file; history survives a relaunch. Written, runnable,
  recorded — never gated.
- The unit record's contents: the decisions (eviction divergence from refuse-never-clamp;
  truncation as the text bound; the menu one-action vs Settings-confirmed split; the F1 fix) and
  the limits (no rate exists; the real surface is unverified — SMOKE only; no search/timestamps
  by design; the tests are the only evidence).

## Out of scope

Any code change; the G5 re-anchor (aspect 3); the PR/merge ceremony.

## Acceptance criteria

R1 **Floor**: `MINIMUM_EXECUTED_TESTS` equals the executed count of the final full gate run;
the script's comment lists the arithmetic; `git diff` touches no production file in this aspect.
R2 **Docs**: every claim added is grounded (file:line where the repo's style does); the four
CAPABILITY_ROADMAP pointers carry `[resolved <date> by turn-history]` with the dated text kept;
`PRODUCT_SPEC.md` §12 still contains the no-browser line and the new sentence reconciles
ROADMAP.md:205 with it; CLAUDE.md's paragraph names the module, the seam, the caps, the F1 fix,
the no-gate honesty, and the floor.
R3 **SMOKE 167**: exists, follows the row structure (`*Gesture:*` / `*Pass:*` / `*Void…*` /
`*Failure:*`), names the shipped copy verbatim, records counts never rates.
R4 **Record**: STATUS.md's entry states the twenty-second-ahead-of-gates posture, that no gate
passes, that no rate exists, that the F1 finding was fixed and pinned, and the unit's limits.
R5 **Final**: clean build (`rm -rf .build/xcode/Build/Products/Debug/Vocca.app` first, the house
convention), then `./Scripts/test-with-floor.sh` — executed == floor, 0 failures.

## Risks

Documentation drift is the failure mode here: the docs must describe the tree this unit ships in
(one module more, one file more, one tab more, one seam more) and keep the dated history.
