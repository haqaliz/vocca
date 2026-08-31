# Understanding: feat/p2-gate-measurement

**Date:** 2026-09-01 · **Phase:** P2 (gate measurement — the path the P0/P1/P2 gates are judged on)
**Source:** `docs/planning/_card/issue.md` (inline brief from `vocca-next`, 2026-09-01)

> Written after a three-agent dig over `docs/SMOKE_CHECKLIST.md`, the env-gated real-run
> harnesses, and the tolerance re-baseline procedure. Every claim carries a file:line.

## 1. What the work is really asking

Execute the **already-written acceptance** — `docs/SMOKE_CHECKLIST.md`'s gate-critical
first-execution steps — on the founder's machine, fix the real defects they find
(test-first), and record the first measured numbers. Nothing in C1–C8 remains to build;
what does not exist is **any measured product number**: the dictation loop has never
delivered text end to end (`SMOKE_CHECKLIST.md:1067-1076`), the injection matrix has
never been run — "the ≥95% first-method-success number does not exist" (`STATUS.md:670-673`)
— and the latency p50/p95 are targets in one table, unmeasured (`STATUS.md:283-286`).
C9 onward is guardrail-blocked until the P2 gate passes (`CAPABILITY_ROADMAP.md:369`;
`ROADMAP.md:180`), and the next installable release waits on steps 62–68 (`STATUS.md:774`).
This unit is therefore the **gate path itself**, not a build capability.

## 2. What the dig established (all verified in the worktree's sources)

- **Steps 62–68 (dictation loop, `SMOKE_CHECKLIST.md:1065-1280`)** — the loop's first
  real execution: 62 byte-compare in Notes + TextEdit; 63 Secure Input (no session
  starts; `.secureInput` copy via `InjectionLadderDecision.swift:84-96`); 64 Esc during
  RECORDING/TRANSCRIBING (`SessionKeyPolicy.swift:50`, `SessionMachine.swift:440-445`);
  65 shortest session (empty-buffer policy, `ParakeetEngine.isBelowSDKMinimum` at
  `ParakeetEngine.swift:145`); 66 model-unavailable (gate refuses before
  `beginCapture`, `AppBootstrap.swift:2908-2925`); 67 toggle triggers + backstops
  (`.toggledOff`, `.audioConfigurationChanged`, 120 s ceiling, `EndReason.swift:31,59,62,84`);
  68 twenty-cycle stability with `recovery/` inspection. Preconditions: Accessibility +
  mic grants, model present and prepared.
- **Steps 87–93 (matrix, `SMOKE_CHECKLIST.md:1765-1879`)** — `Scripts/injection-matrix.sh`
  with `--verify-bundle-ids` (14 confirmed / 0 mismatched / 8 guessed on the authoring
  machine, `:1727`), `--dry-run`, then the tracked baseline; FMS = bytes **and** the log
  naming the expected rung (`:1694-1702`); ≥19 of 20 deliverable rows; tracked table
  sole row "(none yet)" (`:1877-1879`); strategy-memory rows 90 (re-probe after
  `StrategyMemoryTargets.reprobeWindowSeconds` = 604 800 s, `StrategyMemory.swift:26`)
  and 91 (promotion via read-back-verified AX, `MemoryBackedInjectionStrategyOrder.swift:147,247`).
- **Env-gated real runs** — WER (`VOCCA_MODEL_DIR`, visible `XCTSkip`;
  `ParakeetEngineWERTests.swift:52-58`, `WhisperCppEngineWERTests.swift:51-58`; whisper's
  streamed cycle + short-audio rows at step 19, `SMOKE_CHECKLIST.md:352-386`); latency
  bench (`VOCCA_LATENCY_BENCH` + `VOCCA_MODEL_DIR`, four tests in
  `LatencyBenchmarkRealEngineTests.swift`, per-span p50/p95 + warm-start ratio + `.rewarm`
  row + `getpriority` suppression beside every row, `:431-484`); equivalence
  (`EquivalenceRealEngineTests.swift:44-55`, verdict table GO/NO-GO/VOID,
  `EquivalenceRealEngineRunner.swift:228-258`); Parakeet streaming WER
  (`ParakeetStreamingWERTests.swift:36-42`); cleanup eval (`VOCCA_CLEANUP_EVAL`,
  `CleanupEvalHarnessTests.swift:444-473`, F2 corpus = ≥40 utterances ≥5/class,
  `SMOKE_CHECKLIST.md:1365-1399`). Provisioning first:
  `Scripts/provision-asr-fixtures.sh` (prints `VOCCA_MODEL_DIR=<version_dir>`).
