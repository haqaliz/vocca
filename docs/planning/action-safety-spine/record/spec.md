# Aspect spec — `record`

**Boundary:** the documentation sync, the deviations, and the floor ratchet. No production
code.

**Sequencing:** LAST.

---

## In scope

### `ARCHITECTURE.md`

- The module reservation becomes the SHIPPED form (the C12 convention — a reservation is
  annotated, never deleted):

  ```
  VoccaActions/              # P4 — ActionProvider — SHIPPED (action-safety-spine, <date>):
                             #   the audit store; the seam and gate live in VoccaCore/Actions/
  ```

- The seam table row is amended to the **PENDING** form with its reason (deviation D3, the
  `ParakeetEOU` Branch B precedent). It must state plainly that `NullActionProvider` is the
  **shipped default, not a second implementation**, and that guardrail 7 is therefore
  **unmet** in this unit.
- A `> *Annotated (\`action-safety-spine\`, <date>) — …*` blockquote below the table.

### `docs/STATUS.md`

Head entry, prepended above the newest `---`, in house order:

1. Bold headline — the unit, the date, the claim, `; no gate passes.` and the branch
2. `**What shipped, per aspect.**` — `*aspect*` `(sha, sha; 2475 → N):`
3. `**Measured (recorded, never gated):**` — for this unit, the honest content is that
   **nothing was measured**; say so rather than omitting the section
4. `**The honesty block:**` closing with `- Floor **N** (executed N).`

### `CLAUDE.md`

The status paragraph, in the established voice.

### Deviations to record

- **D2** — the zero-network blind spot through spawned children, with the measured spawn-shape
  table. This is the single most important thing this unit hands forward.
- **D3** — the seam ships PENDING; guardrail 7 unmet, with the reason.
- **N1** — persisted per-tool enablement, deferred with its reason.

### The floor

`Scripts/test-with-floor.sh:1783` — `MINIMUM_EXECUTED_TESTS` 2475 → N, in **its own commit**,
with a ledger paragraph naming the aspect, `old -> new; executed N`, and which suites
contributed how many. The count is taken from the script's own parse in the ratchet commit,
never estimated.

## Explicitly NOT in scope

- **No SMOKE rows.** Steps stop at 143 and this unit adds none (PRD §6/C5). Nothing executes,
  so there is no real-machine observation for a founder to make. The record states this
  explicitly rather than reserving numbers nobody can run.
- **No G5 pin re-anchor.** The pin hashes `SessionMachine.swift`, `DictationPipeline.swift`
  and `AppBootstrap.swift`; this unit modifies none of them. The record should state that the
  three digests are unchanged — the positive claim, not silence.
- No `PRODUCT_SPEC.md` change — it says nothing about actions and this unit ships no surface.

## Acceptance criteria

1. The floor script's printed count equals the ratcheted floor (`N == E`).
2. The three G5 digests are unchanged — verified and stated, not assumed.
3. Every claim in the record is either a CI-asserted structural fact or is labelled as
   unmeasured. **No percentage appears anywhere in this unit's record.**
4. The phrase "no gate passes" appears, and the record names this as the **fifth** unit built
   ahead of the uncleared gates.

## Dependencies

All other aspects.
