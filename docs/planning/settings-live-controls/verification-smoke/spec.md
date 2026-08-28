# Aspect 6: `verification-smoke`

**Merge order: 5th (before the cleanup tail).** Depends on aspect 1.

## Problem slice

Two unverified claims sit under this unit, and shipping a picker turns both into user-facing risk.

**R-A — whisper has never transcribed anything.** `WhisperCppEngineWERTests` skips without
`VOCCA_MODEL_DIR`; `SMOKE_CHECKLIST.md` step 19 is unexecuted; `tolerances_20260810.md` records the
tolerances as *seeded from Parakeet's table, not measured on whisper's output*. The picker offers a
1.6 GB download to a destination nobody has verified.

**R-B — the manifest digests are unverified against the served bytes.** The predicted
`{}`-placeholder defect **does not reproduce** (SHA-256 `44136fa3…` appears in no manifest; no
0/2-byte sizes; no duplicated digests). "Not the known defect" is not "verified".

**User outcome:** nobody downloads 1.6 GB into a broken install, and no release claims more than
was measured.

## In scope

- **R1** An env-gated check that each shipped manifest's digests and byte counts match the bytes
  the repository actually serves. Skips **visibly** in CI (the `VOCCA_MODEL_DIR` precedent — a
  silent pass is what let the Parakeet placeholder survive).
- **R2** `SMOKE_CHECKLIST.md` steps for: the Speech tab's first execution, whisper's first real
  transcription end to end, the removal/confirmation path, and the three in-between windows (M11).
- **R3** The tolerance re-baselining procedure for whisper, following the house measure → margin →
  founder-signed shape, keeping the number in exactly one place.
- **R4** A release-note line stating plainly that whisper is selectable but unverified until the
  smoke step passes.

## Out of scope

- Actually running the steps (founder's machine, by construction).
- Measuring latency, or the C8 injection-matrix baseline.
- Downloading anything in CI. The zero-network invariant is absolute.

## Acceptance criteria (tests first)

1. R1 skips visibly without its env var, and **fails loudly** on a planted digest mismatch — a
   gate that cannot fail proves nothing.
2. The smoke steps follow the existing step format and are numbered from the current maximum.
3. R3's number lives in exactly one file, pinned by a single-source scan (the
   `ProvisionalCleanupTargets`/`WarmStartTargets` precedent).
4. CI is unchanged in its network behaviour: the zero-network probe stays green.

## Risks

- The temptation is to let R1 quietly pass when the env var is absent. The whole reason this aspect
  exists is that a check which cannot fail is what shipped the Parakeet placeholder.
