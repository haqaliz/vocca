# Understanding: unmeasured-numbers-sweep

> Phase 2 dig note for `feat/unmeasured-numbers-sweep`. Sources cited inline.

## What this work is

Execute the remaining env-gated real-run smoke steps and record the first measured
numbers through the founder-signed re-baseline procedure. It is the unexecuted M3/M4
remainder of the landed `p2-gate-measurement` unit — the three "still unmeasured"
surfaces named in `CLAUDE.md`: whisper's WER (GGUF absent), F2 cleanup eval (not
run), and the perceived-latency gate number. Measurement + first-execution + defect
fixes; recorded, never gated. No gate passes as a result.

## What the dig found — per surface

### Whisper WER (SMOKE 19, 95-96, 102-104, 21)

- Tests exist and are env-gated exactly like Parakeet's: `WhisperCppEngineWERTests.swift`
  (six fixtures, tolerances 0.10–0.20 + two-hundred-ms 1.0), `RealEngineWERRunner`,
  streamed-final == batch by construction, short-audio rows are "reasoning, not
  measurement" until this run records them (`WhisperCppEngine.swift:240-258`), O(n²)
  partials observation (`:41, 287-292`).
- Provisioning is scripted: `Scripts/provision-asr-fixtures.sh` handles both tiers
  (turbo 1,624,555,275 B; q5_0 574,041,195 B — digests in the two manifests), prints
  the `VOCCA_MODEL_DIR` value, writes the `verified` marker. Whisper has **never
  transcribed anything** (`SMOKE_CHECKLIST.md:2025`).
- Manifest verification (SMOKE 102) exercises the provenance-less whisper digests for
  the first time (`STATUS.md:1043-1049`); `tolerances_20260829.md:59-72` orders step
  102 **before** step 19. SMOKE 104 (re-baseline from step 19) is void unless 102
  passed. SMOKE 21 is the whisper.cpp license sign-off (model-lifecycle M10).
- Re-baseline: `tolerances_20260810.md` — measure → margin → founder-signed → land in
  **exactly two files** (both WER test classes), never silently relaxed.

### F2 cleanup eval (SMOKE 73) — three real findings, two are defects

1. **The ballot is never printed.** `printBallot` (`CleanupEvalHarnessTests.swift:835-855`)
   has no caller; the env-gated test skips when `answers.tsv` is missing without
   printing anything (`:459-463`); nothing generates the ballot seed that `answers.tsv`'s
   first line must match. The "first invocation prints the seeded ballot" flow is
   **unimplemented end-to-end** — the run would surface this on day one.
2. **Corpus discovery requires `.raw.txt`, but the documented convention omits it.**
   `CleanupPairSuite.swift:91-95` discovers pairs solely by `.raw.txt` suffix; the
   specs/plan/SMOKE list only `.wav/.clean.txt/.class.txt` + `dictionary.json`
   (`cleanup-eval-f2/spec.md:17`, `SMOKE_CHECKLIST.md:1380-1383`). A wav-only corpus
   loads 0 pairs. The raw-side convention needs a founder decision: engine-transcript-
   written-to-`.raw.txt`, or hand-typed fallback documented as required.
3. `VOCCA_CLEANUP_EVAL=1` in the old plan's commands is wrong — the env value **is**
   the pairs-dir path (`CleanupEvalHarnessTests.swift:450`); SMOKE's `<pairs-dir>`
   spelling is correct. Plan-doc bug, not code.
- Verdict machinery is complete: per-pair rows, `preference=NN.N%`, per-class tallies,
  `verdict vs provisional 0.8: RECORDED, not gated` (`:882-906`),
  `ProvisionalCleanupTargets.preferenceMinimum = 0.80` pinned by a single-source scan;
  re-baseline per `tolerances_20260815.md` (tie/noPreference excluded from the
  denominator).
- Corpus is the long pole: ≥40 utterances, ≥5 per class, six classes, on-disk
  `~/Vocca/f2-pairs/` only, never in the repo.

### Latency record (SMOKE 71-72) — ran, but step 72's deliverable is incomplete

- Steps 71-72 **executed fully** (both variants) in p2-gate-measurement: per-span rows
  recorded (`STATUS.md:208-211`: captureClose 3/3, asr p50 79-102 / p95 354, inject
  7/7, suppression 0 throughout; warm-start 0.348×; re-warm 82-85 ms).
- What is **missing**: the composite perceived-latency number (key-up → text-on-screen,
  the P2 gate's p50 ≤ 400 / p95 ≤ 800 shape, `ROADMAP.md:171`) was never computed or
  recorded — only per-span rows. No founder-signed re-baseline, no margin
  (`tolerances_20260825.md:25-32` holds the numbers as prose); the 60 s fixture
  substitution caveat and the machine/model statement are not beside the numbers
  (`SMOKE_CHECKLIST.md:1350-1358` requires them); the **cleanup span was never
  measured** — the real runner emits only captureClose/asr/inject, cleanup
  `notPresent` for the nil-cleanup pipeline, so step 71's "cleanup is one of the four"
  is unmet.
- Existing rows must not be re-claimed as new (`_card/issue.md:64-66`): the sweep
  records what is missing, not what is done.

## Cross-cutting

- **Re-baseline discipline:** measure → margin (founder decision) → founder-signed row
  in the matching `tolerances_*.md` → land in exactly one/two named files; single-source
  scans stay green; nothing gates.
- **Defect fixes are test-first:** RED→GREEN, suite floor 1755 never drops; a fix
  needing a PRD-level decision or seam-contract change escalates as its own card.
- **Stale docs to fix along the way:** `real-engine-runs/spec.md:8` cites a stale
  STATUS range (now the AppQuitPolicy entry); `cleanup-eval-f2/plan_20260901.md:8`
  says floor 1731 (now 1755) and its commands use `VOCCA_CLEANUP_EVAL=1`;
  `tolerances_20260810.md` prose status predates its own measured table.

## Open questions for the PRD

1. **F2 raw-side convention**: keep `.raw.txt` as the discovery requirement and
   document it (raw side = engine transcript written by the provisioning pass, or
   hand-typed), or extend discovery to wav-first? The first is a doc fix; the second
   is a test-first code slice.
2. **Latency composite**: extend the real benchmark runner to emit a composite
   (total) span row (test-first code slice), or compute the composite from already-
   recorded per-span numbers by hand? The runner change keeps the number honest per
   cycle; the hand computation reuses recorded rows.
3. **Whisper tiers**: provision both (turbo + q5_0; ~2.2 GB total, both manifests
   verified by SMOKE 102) or turbo only?
4. **Margins** at each re-baseline are the founder's decision at the time, recorded in
   the step's note (no need to pre-decide).

## Out of scope (honestly)

The injection matrix run (C8's other half — `injection-matrix-completion`, sequenced
after this unit per the founder's PH-publish plan), notarization (blocked — not
purchased), the P2 gate's third leg (≥5 external users), the P0 7-day daily-use log,
and any gate claim. No number lands as a pass; everything records. Cloud/telemetry
stay out — the F2 corpus and all recordings remain on the machine.

## Phase placement

P2 (latency + injection feel) — the measurement half of the two make-or-break battles.
The whisper WER leg serves C3's "selectable but unmeasured" honesty (`CAPABILITY_ROADMAP.md:98-106`);
the F2 leg produces the P1 gate's number (`ROADMAP.md:137`, recorded not gated); the
latency leg completes step 72's deliverable. Guardrail-fit: macOS-only, local-only, no
cloud, no crippling of the local core; dictation-first — every number serves the
dictation loop, not the assistant layer.