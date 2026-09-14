# PRD: Kokoro Binding (C9's second half)

> Source card: `docs/planning/_card/issue.md` (the recorded follow-on from
> `kokoro-voice-output`). Four founder decisions ratified 2026-09-12: **CoreML/ANE Swift port**,
> **Jud/kokoro-coreml**, **DI from the composition root**, **one voice (af_heart)**.
> **Vetting executed 2026-09-14 against the port's actual code** (`Jud/kokoro-coreml` @ main,
> v0.11.2): the port passes the gate with three recorded corrections — the phonemizer is
> **not** Misaki (bundled English G2P + BART fallback), the dependency requires
> **`swift-tools-version: 6.2`** (CI must move off Xcode 16), and the model artifact is a
> **single tarball** (provisioning = download + idempotent extraction). See
> `docs/planning/_card/understanding.md` for the evidence.

## Problem Statement

C9's first half shipped the `SpeechSynthesizer` seam + the system renderer; the second
implementation — Kokoro-82M — is the recorded follow-on. The runtime question
(`ARCHITECTURE.md:706`) is resolved (CoreML/ANE via a Swift port; the VoccaBridge C-shim
reservation overtaken by the ecosystem, cited at `ARCHITECTURE.md:43-51`). What happens if
we don't build this: the P3 voice loop's default voice stays a system voice; the "local
Kokoro TTS" promise in `VISION.md` stays unfulfilled; and the wedge's flagship
differentiator — talking back with a voice that isn't Siri's — stays unbuilt. The seam
doctrine (`ROADMAP.md` principle 4: two real implementations) stays unproven for TTS.

## Goals & Success Metrics

- **G1 — The runtime decision, made and recorded.** CoreML/ANE via a Swift port
  (Jud/kokoro-coreml, Apache-2.0 — LICENSE verified verbatim 2026-09-14), DI from the
  composition root, one voice (af_heart). **Correction (recorded, not assumed):** the
  port's phonemization is **not Misaki** — it bundles its own English G2P (lexicon +
  morphological stemming + number expansion; `us_gold.json`/`us_silver.json` in package
  resources) with a BART neural fallback via `Jud/swift-bart-g2p` (Apache-2.0, models
  bundled in resources — no runtime download). The record (STATUS/CLAUDE.md/
  ARCHITECTURE.md) states what the port actually does.
- **G2 — The conformance.** `KokoroEngine: SpeechSynthesizer` in
  `VoccaSpeech/Kokoro/KokoroEngine.swift` (the one file naming the port's family):
  `identity.engineID == "kokoro-82m"`, voiceName from the plain-data voice input;
  `speak(_:)` → chunk stream, **one port `synthesize(text:voice:speed:)` call per
  `SentenceChunker` sentence** (the PRD R1b guaranteed path — the port's streaming
  `speak()`/`SpeakEvent.audio(AVAudioPCMBuffer)` is deliberately NOT used, keeping the
  file AVFoundation-free); `cancel()` ≤50 ms with zero chunks after + safe re-invoke
  (the generation-tagged flag pattern; **cancel finishes the stream without waiting for
  the in-flight synchronous call**, dropping the orphaned result by generation — a
  ~100 ms/chunk call cannot be interrupted mid-call); **init pure-local** — no port-engine
  construction (the port's init does file IO + spawns a warmup thread = a model load;
  construct lazily on first speak), no download (the probe's contract).
- **G3 — The suite entry.** The parameterized body runs over `KokoroEngine` env-gated
  (`VOCCA_RUN_REAL_SPEECH` presence gate, the `SpeechSystemSuiteTests` shape): fixtures
  `three-sentence-reply` (≥1.0 s) + `short-reply` (≥0.25 s), cancelLatency ≤50 ms
  wall-clock, re-invoke full render, per-chunk duration > 0.
- **G4 — TTFA measured, recorded, never gated.** Warm-run time-to-first-chunk measured
  and compared against the system renderer's recorded ~178.8 ms baseline (SMOKE 129's
  row gains a Kokoro line or a new row — step 130); the ≤300 ms P3 budget is never a CI
  gate. The cold-load cost (CoreML first compile) is a provisioning/prepare fact, never
  speak latency — the bootstrap prepares the engine at launch (the ASR warm-start
  parallel, `AppBootstrap.prepareAndAssemble`).
- **G5 — Provisioning, C2-disciplined.** The TTS manifest rides the existing string-keyed
  store machinery unchanged; the composition root provisions and **injects the path**
  (no boundary amendment; `VoccaSpeech` stays VoccaCore-only). **The artifact is a
  tarball** (`kokoro-models.tar.gz` @ `models-2026-03-23`, GitHub Releases — the newest
  `models-*` release; contains `kokoro_frontend.mlmodelc`, `kokoro_backend.mlmodelc`,
  `voices/` incl. af_heart `.bin`, `vocab_index.json` — shape verified at provisioning
  time): the manifest pins the tarball (sha256 + byteCount from the ACTUAL provisioned
  bytes, never the README's), the bootstrap downloads via the store, **extracts
  idempotently** (`/usr/bin/tar xzf`), and points the engine at the extracted directory;
  the port's own `KokoroEngine.download(to:)` never runs (it is the library's only
  network surface; `init`/`synthesize`/`speak` are zero-network by construction —
  verified); the default configuration stays zero-egress.
- **G6 — The lints, deliberate.** A new Kokoro-runtime family lint (one permitted file,
  planted-violation + comment-strip controls); **no AVFoundation row needed** (the
  binding touches only `SynthesisResult.samples: [Float]`); no new URLSession file; the
  probe drives the module's default work (construct + empty-speak + cancel).
- **G7 — The record.** The runtime decision + the reservation overturn + the three
  vetting corrections (Misaki, tools-version/CI, tarball) + the TTFA numbers land in
  STATUS/CLAUDE.md/ARCHITECTURE.md; the floor ratchets with the unit's tests (currently
  1949; the raise restores the ledger-paragraph pattern).

