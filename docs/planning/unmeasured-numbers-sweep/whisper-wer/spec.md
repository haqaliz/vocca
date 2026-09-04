# Spec — whisper-wer (aspect 1 of unmeasured-numbers-sweep)

**Aspect of:** unmeasured-numbers-sweep · **PRD ref:** M1, M2, M3 · **Date:** 2026-09-04

## Problem slice and user outcome

Whisper is selectable in settings and honestly labelled unmeasured (`CAPABILITY_ROADMAP.md:98-106`); no whisper model has ever transcribed anything (`SMOKE_CHECKLIST.md:2025`). Outcome: both GGUF tiers provisioned and manifest-verified, the real WER + streamed cycle measured against the tolerance table, the first engine-attributed whisper transcriptions recorded, and the license sign-off recorded. Recorded, never gated.

## In-scope

- **M1 — Provision + verify (SMOKE 102, both tiers):** `Scripts/provision-asr-fixtures.sh` provisions turbo (1,624,555,275 B) and q5_0 (574,041,195 B) with the `verified` marker; `ManifestDigestVerificationTests` `testEveryShippedManifestMatchesTheProvisionedBytes` runs green naming both tiers `MANIFEST-VERIFY`; a digest mismatch is a defect fixed test-first with provenance recorded (`STATUS.md:1043-1049`). Ordered **before** any whisper WER row (`tolerances_20260829.md:59-72`).
- **M2 — WER + streamed cycle (SMOKE 19):** `WhisperCppEngineWERTests` with `VOCCA_MODEL_DIR` set (visible skip lifted): six fixtures vs tolerances (clean 0.10 / spike-clip 0.10 / accented 0.12 / noisy 0.20 / sixty-second 0.10 / two-hundred-ms 1.0), streamed-final == batch, short-audio rows (0.2/0.5/1 s) through both `transcribe` and `stream` (`WhisperCppEngine.swift:240-258` — "reasoning, not measurement" until recorded), the O(n²) cost observation against the shipped constant (never gated). **q5_0 disposition:** run q5_0 through the same six fixtures and record its rows against the turbo table, re-baselining a q5_0 row via `tolerances_20260810.md` if missed, or record "q5_0 accuracy not tolerance-tested" as a named row if the founder declines (PRD M2). Provisioning a tier must not silently open a new unmeasured surface.
- **M3 — First transcriptions + license (SMOKE 95, 96/103, 21):** tier download recorded; first whisper transcription engine-attributed (whisper identity, not Parakeet's); whisper.cpp license sign-off recorded (model-lifecycle M10).

## Out-of-scope

- Any tuning of SDK window configs or engine parameters (founder decision, recorded not gated, only via the named single-source file).
- The F2 corpus (aspect `cleanup-eval-f2`).
- Claiming any latency win (the equivalence NO-GO stands; this aspect records no latency claim).

## Acceptance criteria (testable)

- SMOKE 102 row: both tiers named `MANIFEST-VERIFY`; a failing digest is fixed RED→GREEN with provenance before any whisper WER row.
- SMOKE 19 rows: whisper WER per fixture, streamed-final == batch, three short-audio rows, the O(n²) row — each recorded in `SMOKE_CHECKLIST.md` with its numbers.
- q5_0's accuracy disposition recorded (measured rows or explicitly named not-tested) — no silent new unmeasured surface.
- SMOKE 95/96/103/21 rows recorded; first transcription engine-attributed.
- Every re-baseline follows measure → margin → founder-signed row in `tolerances_20260810.md` → land in exactly the named files (both WER test classes where tolerances change); single-source scans stay green.
- Defect fixes RED→GREEN, floor 1755 holds.

## Dependencies and sequencing

- Requires `Scripts/provision-asr-fixtures.sh` + the founder's model store; GGUF download (~2.2 GB both tiers) is the long-pole dependency — start early.
- SMOKE 102 before 19 (`tolerances_20260829.md:59-72`); 104 (re-baseline from step 19) void unless 102 passed.
- Parakeet's six-fixture WER rows are already recorded (`STATUS.md:202-205`) — this aspect measures whisper only; do not re-run Parakeet.

## Open questions / risks

- Whisper's real WER may miss the seeded tolerances (seeded from Parakeet's table) — re-baselines via `tolerances_20260810.md`, never relaxes silently.
- Short-audio behavior (pad vs refuse) is unrecorded until this run — the 0.2/0.5/1 s rows are that record.
- Digest provenance gap (`STATUS.md:1043-1049`): a first-execution digest failure is a defect (M1), not a blocker.
- GGUF download friction: resumable transfer + digest verification are the mitigation; a stalled download blocks only the whisper half.