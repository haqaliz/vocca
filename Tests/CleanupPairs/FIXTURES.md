# Cleanup Pair Corpus — provenance

The stand-in held-out corpus the `eval-harness` aspect scores (`docs/planning/deterministic-cleanup/eval-harness/spec.md`,
`plan_20260815.md` §2.2-2.3). One pair is a triple of siblings `<name>.raw.txt` (the
as-spoken / ASR-raw side), `<name>.clean.txt` (the golden clean target — what should have been
typed), `<name>.class.txt` (one tag word: `fillers | punctuation | capitalization | numbers-units
| dictionary | token-protection`). The loader (`Tests/HarnessTests/CleanupPairSuite.swift`)
discovers pairs by the `.raw.txt` suffix only, so `dictionary.json` and this file are never
misread as pairs.

## Where the bytes come from

The corpus is **generated, not hand-written**: `Scripts/provision-cleanup-fixtures.sh` reads the
checked-in goldens under `goldens/<class>/*.txt` (one golden per pair — the golden IS the clean
text), applies deterministic ASR-ish error injection, and writes the triples. Regenerate with:

```
Scripts/provision-cleanup-fixtures.sh --goldens Tests/CleanupPairs/goldens --output Tests/CleanupPairs --seed 0x5EED_C0DE
```

Two runs over the same goldens with the same seed produce byte-identical output (asserted by
`CleanupProvisioningScriptTests`). The seed is fixed for the shipped corpus.

## The injection matrix (never assumed — this is it)

Each golden is degraded in a shared way and then class-specifically, so the shipped rules must
recover the golden from the raw side:

| Class | Shared degradation | Class-specific injection | Recovery stage(s) |
|-------|--------------------|--------------------------|-------------------|
| `fillers` | lowercase first letter, drop terminal `.` | prefix one of `um` / `uh` / `hmm` (seeded choice) | `removeFillers`, `segmentAndTerminate`, `capitalizeSentences` |
| `punctuation` | lowercase first letter, drop terminal `.` | — | `segmentAndTerminate`, `capitalizeSentences` |
| `capitalization` | lowercase first letter, drop terminal `.` | — | `capitalizeSentences`, `segmentAndTerminate` |
| `numbers-units` | lowercase first letter, drop terminal `.` | spell every digit into a bounded cardinal word (`3` → `three`, `42` → `forty two`) | `normalizeNumbers`, `capitalizeSentences`, `segmentAndTerminate` |
| `dictionary` | lowercase first letter, drop terminal `.` | — | `applyDictionary` over `dictionary.json`, `capitalizeSentences`, `segmentAndTerminate` |
| `token-protection` | lowercase first letter, drop terminal `.` | — | `capitalizeSentences`, `segmentAndTerminate` — protected tokens (`/ . - _ @`) untouched |

**The planted pair** — `numbers-units-planted-raw-preferred` — is emitted with **no injection at
all**: `raw == clean == "Twelve people came to the meeting."`. The rules normalize `Twelve` to
`12`, so the oracle's verdict through the real engine is `rawPreferred`. This is the can-lose
proof: the scorer must be able to count a loss, or it measures nothing. A golden whose content
duplicates the planted golden is the same utterance, not a second pair — the script skips the
duplicate, keeping the planted name.

## What this corpus is NOT

- **It is not a product-quality claim.** Goldens are chosen so the shipped rules recover them —
  the stand-in corpus measures the **mechanism** (does the run score, tally, and gate correctly),
  exactly the C2/C3 fixture discipline (`docs/planning/local-asr/fixture-suite/spec.md`). The
  preference percentage over stand-ins is a harness sanity number, not a product number.
- **It is not the F2 corpus.** The real held-out set is the founder's recordings — ≥ 40 pairs,
  ≥ 5 per class, natural as-spoken speech — consumed identically by the env-gated runner
  (`VOCCA_CLEANUP_EVAL`; `docs/SMOKE_CHECKLIST.md` step 73). Nothing about the harness changes,
  only the bytes. The ≥ 80% / 10 ms targets are provisional until that run
  (`Tests/HarnessTests/ProvisionalCleanupTargets.swift`; the re-baseline record
  `docs/planning/deterministic-cleanup/eval-harness/tolerances_20260815.md`).

## The dictionary

`dictionary.json` in this directory is the corpus's shared rule set (the `user-dictionary` store
reads `<dir>/dictionary.json`): `kawa` → `Kawa` and `mcp server` → `MCP server`, both
case-insensitive with word boundaries — the PRD Scenario B shapes.
