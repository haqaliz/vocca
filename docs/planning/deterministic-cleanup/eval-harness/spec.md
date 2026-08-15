# Spec — eval-harness

Aspect of `deterministic-cleanup` (C5) · `docs/planning/deterministic-cleanup/prd.md`
Depends on `rules-engine` (+ `user-dictionary` for the real-corpus rows that carry a
dictionary) — the last aspect in the unit, per the PRD's rough shape (prd.md:234-236).

## Problem slice

The P1 gate is judged on a number no one can yet produce: **cleaned text beats raw in
≥80% of blind pairwise comparisons on the held-out set** (`prd.md:36`; the gate at
`ROADMAP.md:137`). Nothing exists that can produce that number — no corpus, no comparator,
no latency measurement, and no owner for F2, the founder-recording task that replaces the
stand-ins (`local-asr/prd.md:369-372` flags F2 as ownerless; this aspect claims it). The
binding constraint is the house honesty rule (`latency-instrumentation/prd.md:35-38`): CI
proves the *mechanism* over stand-in pairs and never claims a product number; the real
number comes from an env-gated run on the founder's machine. So this aspect ships the
mechanism end to end — corpus, deterministic comparator, headless CI run, env-gated real
run, honest latency measurement, the provisional ≥80% target in exactly one named place —
and the F2 smoke task that will eventually re-baseline it. It scores `RulesCleanup`
(`ARCHITECTURE.md:511`); it does not build it.

## In scope

1. **Held-out raw→clean pair corpus.** Text-only pairs (no audio — cleanup consumes text)
   under `Tests/CleanupPairs/`, one pair = `<name>.raw.txt` + `<name>.clean.txt` beside
   each other, plus a provenance doc in the `FIXTURES.md` pattern (`Tests/Fixtures/FIXTURES.md:7-22`:
   a table of sources, the stand-in disclaimer) and a per-pair class tag
   (`fillers | punctuation | capitalization | numbers-units | dictionary | token-protection`)
   so runs can print a per-class breakdown. The loader mirrors `ASRFixtureSuite.loadFixtures`
   (`ASRFixtureSuite.swift:50-81`): discovers pairs, throws `missingGolden` on a pair whose
   clean side is absent (`:69-72`) and `noPairsFound` on an empty directory (`:64-66`) — a
   harness that cannot measure must never read green. Pairs are checked in, generated once
   by a provisioning script (the `Scripts/provision-asr-fixtures.sh` precedent) from goldens
   with deterministic ASR-ish error injection (filler insertion, case collapse, missing
   terminal punctuation, unnormalized numbers); provenance and generation are documented in
   the doc file, never assumed. **PRD goals 1 and 2's instrument** (S3, `prd.md:134-138`).