## User Personas & Scenarios

- **C10 (barge-in).** Cancels mid-utterance and re-invokes — the ≤50 ms contract is the
  binding constraint; the per-sentence `synthesize` + finish-stream-on-cancel design
  satisfies it without depending on the port's streaming shape.
- **The founder.** The recorded payoff: a talking Vocca whose default voice is Kokoro's
  (af_heart), local, zero-egress — the `VISION.md` promise.
- **A future contributor.** The "add your own speech engine" path stays: one seam file +
  one suite entry + one family lint.

## Requirements

### Must-have

- **R1 (vetting gate — EXECUTED 2026-09-14, passes with corrections):**
  - License: **Apache-2.0 verified** against the repo's LICENSE (both the port and its
    BART dependency share the same Apache-2.0 LICENSE blob).
  - Model provenance: **`kokoro-models.tar.gz` @ `models-2026-03-23`** (GitHub Releases;
    port picks the newest `models-*`). Digests pinned in the TTS manifest from the
    actual provisioned bytes.
  - Phonemization: **bundled English G2P + BART fallback** (`Jud/swift-bart-g2p`,
    models bundled in package resources — no runtime download). The Misaki claim is
    corrected in the record.
  - Cancel/chunk semantics: **per-sentence synchronous `synthesize`** (R1b) — verified;
    the ≤50 ms contract is met by our finish-stream-on-cancel mechanics, not by the
    port's streaming shape.
  - **Toolchain: `swift-tools-version: 6.2`** in both dependencies — the port cannot
    build under Vocca's CI Xcode 16 (Swift 6.0/6.1). **CI must move `XCODE_MAJOR` to
    26.x** (availability on the macos-15 runner verified at plan time) or the
    dependency cannot land. Local toolchain (Swift 6.3.3 / Xcode 26.6) is fine.
- **R2 (the dependency):** `Jud/kokoro-coreml` lands in `Package.swift` as a product
  dependency (`KokoroCoreML`) of `VoccaSpeech`; its transitive `BARTG2P` comes along;
  version policy (from/upToNextMinor/exact) decided at plan time — the port is young.
- **R3 (the conformance):** `KokoroEngine` per G2 — one file, the port's identifiers
  confined there, plain-data init (model directory URL, voice, rate), lazy port-engine
  construction (init pure), empty-speak short-circuit before any port touch, the
  SystemSynthesizer cancel shape (finish stream on cancel, drop stale by generation).
- **R4 (the suite + probe):** the env-gated suite entry (G3); the probe drives the
  module (construct + empty-speak + cancel) with zero egress observed.
- **R5 (provisioning):** the TTS manifest (`Sources/VoccaASR/Models/Manifests/
  kokoro-82m.json`, parallel loader — the EngineTier-closed `ShippedModelManifest`
  switch does NOT grow) + the tarball with pinned digests from the ACTUAL provisioned
  bytes; bootstrap downloads via the store + extracts idempotently (marker-guarded) +
  injects the extracted path; the port's downloader suppressed by construction (no URL
  is ever handed to the port); a TTS digest-verification row joins
  `ManifestDigestVerificationTests` (the EngineTier loop does not cover it); the TTS
  provision is sequenced after ASR preparation (the store's single-flight slot is not
  per-manifest).