- **The re-baseline procedure** — five `tolerances_YYYYMMDD.md` files, each with the
  doctrine "records measured values only; the bound lives in exactly one file"; the
  founder-signed chain is measure → margin → founder-signed row in the tolerances file →
  land in exactly one code file (`tolerances_20260815.md:28-41`), enforced by the
  single-source grep scans (`SwiftSourceScanner.swift:27-29`; a duplicate anywhere fails
  with "a second spelling is a second place a re-baseline must find"). Targets:
  `WarmStartTargets.swift:28` (1.2), `IdleReWarmPolicy.swift:27` (300 s),
  `StrategyMemory.swift:26` (604 800), `ProvisionalCleanupTargets.swift:30,33` (0.80, 10 ms),
  `LatencyBenchmarkTests.swift:926,928` (400/800 ms), `EquivalenceMeasurement.swift:173-181`
  (0.05 × 6). "Recorded, never gated" is the house discipline; a FAIL equivalence verdict
  is a successful unit outcome (`tolerances_20260831.md:22-23`).
- **Headless command:** `Scripts/test-with-floor.sh` (floor 1731, `:1392`), filter syntax
  `swift test --filter <TestClass>`; the suite is a Swift 6 package, not pytest.

## 3. Contradictions surfaced (flag, don't paper over)

- **The `vocca-begin-fast` skill prose is stale on this repo's state**: "no commits",
  "no pyproject.toml", "uv sync" — the tree is a shipped Swift 6 package, 50 commits on
  master, 1731 tests via `Scripts/test-with-floor.sh`. Code and git history win.
- **`SMOKE_CHECKLIST.md` line citations drift from current code** (e.g. `setActiveMode`
  cited at `AppBootstrap.swift:700-719` but is at `:1821`; `beginCapture` gate at
  `:2908-2925`). Cosmetic drift; fix where touched.
- **Step 67's claim that the toggle-mode control is unwired is stale** — the Settings →
  General activation-mode switch shipped with the design pass
  (`STATUS.md:534-542`) and `hotkey-rebinding` (2026-08-30). The checklist preamble
  (`:1084-1088`) predates both.
- **Whisper manifests: "verified digests" with no provenance** (`STATUS.md:820-825`) —
  step 102 (`ManifestDigestVerificationTests.swift:281-333`) will exercise them for the
  first time; a digest failure is a defect this unit fixes.

## 4. Scope placement

- **Phase:** P2 — the latency + injection gate legs (`ROADMAP.md:150-180`), plus the P0
  gate's first-execution clause (7-day daily log begins at step 62) and the P1 gate's F2
  corpus. Not a new capability; C9+ stays guardrail-blocked.
- **Layer:** the whole loop — capture, ASR (both engines), cleanup, injection, widget —
  exercised for real for the first time. Local-only; zero-network invariant untouched;
  nothing leaves the machine.
- **Bounded by discipline:** fixes land test-first with floor 1731 as the regression
  bar; numbers record, never gate; re-baselines follow the founder-signed procedure.

## 5. Ambiguities and open questions carried into the PRD

1. **Step set in scope:** gate-critical minimum = 62–68, 87–93, latency/warm-start real
   run (71-72/77), equivalence (125-126), Parakeet streaming WER (124), whisper step 19,
   manifest verification (102). F2 cleanup eval (73) needs ≥40 founder-recorded
   utterances — include as its own aspect, or defer?
2. **What a "defect fix" may change:** any shipped seam, adapter, or harness — bounded by
   "found on a first-execution run", test-first, no scope creep; a large fix escalates as
   its own card.
3. **Re-baseline margins** are founder decisions at re-baseline time (recorded in the
   smoke step's note).
4. **A failing real run is not a failure of this unit** — it re-baselines (or, for
   equivalence, yields NO-GO which only blocks *claiming* the latency win). No number
   becomes a gate pass without the P2 gate's three legs (latency, matrix, external users).
5. **External users leg** (≥5) is out of scope here — it needs a release, which needs
   steps 62–68 first; the release itself is a follow-on unit.