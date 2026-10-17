# Aspect spec — `phrase-store-validation`

**Parent PRD:** `docs/planning/phrase-authoring-ui/prd.md` · **Module:** `VoccaActions`
(+ its tests) · **Prerequisite of:** `phrase-authoring` (its save path), `audit-enablement` (independent).

## Problem slice

`IntentPhraseStore.save` (`Sources/VoccaActions/Config/IntentPhraseStore.swift:123-143`)
enforces only count + encoded-byte caps. The rules that make a phrase file safe — the
`dev.vocca.shell` refusal and the empty / duplicate / length checks — live **only in `load`**
(`:186-208`). The new authoring UI is the first production `save` caller, so the invariants must
hold at the write, not merely be filtered on the next read.

## In-scope requirements

1. `save(_:)` throws (a typed `IntentPhraseStoreError` case) for:
   - a row whose `providerID == ShellProvider.providerID` (`dev.vocca.shell`);
   - a duplicate **normalized** phrase (using `PhraseIntentResolver.normalized`, the same rule the
     resolver matches with — the agreement test
     `IntentPhraseStoreTests.swift:314-337` already asserts parity);
   - an empty (or whitespace-only) phrase;
   - a `phrase` past `maximumPhraseLength` or an `id`/`providerID`/`toolID` past `maximumIDLength`.
2. The refusals are additive: the happy-path encoded bytes are **unchanged** — the exact-bytes pin
   (`IntentPhraseStoreTests.swift:299-308`) and the off-file pin (`:410-416`) stay green.
3. `load` behavior is unchanged (first-wins on duplicates, row-skip on invalid) — `save` is the
   strict gate; `load` stays tolerant.
4. Expose the committed file location so the UI can display it once (a read-only accessor; the
   store already holds `directory`, add the file URL/`fileURL`).
5. No new `FileManager`-naming file; no new network name; the transport lint is untouched.

## Out of scope

- Any change to the on-disk **shape** (`version`, `phrases`, `keywordFallback`) — shape-only,
  byte-stable.
- New caps or clamping (caps stay **refuse never clamp**).
- Validation of a phrase's **target being enabled** — a phrase may name a disabled tool; it is
  inert until the tool is enabled (the resolver's catalog gate). Not this aspect's concern.

## Acceptance criteria (written first — RED)

- `A1` — `save` throws on a `dev.vocca.shell` row; the file is not written (directory empty).
- `A2` — `save` throws on a duplicate normalized phrase (`"Count the audit log"` vs
  `"count the audit log"`); nothing written.
- `A3` — `save` throws on an empty / whitespace phrase; nothing written.
- `A4` — `save` throws on an over-length phrase and on an over-length id; nothing written.
- `A5` — the happy-path bytes for a fixed table are **byte-identical** to the pre-change pin
  (regression guard on the exact-bytes test).
- `A6` — `load` is byte-for-byte behavior-unchanged: absent→empty, tolerant row-skip, first-wins
  duplicates (the existing suite green with no edits that weaken it).
- `A7` — the file-location accessor returns `<directory>/intent-phrases.json`, agreeing with the
  path `save`/`load` use (one derivation, pinned).
- `A8` — an untouched file is never rewritten by `load` (the existing test stays green).

## Dependencies / sequencing

None — this can land first. `phrase-authoring` consumes the new typed errors for loud copy; it
can start in parallel once the error case names are fixed.

## Open questions

- One error case with an associated reason, or one case per rule (shell / duplicate / empty /
  too-long)? Recommend a `case invalidRow(reason)`-style enum for clean UI copy — decide in the
  tech plan.
