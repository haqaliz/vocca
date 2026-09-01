# Card: feat/p2-gate-measurement

> Inline brief — no GitHub issue exists. Source: `vocca-next` handoff, 2026-09-01.

## Brief

Execute the already-written acceptance — `docs/SMOKE_CHECKLIST.md` steps 62-68 (the
dictation loop's first real end-to-end run: Notes + TextEdit, Esc, Secure Input,
short-press rows), then the injection-matrix baseline (steps 87-93, `Scripts/injection-matrix.sh`,
22 rows) and the env-gated real runs (latency/warm-start steps 69-70 + 77, equivalence
125-126, cleanup eval 73). Fix the real defects these runs find. Everything records,
never gates; provisional tolerances re-baseline only via each tolerance file's
measure → margin → founder-signed procedure, in exactly one file; any fix lands
test-first with the existing suite floor (1731) as the regression bar.

Acceptance:

- The dictation loop's first real execution passes (steps 62-68): a 10-second utterance
  lands byte-for-byte in Notes and TextEdit, Secure Input never lets a session start
  over a password field, Esc discards during RECORDING and TRANSCRIBING, the
  shortest-session and ceiling rows behave, and the 7-day daily-use gate's first day is
  logged. This is also the release blocker: no installable release before steps 62-68
  (STATUS.md:774).
- The injection matrix baseline is recorded: ≥19 of 20 deliverable rows at
  first-method-success, `--verify-bundle-ids` clean on the founder's machine, the 8
  guessed bundle ids confirmed or corrected, the tracked table's first row filled.
- The latency/warm-start/equivalence/cleanup-eval real runs produce their first measured
  numbers, re-baselining the provisional tolerances via each file's founder-signed
  procedure (never silently relaxed, never gated).
- Every defect found on the way lands as a test-first fix on this branch; suite floor
  1731 never drops.

Caveat: every prior first-execution in this repo found defects CI cannot catch
(STATUS.md:694-713 short-press, 474-495 local-dev-launch, 725-760 release symlink) —
expect to fix real bugs. Whisper's WER run (step 19) and the whisper manifest digests'
provenance remain unmeasured/unverified and surface in these runs. No number claimed as
a gate pass until the P2 gate's three legs (latency, matrix, external users) all have
measured rows.