# model-lifecycle — spec

> Aspect of `second-asr-engine` (C3). PRD: `docs/planning/second-asr-engine/prd.md`
> (M4, M9-half, M10).

## Problem slice

The GGUF artifacts for the Whisper engine, provisioned and verified through the shipped
engine-agnostic `ModelStore`/`ModelDownloader`, with real SHA-256 digests pinned in
checked-in manifests — the same integrity story C2's Parakeet manifest already has.

## In-scope

- Two checked-in manifests: `Sources/VoccaASR/Models/Manifests/whisper-large-v3-turbo.json`
  (default tier, 1.5 GiB) and `whisper-large-v3-turbo-q5_0.json` (constrained tier,
  547 MiB). Shape: `engineID "whisper-large-v3-turbo"`, `version "1"`, **no
  `sdkDirectory`** (flat single-file layout), one `ManifestFile` each
  (`ggml-large-v3-turbo.bin` / `ggml-large-v3-turbo-q5_0.bin`) with real SHA-256 +
  byteCount computed at provisioning time (upstream documents SHA-1 only — never copied
  from docs).
- Provisioning script generalized from `Scripts/provision-asr-fixtures.sh` (currently
  Parakeet-hardcoded `ENGINE`/`VERSION`/`SDK_DIR`/`REQUIRED`): `--engine` +
  single-file mode (no `sdkDirectory`, install at `<version>/<file>`), prints
  `VOCCA_MODEL_DIR`-compatible version-dir path.
- Model store reuse **as-is**: no changes to `ModelStore`/`ModelDownloader`. A store
  test (existing `ModelStoreTests`/`ModelDownloaderTests` patterns) proves a
  single-file manifest round-trips: download → verify → marker → `isPresent`, and that a
  `.part`/corrupt file is refused.
- **M10 — weights license verification (pre-merge task, founder-signed):** verify the
  GGUF weights' license from a primary source (HF `ggerganov/whisper.cpp` repo
  metadata / OpenAI whisper LICENSE) and record it; add the attribution surface
  (NOTICE/THIRD_PARTY entry) for whisper.cpp + ggml (MIT) and the converted weights.

## Out-of-scope

- Engine code consuming the manifests — `whisper-engine` aspect.
- Any model store changes, model registry UI, auto-update (C14 / `PRODUCT_SPEC.md:273`).
- Downloading the 1.5 GiB artifact into CI.

## Acceptance criteria (test-first)

1. Both manifests decode via `ModelManifest.load` and satisfy the store's validation
   (unknown fields, digest shape, safe paths, duplicates — the `ModelManifestTests`
   machinery).
2. A headless store test round-trips a single-file manifest over a stub transport and
   asserts verified-marker semantics (no `.part` ⇒ `isPresent`; `sdkDirectory` absent
   ⇒ flat layout).
3. `provision-asr-fixtures.sh --engine whisper-large-v3-turbo --source <dir>` produces a
   store-shaped install + a manifest whose digests match `shasum -a 256` of the files.
4. The pre-merge license task has a recorded answer (verification + attribution) before
   the PR merges.

## Dependencies / sequencing

Independent of `bridge-integration`/`whisper-engine` (parallel). Required by
`fixture-harness` (real WER run needs the artifacts + manifest).

## Open questions

- None. Artifact byteCounts/SHA-256 are computed at provisioning time by the founder's
  machine, then committed.
