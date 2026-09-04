# Spec: real-engine-runs

**Aspect of:** p2-gate-measurement · **PRD ref:** M3, S2, execution order step 4 · **Date:** 2026-09-01

## Problem slice and user outcome

Both engines' real WER is unmeasured (whisper's tolerances are seeded from Parakeet's
table, `STATUS.md:313-315`), the latency p50/p95 are provisional targets, and the
streamed-vs-batch equivalence verdict is open. Outcome: the first measured numbers for
WER (both engines + whisper's streamed cycle), latency/warm-start/re-warm, the
equivalence verdict, and the Parakeet streaming WER row — each re-baselining its
provisional tolerance via the founder-signed procedure, recorded never gated.

## In-scope

- SMOKE step 19: `WhisperCppEngineWERTests` + `ParakeetEngineWERTests` with
  `VOCCA_MODEL_DIR` set (skip lifted); whisper's streamed cycle (partials appear,
  streamed final == batch text-for-text), short-audio rows (0.2 s / 0.5 s / 1 s through
  both `transcribe` and `stream`), and the O(n²) cost row.
- SMOKE steps 71-72: the latency benchmark real run (`VOCCA_LATENCY_BENCH` +
  `VOCCA_MODEL_DIR`) — per-span p50/p95, suppression state beside every row.
- SMOKE step 77: the warm-start ratio row (firstAfterLaunch vs steady-state vs the 1.2
  bound).
- SMOKE step 128: the re-warm row (`.rewarm` samples).
- SMOKE steps 125-126: the equivalence run — verdict GO/NO-GO/VOID per fixture, key-up
  cost row, `ProvisionalEquivalenceTolerances` re-baselined via
  `tolerances_20260831.md`'s procedure.
- SMOKE step 124: `ParakeetStreamingWERTests` — exactly one final, non-empty,
  Parakeet-attributed.
- Fix every defect surfaced (RED→GREEN, floor holds, M5 escalation rule).

## Out-of-scope

- Any tuning of SDK window configs or engine parameters (founder decision, recorded not
  gated, and only via the named single-source file).
- The F2 corpus (aspect `cleanup-eval-f2`).
- Claiming any latency win — a NO-GO verdict blocks the claim, never the feed.

## Acceptance criteria (testable)

- Each run's printed rows recorded in the SMOKE checklist with its step number; visible
  skips lifted (a skip counts as executed only when the row says so).
- Every re-baseline follows measure → margin → founder-signed row →
  land-in-exactly-one-file; the single-source scans stay green.
- Any defect fix: RED→GREEN, floor 1731 holds.

## Dependencies and sequencing

- Requires `provision-and-verify` (model bytes + verification).
- Whisper's streamed cycle needs the whisper model; the O(n²) observation is recorded
  against the shipped constant, never gated.
- The equivalence harness is Parakeet-only by construction (whisper's final equals batch
  by construction — the printed note says why).

## Open questions / risks

- Whisper has never transcribed anything; its real WER may miss the seeded tolerances —
  that re-baselines via `tolerances_20260810.md`, never silently relaxes.
- Short-audio behavior (pad vs refuse) is "reasoning about the C library, not a
  measurement" until this run records it — the 0.2 s/0.5 s/1 s rows are that record.
- The per-session `loadModels` cost on Parakeet's stream path is unmeasured; the
  equivalence run observes and records it.