2. **Deterministic blind pairwise-preference comparator.** A pure function in the WER-scorer
   style (`WERTests.swift:17-19` — "the measurement the P0 gate is judged on, pinned before
   any engine runs against it"): verdicts `cleanedPreferred | rawPreferred | tie |
   noPreference` over a judge's blind answer (labels revealed only after the verdict — the
   comparator is what makes "blind" mechanical rather than a promise), the per-pair outcome
   mapping, and the aggregate: preference percentage = `cleanedPreferred ÷ (pairs with a
   preference)`, with a loud refusal to divide by zero on an all-tie run. The CI judge is a
   deterministic oracle — prefer the side that equals the pair's golden clean target; both
   or neither ⇒ `noPreference` — so the mechanism is table-tested, not vibes (the roadmap's
   own design, `ROADMAP.md:132`). **Goal 1.**
3. **CI-runnable stand-in eval.** A headless suite drives the real `RulesCleanup` over the
   whole corpus with the oracle judge, prints per-class tallies and the preference
   percentage, and asserts the mechanism: a planted raw-preferred pair is *counted* as
   `rawPreferred` — the scorer must be able to lose, or it measures nothing. Zero network by
   construction: the eval runner touches no transport, and the H8 lint family
   (`ModelDownloaderSeamTests`) gains the eval files to the no-`URLSession` rule. CI numbers
   here are mechanism numbers only. **Goal 1's mechanism; S3.**
4. **Env-gated real scoring run.** A runner gated exactly like the WER tests — visible
   `XCTSkip` naming the env var without it (`ParakeetEngineWERTests.swift:52-58`), a loud
   failure naming the missing artifacts when the var is set but the F2 pairs are absent (the
   `RealEngineWERRunner` discipline: `missingTolerance`/`noFixturesFound`-style named errors,
   `RealEngineWERRunner.swift:91, 115`). With the var set, it loads the F2 pairs, runs
   `RulesCleanup` (and the real ASR engine over the F2 recordings where the pair contract
   carries raw transcripts — `VOCCA_MODEL_DIR` provisioning via
   `Scripts/provision-asr-fixtures.sh`), **prints** the preference percentage and the
   per-class breakdown, and **records rather than gates** until the founder re-baselines —
   the C3 tolerances mechanism (`tolerances_20260810.md:26-45`). The judge is the founder,
   blind: pairs presented in seeded-random order with the seed printed beside the verdicts.
   **Goal 1's real-number half.**
5. **Rules-path latency measurement.** Headless over the corpus with the injected clock:
   p50 across all pairs, asserted `< 10 ms` against the named provisional table — the
   budget at `ARCHITECTURE.md:310` ("cleanup gets 10 ms and not 200"). The load-bearing
   test mirrors the benchmark-gate's mechanism proof: a **seeded slow rule** (an expensive
   replacement over a pathological pair) must fail the assertion — a gate that cannot fail
   proves nothing (`benchmark-gate/spec.md:27-29`). **Goal 2.**
6. **The ≥80% provisional target in exactly one named table.** `ProvisionalCleanupTargets`
   (preference minimum 0.80, rules-path p50 10 ms) in one file, marked provisional, with the
   F2 re-baseline procedure recorded in this unit's tolerance record — the
   `tolerances_20260810.md:47-52` "Where the final numbers land: F2" mechanism, asserted
   single-sourced in the B6 pattern of the latency gate (`LatencyBenchmarkTests.swift:193-217`).
   **Goal 1's P1-gate instrument.**
7. **F2 recording task in the smoke checklist.** A new numbered step (71, after the
   benchmark pair 69-70, in the 62-68 *Gesture:*/*Pass:* format,
   `SMOKE_CHECKLIST.md:1011-1149`) naming the F2 contract — recordings, golden
   transcription, pair location/format, the env-gated scoring run and what "pass" means —
   claiming the ownerless F2 (`local-asr/prd.md:369-372`). Until the founder runs it, ≥80%
   stays provisional and CI runs stand-ins. **S3's F2 clause; goal 1's re-baseline path.**

## Out of scope

- **Product-quality claims.** CI never produces the ≥80% number or a product latency
  number; the founder's env-gated run is their only source (`latency-instrumentation/prd.md:35-38`).
- **The rules engine itself** (`rules-engine` aspect), the user dictionary
  (`user-dictionary` aspect), pipeline wiring and the cleanup span (`pipeline-wiring`):
  the harness only *scores* `RulesCleanup`.
- **Persistence or UI for results** — the ledger's local recording and any settings surface
  belong to other aspects; the harness prints and asserts, nothing more.
- **Anything network** — no telemetry, no cloud, no transport in the eval path; the F2
  audio/pairs never leave the machine (R11, `prd.md:189-190`).
- **CI wiring beyond the existing suite** — the harness runs through the current
  `test-with-floor.sh` headless job; no new job, no new dependency.
- **Chasing the number** — nothing in this aspect tunes rules to pass the gate (the
  P2-gate external confirmation is the bias absorber, `prd.md:201-203`).

## Isolation / honesty decisions

- **CI proves the mechanism, never a product number** (`latency-instrumentation/prd.md:35-38`):
  the stand-in run's oracle judge and checked-in generated pairs exercise the comparator,
  the corpus loader, the latency gate and the single-source discipline. The percentage CI
  prints is about the mechanism — it must be able to print a losing number (deliverable 3's
  planted raw-preferred pair).
- **The ≥80% figure is the P1-gate instrument** (`prd.md:36`; `ROADMAP.md:137`), marked
  provisional, living in exactly one named table that a test proves is consumed — the
  re-baseline moves it in exactly that one place, founder-signed, per
  `tolerances_20260810.md:47-52`. External bias in a founder-judged held-out set is
  absorbed by the P2 gate, not by fudging this one (`prd.md:201-203`).
- **The real numbers come from the env-gated founder run** (the `VOCCA_MODEL_DIR` WER
  precedent, `ParakeetEngineWERTests.swift:52-58`), with the pair order seeded-random and
  the seed printed — blindness is mechanical, not assumed.
- **Latency is measured with the honest shape:** pure stdlib function, injected clock, p50
  over the corpus, the seeded-slow rule proving the gate can fail; the 10 ms provisional
  figure is re-baselined by the founder's run like every other number in the unit's table.
- **Zero network, structurally** — the eval files join the no-`URLSession` lint family; the
  corpus is text in the repo; nothing is fetched, nothing is uploaded.

## Acceptance criteria (tests written first)

New suites: `Tests/HarnessTests/CleanupPairwiseScorerTests.swift` (the comparator's decision
table) and `Tests/HarnessTests/CleanupEvalHarnessTests.swift` (corpus, CI stand-in run,
env-gated real run, latency gate, single-source table). The tests fail before the
implementation, per the capability rule (`CAPABILITY_ROADMAP.md:13`).

- B1 **Comparator decision table** (`CleanupPairwiseScorerTests.swift`): identical inputs
  yield identical outcomes (determinism, the `WERTests` purity shape); rows cover all four
  verdicts — `cleanedPreferred`, `rawPreferred`, `tie`, `noPreference` — with the label
  order (raw-first vs cleaned-first presentation) provably not influencing the outcome;
  percentage arithmetic is exact (3 of 4 preferred ⇒ 0.75); an all-tie or all-no-preference
  run throws a named `noPreferenceSample` error rather than dividing by zero; the empty
  corpus rule (the WER empty-reference precedent, `WERTests.swift:55-58`).
- B2 **Corpus loads and fails loudly** (`CleanupEvalHarnessTests.swift`): `loadPairs` finds
  every pair under `Tests/CleanupPairs/`; a pair missing its `.clean.txt` throws
  `missingCleanTarget` naming the pair (the `missingGolden` shape, `ASRFixtureSuite.swift:69-72`);
  an empty directory throws `noPairsFound` (`:64-66`); a vacuity guard fails the suite if the
  corpus holds fewer pairs than the named minimum — the harness cannot measure nothing
  (the `noFixturesFound` discipline, `RealEngineWERRunner`).
- B3 **CI stand-in run, headless and zero-network**: the suite runs the real `RulesCleanup`
  over the full corpus with the oracle judge, returns per-class tallies and the preference
  percentage; a planted raw-preferred pair is counted `rawPreferred` (the scorer can lose);
  no eval file names `URLSession` (the H8 lint family row); no `connect(2)` is made (the
  inherited interposer posture).
- B4 **Env-gated real run**: without the env var it skips visibly, the `XCTSkip` naming the
  var (the WER pattern, `ParakeetEngineWERTests.swift:52-58`); with it but no F2 pairs
  directory, it fails loudly with provisioning instructions (the WER-with-model-missing
  shape, `LatencyBenchmarkRealEngineTests`); with both, it prints the preference percentage,
  the per-class breakdown, and the pair-order seed — and never throws on a result below the
  provisional target (records, never gates; `LatencyBenchmarkRealEngineTests.swift:40-41`).
- B5 **Latency gate**: headless p50 over the corpus asserts `< 10 ms` from the named
  provisional table (the `ARCHITECTURE.md:310` budget); a seeded slow rule fails the
  assertion, proving the gate can fail; the CI assertion consumes the table, so deleting
  the table breaks the gate (the `LatencyBenchmarkTests.swift:198-217` consumption shape).
- B6 **Single-source ≥80%**: `ProvisionalCleanupTargets.preferenceMinimum == 0.80` and
  `.rulesPathP50 == 10 ms`, both asserted to exist and to be consumed by the real-run
  printing path and the latency gate; a scan test (the `SwiftSourceScanner` family, with its
  vacuity guard) fails if the `0.80` figure appears anywhere outside the named file — the
  WER single-place discipline (`tolerances_20260810.md:3-6`) applied to the cleanup target.
- B7 **Checklist**: `docs/SMOKE_CHECKLIST.md` gains the F2 recording + first real scoring
  run step (numbered 71 in sequence, *Gesture:*/*Pass:* format), naming the env var, the
  pair contract, and that "pass" for this run is the printed record, not a verdict.
- B8 **Floor/boundary**: full floor green after every commit
  (`Scripts/test-with-floor.sh`); no new dependencies; no lint edits;
  `expectedRealtimeDeclarations` unchanged.

## Dependencies / sequencing

- **`rules-engine`** — the `RulesCleanup` function the harness scores. Not merged yet:
  `Sources/VoccaText/` holds only `Placeholder.swift`, so this aspect's B3 cannot pass until
  the engine lands. Last aspect in the unit, per `prd.md:234-236`.
- **`user-dictionary`** — real-corpus rows that exercise dictionary rules (`dictionary.json`
  rows) need `ReplacementRule` application; the corpus's `dictionary`-tagged pairs are
  written but only meaningful once the engine applies them.
- **Precedents reused, not rewritten**: the loader shape (`ASRFixtureSuite.swift:50-98`),
  the scorer style (`WERTests.swift`), the env gate (`ParakeetEngineWERTests.swift:52-58`),
  the tolerance-record mechanism (`tolerances_20260810.md`), the single-source assertion
  (`LatencyBenchmarkTests.swift:193-217`), the H8 lint family (`ModelDownloaderSeamTests`),
  and the provisioning-script pattern (`Scripts/provision-asr-fixtures.sh`).
- **`pipeline-wiring`** flips the `SMOKE_CHECKLIST.md:1189-1191` "cleanup is never recorded"
  wording and the verbatim steps 62-68 to cleaned-vs-raw; this aspect's step 71 slots after
  step 70 without touching those.

## Open questions / risks

- **Stand-in pair provenance**: generated-by-script (deterministic error injection from
  goldens, checked in, provenance documented) vs hand-written pairs. The script wins on
  reproducibility and class coverage; the risk is the injected errors being unrealistically
  clean — mitigated by the F2 replacement, exactly the `FIXTURES.md:16-22` stand-in
  disclaimer's argument.
- **How many pairs for statistical meaning**: 80% over five pairs is noise; the vacuity
  guard (B2) sets a floor, but the founder's real corpus size is a human decision this
  aspect cannot make — the smoke step names a target count and the guard prevents a
  meaningless green.
- **Ties in the denominator**: `tie` and `noPreference` rows — excluded from the
  denominator (percentage over pairs *with* a preference), counted as half, or counted as
  raw? The comparator's table (B1) pins one choice now; a blind judge's tie rate is
  unknown until F2 and the choice is re-openable at re-baseline.
- **F2 format/location contract**: what the founder records (utterances per class, count),
  whether the pair contract carries the recording + a real-engine transcript or a
  hand-transcribed raw text, where the artifacts live, and who transcribes the goldens.
  The smoke step fixes this contract; the harness's loader must not block on it.
- **Blindness is mechanical only if presentation order is randomized** — a checked-in
  fixed order would let the founder pattern-match. The seed-printed shuffle (deliverable 4)
  is the mitigation; the risk is a judge who recognizes their own utterances regardless.
- **Latency CI number honesty**: a pure stdlib function measured on a hosted runner is
  close to real, but it is still a mechanism number; the founder's run re-baselines the
  10 ms provisional figure like every other number in the unit's one table.
