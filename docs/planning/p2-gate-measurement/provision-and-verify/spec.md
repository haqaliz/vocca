# Spec: provision-and-verify

**Aspect of:** p2-gate-measurement · **PRD ref:** execution order step 1 · **Date:** 2026-09-01

## Problem slice and user outcome

Every env-gated real run needs real model bytes present in the `ModelStore` layout and
verified against the shipped manifests — and the manifests' digests have never been
checked against provisioned bytes (whisper's "verified digests" have no provenance,
`STATUS.md:820-825`). Outcome: the founder's machine is provisioned for both engines,
the manifest verification run (SMOKE step 102) produces its first result, and any
digest mismatch lands as a test-first fix before a single dictation runs.

## In-scope

- Run `Scripts/provision-asr-fixtures.sh` for Parakeet (4 `.mlmodelc` + `config.json` +
  parakeet_vocab) and both whisper tiers (GGUF large-v3-turbo + q5_0); record the
  printed `VOCCA_MODEL_DIR` value.
- Run the manifest verification (`ManifestDigestVerificationTests`, gated by
  `VOCCA_MODEL_DIR`, SMOKE step 102) and record its result.
- Fix any digest mismatch found (RED→GREEN, regression test, floor never drops), with
  the corrected digest's provenance recorded per `STATUS.md:820-825`'s open item.
- Record the aspect's rows in the SMOKE checklist per house convention.

## Out-of-scope

- Any engine WER or latency run (aspect `real-engine-runs`).
- Model download UI, the model registry, or any P5 surface.

## Acceptance criteria (testable)

- `Scripts/provision-asr-fixtures.sh` runs clean for all three tiers and prints the
  model dir the gates use.
- `ManifestDigestVerificationTests` runs with `VOCCA_MODEL_DIR` set: skip lifted, all
  shipped manifests verify against provisioned bytes, no named tier left unprovisioned.
- If a digest failed: the fix commit is RED→GREEN and the provenance row exists; the
  suite floor (1731) holds after the fix.

## Dependencies and sequencing

- First aspect. Nothing else runs before it. Depends on the founder's machine having the
  model artifacts (downloaded per `docs/planning/local-asr/` + `second-asr-engine/`
  manifests).
- The model artifacts themselves are not in the repo and never leave the machine.

## Open questions / risks

- The whisper manifests' provenance is unverified; a digest failure here is expected
  enough to be the aspect's stated fix, not a blocker.
- Disk space: whisper turbo (~1.6 GB) + q5_0 (~574 MB) + Parakeet (~470 MB) — confirmed
  present before provisioning.