- **R6 (lints):** the Kokoro family lint; the AVFAudio/URLSession constraints per G6.
- **R7 (record):** G7's record edits (STATUS, CLAUDE.md, ARCHITECTURE.md open-question
  closure, the Misaki correction, the CI bump, SMOKE step 130, the floor ratchet).

### Should-have

- **S1:** a cold-load prepare measurement recorded (the port's first-compile cost as a
  provisioning fact, the ASR warm-start parallel).
- **S2:** the `kokoro-voice-output` PRD's doctrine note updated (the two-implementation
  doctrine is now satisfied — Kokoro + SystemSynthesizer both real and shipped).

### Nice-to-have

- **N1:** more voices later via the store (the seam's voiceName knob is ready).

## Technical Considerations

- **Layer/phase:** P3 voice loop, TTS layer; local-only; the default configuration stays
  zero-egress (the probe + the port-downloader suppression are the enforcement).
- **DI shape:** `KokoroEngine(modelDirectory: URL, voice: String, rate: Float?)` built by
  `VoccaBootstrap` after `ModelStore.downloadIfMissing(manifest:transport:)` +
  extraction; the store's string-keyed surface is reusable unchanged; the
  EngineTier-closed `ShippedModelManifest` does NOT grow (a parallel string-keyed loader
  in `VoccaASR/Models/`). `VoccaBootstrap` gains the `VoccaSpeech` dependency in
  `Package.swift` (the root may import modules; only the reverse is pinned).
- **Cancel mechanics:** per-sentence `synthesize` (~100 ms/chunk) + generation-tagged
  flag; `cancel()` sets the flag, takes the stream continuation, and **finishes it
  immediately** — the consumer's `next()` returns nil within the ≤50 ms budget without
  waiting for the in-flight call; the orphaned result is discarded by generation.
- **The probe:** the engine's init + empty-speak + cancel run inside the interposed
  process; any deferred egress (settle window 0.75 s) fails the invariant. Init must
  not construct the port engine (file IO + warmup thread) — lazy construction keeps
  construct pure.
- **CI:** `XCODE_MAJOR 16 → 26` (`.github/workflows/ci.yml:58`) — a deliberate,
  reviewable edit; the runner image availability is verified at plan time.
- **Floor:** 1949 today; the unit's tests ratchet it in the same commit (doctrine), with
  the ledger paragraph restored.

## Risks & Open Questions

- **The port is young and single-maintainer** (2026-03, ~10 stars): the seam contains it
  (one file + one family lint + the suite); the vetting record names the dependency's
  state honestly. A future port failure re-opens the pick (mweinbach's packages are the
  recorded alternates).
- **Toolchain coupling:** both dependencies require Swift 6.2+; CI is on Xcode 16. The
  bump is in scope; if Xcode 26.x is unavailable on the runner, the fallback (vendoring
  with a lowered tools-version) forks the trust boundary and is surfaced before merge.
- **Tarball extraction** is bootstrap-side and must be idempotent + marker-guarded; an
  interrupted extraction must never leave a "present but unusable" state.
- **Cold-load TTFA is high** (CoreML first-run compilation): warm-run measurement per
  G4; the cold cost is a prepare fact, never a speak-latency claim.
- **The port's internal downloads must never run:** suppressed by construction
  (provisioned bytes only; `download(to:)` never called) and pinned by the probe + the
  family lint.
- **P2/P3 gates uncleared** (recorded posture, unchanged); TTFA stays recorded, never
  gated.

## Out of Scope

- No UI, no playback/ducking (C10), no 54-voice set, no boundary amendment (VoccaSpeech
  stays VoccaCore-only; DI carries the provisioned path), no espeak-ng/Misaki adoption,
  no P3 gate claims, no cloud.

---

## Aspect decomposition

| Aspect | Boundary |
|--------|----------|
| `port-vetting` | The dependency decision pinned **in this unit's first commit**: license (done), provenance (models-2026-03-23 tarball), phonemization (bundled G2P + BART — Misaki correction), cancel semantics (per-sentence synthesize), toolchain (6.2 → CI bump decision), version pin; `Package.swift` lands the dependency; the corrections recorded. |
| `engine-binding` | `KokoroEngine` (one file, the seam conformance, lazy port construction, finish-stream-on-cancel), the Kokoro family lint, the env-gated suite entry, the probe wiring — test-first. |
| `provisioning` | The TTS manifest + tarball digests (from actual bytes), the bootstrap's store-provision + idempotent extraction + inject path, the digest-verification row, the CI bump, the record (STATUS/CLAUDE.md/ARCHITECTURE.md/SMOKE 130/floor). |