# Aspect spec — `model-downloader`

Parent PRD: [`../prd.md`](../prd.md) · Capability C2 · Phase P0
Depends on: `asr-seam` (EngineIdentity vocabulary — used by reference only, not imported here)
Unblocked — no `audio-capture` dependency

---

## Problem slice

The seam now exists as code; the model it would transcribe with does not, and nothing in the
repository can bring it onto the machine. The PRD's model-lifecycle must-haves — download on
first use, integrity verification, resumable transfer, storage in Application Support —
are machinery that exists nowhere, and `ARCHITECTURE.md:16`'s "two named network types"
are named nowhere.

This aspect builds the first of those two types: **`ModelDownloader`**, the one place in
`Sources/` permitted to open a socket, plus the `ModelStore` that says whether a model is
present and verified. The whole aspect is engine-agnostic: it keys directories by
`(engineID: String, version: String)` and never imports `VoccaCore` — the `EngineIdentity`
binding happens in `parakeet-engine`.

**User outcome:** none visible yet (the download UI is `download-ui`'s). The outcome is the
privacy structure the rest of the product leans on: a model that arrives verified or not at
all, resumes instead of restarts, and is the *only* egress the default path can ever take.

**Why it is the second aspect:** fully headless — the transport is a seam, so every
decision (resume, verify, retry, atomicity, progress) is tested with a stub and a temp
directory; no model, no network, no microphone. And it is the enforcement point of the
zero-network claim: confine `URLSession` to one file and the invariant holds by lint rather
than by hope.

---

## What this aspect inherits — decided, do not relitigate

| # | Constraint | Where it came from |
|---|---|---|
| 1 | **The downloader is the first named network type** — the only one of `ARCHITECTURE.md:16`'s "two named types" this capability names (the BYOK client in C6 is the other). The default dictation path never touches it: it is reached only by an explicit `downloadIfMissing` call. | PRD M8; amends `ARCHITECTURE.md` I2 |
| 2 | **`URLSession` appears in exactly one file in `Sources/`** — the H7 pattern applied to the transport. A wrong code path that opens a socket elsewhere fails the lint, not an audit. | PRD M6/M14; the H7 precedent (`HotkeySeamBoundaryTests`) |
| 3 | **Storage layout is `~/Library/Application Support/Vocca/models/<engine-id>/<version>/`**, and `<engine-id>` is the string `EngineIdentity.id` (`"parakeet-tdt-0.6b-v3"`), which the directory key must match exactly. | `ARCHITECTURE.md:489-490`; PRD M8 |
| 4 | **Models never auto-update.** "No auto-updating models. Model changes alter output; the user decides when that happens." A verified version directory is immutable; `downloadIfMissing` writes only the pinned version. | `PRODUCT_SPEC.md:273`; PRD M9 |
| 5 | **The checksum manifest ships in-repo and is never fetched** — verification stays offline and honest. The manifest's *initial content* is data generated from the real artifact (founder's first download, recorded during the F1 spike); the format and machinery are built and tested against synthetic manifests first. | PRD M8; the "never fetched" rule is this aspect's form of the zero-network claim |
| 6 | **`isPresent` means "present and verified"**, never "a directory exists". The commit is atomic: the version directory is complete and verified before it is ever reported present. | PRD M8; I1-adjacent — a half-verified model must not masquerade as a ready one |
| 7 | **The model files stream to disk** — the Parakeet artifact is ~2 GB, so a `data(for:)`-style buffer is out of the question; the transport writes chunks to the `.part` file as they arrive. | PRD §5; the 2 GB figure (`ROADMAP.md:14`) |
| 8 | **`VoccaASR` stays a leaf in this aspect.** The downloader needs no Vocca imports (Foundation + CryptoKit only), so the module-boundary lint is untouched; the adapter move happens in `parakeet-engine`. | `ModuleBoundaryTests`; the `ARCHITECTURE.md:90-93` home is `VoccaASR/Models/` |

---

## In scope

- `ModelManifest` (Codable): `engineID`, `version`, `files: [ManifestFile]` with `name`,
  `sha256`, `byteCount`; a JSON loader that validates shape (rejects unknown fields,
  duplicate names, non-hex or wrong-length digests — the near-miss pattern).
- `ModelStore`: injected root URL (default = Application Support/Vocca/models, computed —
  never a hardcoded path), `isPresent(engineID:version:)`, `baseURL(for:)` (the load-from-URL
  hook `parakeet-engine` consumes), atomic presence via a verified-marker written only after
  every file's checksum passed.
- `ModelTransport` protocol (Sendable): ranged, streaming, progress-reporting download of
  one URL into a destination file; `DefaultModelTransport` — **the one file permitted to
  name `URLSession`**, using the async bytes API (never `data(for:)`), Range requests,
  stream-to-disk, byte-counted progress. The stub transport lives in tests.
