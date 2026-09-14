# Spec: provisioning

> Aspect of `kokoro-binding` (C9 second half). Source: `docs/planning/kokoro-binding/prd.md`
> (G5/G7, R5/R7). The store/composition maps are in `docs/planning/_card/understanding.md`.

## Problem slice

The Kokoro model bytes (a single tarball) arrive through the existing C2 store machinery
with pinned digests, extract idempotently, and the composition root injects the path into
`KokoroEngine(modelDirectory:voice:rate:)` — launch-only, zero-egress default, records
updated.

## In-scope

- `Sources/VoccaASR/Models/KokoroModelManifest.swift` — the **parallel** string-keyed
  loader (`load() throws -> ModelManifest`, `Bundle.module` resource `Manifests/kokoro-82m.json`).
  The EngineTier-closed `ShippedModelManifest` switch does NOT grow.
- `Sources/VoccaASR/Models/Manifests/kokoro-82m.json` — the TTS manifest: `engineID:
  "kokoro-82m"`, `version: "1"`, `sdkDirectory: "kokoro"`, one file entry
  `kokoro-models.tar.gz` with `sha256` + `byteCount` **generated from the actual
  provisioned bytes** (never the port's README numbers).
- `Scripts/provision-kokoro-fixtures.sh` — downloads the asset (founder machine), prints
  digest + byteCount + the manifest JSON to commit (the `provision-asr-fixtures.sh` shape).
- `Sources/VoccaASR/Models/TarballExtractor.swift` — idempotent extraction (`/usr/bin/tar
  xzf` via `Process`, the port's own mechanism), marker = the extracted trio
  (`kokoro_frontend.mlmodelc` + `kokoro_backend.mlmodelc` + `voices/`); an interrupted
  extraction self-heals on the next run (extract-if-absent).
- `Tests/HarnessTests/Fixtures/` — a tiny committed tarball fixture for the extractor test.
- `AppBootstrap` wiring: `kokoroModelRepository` constant (the `models-2026-03-23` release
  asset base URL, beside `AppBootstrap.swift:838-845`, NOT the closed `repositoryURL(for:)`
  switch); a launch-only `prepareSpeechModels(store:)` step invoked from
  `prepareAndAssemble()` (the `AppBootstrap.swift:2372-2414` path), **never from
  `configure`** (probe contract); sequenced **after** ASR preparation (the store's
  single-flight slot is not per-manifest — a racing TTS provision would silently skip);
  a `kokoroSynthesizer(store:)` builder constructing `KokoroEngine(modelDirectory:voice:
  rate:)` with the extracted path (the engine itself is `engine-binding`'s; the builder is
  this aspect's wiring).
- Test rows: the pairwise-distinct storageID pin (kokoro-82m vs the three ASR storageIDs);
  the digest-verification row for the TTS manifest (env-gated `VOCCA_MODEL_DIR`, the
  `ManifestDigestVerificationTests` shape); the provisioning sequence test (fake transport
  asserting manifest/transport/target + extraction + engine path, double-run idempotent);
  the zero-network pin stays the enforcement that `configure` never provisions.
- The record: `docs/STATUS.md` entry, `CLAUDE.md` status paragraph, `ARCHITECTURE.md`
  (open-question closure + the Misaki correction + the tools-version note), SMOKE step 130
  (the Kokoro TTFA row, `SMOKE_CHECKLIST.md:2722-2740` format), floor ratchet + ledger
  paragraph.

## Out-of-scope

- No engine behavior (`engine-binding`'s), no UI, no voice set beyond af_heart, no
  `EngineTier` growth, no new URLSession file (`DefaultModelTransport` is reused), no
  download-triggering from `configure`.

## Acceptance (test-first)

1. Manifest loader test: `KokoroModelManifest.load()` returns the shipped manifest and
   passes the same validation the ASR manifests pass (engineID/version/sdkDirectory
   shape, hex digests, safe file names, duplicate rejection — the
   `ModelStoreTierKeyingTests`/manifest-test shapes).
2. Pairwise-distinct pin: the TTS `engineID` `"kokoro-82m"` ≠ each ASR storageID.
3. Extractor test (committed fixture tarball): extracts to the target; idempotent on
   double-run; interrupted state (partial trio) re-extracts; wrong bytes → failure, never
   a silent partial.
4. Provisioning sequence test: a fake transport + a store-root temp dir — the sequence
   downloads via `downloadIfMissing` with the kokoro manifest, extracts to
   `<root>/kokoro-82m/1/kokoro`, and the builder yields `KokoroEngine(modelDirectory:
   <that path>, voice: "af_heart", rate: nil)`; running the sequence twice downloads once
   (marker) and extracts once more safely.
5. Digest verification row (env-gated): the shipped manifest's digests match the
   provisioned bytes (the `ManifestByteVerifier` shape).
6. Zero-network: the probe still passes (configure never provisions); the
   prepareSpeechModels call site is launch-only (pin via the existing configure-driven
   probe + a call-site scan if the repo's pattern calls for one).
7. The record edits land; the floor ratchets with the new tests in the same commit.

## Dependencies / sequencing

- After `engine-binding` (the builder constructs `KokoroEngine`). The real-suite run
  (founder machine) needs the models provisioned via the script.

## Open questions / risks

- The tarball's internal shape (`vocab_index.json` presence, voice file naming) is
  verified against the actual artifact at provisioning time (the script prints the
  listing); the manifest's `sdkDirectory` assumes extraction to a named subdirectory —
  adjust to the artifact's real layout if it differs.
- GitHub release assets and range resume: `DefaultModelTransport` uses range requests;
  release assets support them — the founder's first real download is the proof (SMOKE).