- `ModelDownloader`: given a manifest + store, download each file to `<name>.part`, resume
  from the `.part`'s size when it exists, verify SHA-256 per file, delete-and-restart a file
  whose checksum fails (bounded retries), write the verified marker only when all files
  pass, report aggregate progress 0...1, honour Task cancellation (`.interrupted`, `.part`
  preserved for the next attempt). Server that ignores Range → detect and restart that file
  from scratch, honestly recorded, never corrupt.
- `ModelDownloadError`: `.manifestInvalid`, `.transportFailed(underlying:)`, `.checksumMismatch(file:)`, `.resumeRefused`, `.diskWriteFailed`, `.interrupted`, `.retryLimitExceeded(file:)` — every failure leaves the store in a state where `isPresent` is false and the next attempt resumes or restarts; **no failure state is silently "present"**.
- The confinement lint: a test asserting exactly one file in `Sources/` names `URLSession`
  (the H7 shape).
- Amend `ARCHITECTURE.md` I2: name `ModelDownloader` as the first named network type, with
  the confinement rule stated beside it. Reviewer: aliz.

## Out of scope

- **The EngineIdentity binding** (mapping a `ModelStore` location to an `ASREngine`) —
  `parakeet-engine`.
- **The trigger path** — who calls `downloadIfMissing` (engine prepare vs the download UI's
  button vs onboarding) — `parakeet-engine` / `download-ui`.
- **Load-time verification** (re-checking a verified model before loading; FluidAudio's own
  corrupt-detection on `.mlmodelc`) — `parakeet-engine`, with `ModelHub.offlineMode` making
  refetch structurally impossible there.
- **The real manifest content** — generated data from the real artifact, recorded during
  the F1 spike / the founder's first download; this aspect tests with synthetic manifests.
- **Model registry UI, switching, removal** — C14.
- **Any actual network use in tests or CI** — the stub transport only; the default transport
  is exercised by the founder's first real download and the smoke checklist.

---

## Acceptance criteria (tests written first)

1. **Manifest validation.** A valid manifest decodes; near-misses are rejected: bad digest
   hex/length, duplicate file names, unknown fields, missing engineID/version.
2. **Store contract.** `isPresent` is false before anything lands, false while `.part` files
   exist, **true only after every file verified** (the marker), false again if any file's
   checksum fails after a partial download; `baseURL` matches
   `<root>/<engineID>/<version>/`; the marker is written last and the directory is
   immutable after commit (a second download with the same version does not touch it).
3. **Happy path.** A three-file synthetic manifest downloads, verifies, and commits; progress
   is monotonic and reaches 1.0 exactly once all bytes are written; `isPresent` flips true
   only at commit.
4. **Resume.** A transport that fails mid-file (after N bytes) leaves a `.part` of size N;
   the retry sends a Range starting at N, writes only the remainder, verifies once, and
   commits — **the model is never re-downloaded from zero**.
5. **Checksum mismatch.** A transport serving corrupt bytes → the file's `.part` is deleted,
   the file restarts from zero (bounded retries), and after the retry limit the error is
   `.retryLimitExceeded(file:)` with `isPresent` still false.
6. **Resume refused.** A transport that ignores Range (serves the full body from byte 0)
   → detected and recorded (`.resumeRefused`), the file restarts from zero once, and the
   commit is correct.
7. **Cancellation.** Cancelling mid-download surfaces `.interrupted` and preserves the
   `.part`; a subsequent run resumes rather than restarts.
8. **Confinement.** Exactly one file in `Sources/` names `URLSession`; everything else uses
   the seam. (`ModelDownloaderTests` + the lint test.)
9. **Module discipline.** `VoccaASR` remains a leaf (`ModuleBoundaryTests` green unchanged);
   no `VoccaCore` import anywhere in this aspect; Apache-2.0 headers on every new file; the
   test floor ratchets in the same commit.

---

## Dependencies and sequencing

- **Unblocked.** Foundation + CryptoKit only; no `audio-capture` dependency, no network in
  tests. Runs on the current branch state (asr-seam Phases 1–2 committed).
- `parakeet-engine` follows, opening with the F1 spike; it consumes `ModelStore.baseURL`
  and the verified-marker guarantee.
- The real manifest content lands with the F1 spike's first real download.

---

## Open questions / risks

- **HF file layout unknown until the first real download.** The manifest machinery is
  built against the JSON format; the *content* (file names, sizes, digests) is recorded
  from the real artifact. The plan's Phase 1 names the exact synthetic fixture shape so
  this cannot drift.
- **Does the store need a "last verified at" timestamp?** C14's registry (disk usage,
  remove, re-download) will want bookkeeping; this aspect ships only presence + baseURL and
  leaves the timestamp field out until a consumer exists (the repo's "abstractions are
  earned by the second implementation" rule).
- **Single-flight:** two concurrent `downloadIfMissing` calls must not double-download.
  `ModelStore` is an actor; the plan pins the one-flight behaviour with a test.
