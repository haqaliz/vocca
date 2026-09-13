# Understanding: kokoro-binding

> Phase 2 dig note. Source: `docs/planning/_card/issue.md` (the recorded follow-on card) +
> local mapping agent + web research (2026-09-12).

## What this work really is

Bind Kokoro-82M behind the shipped `SpeechSynthesizer` seam (C9's second half): make the
runtime decision **here** (not deferred again — the card's first job), then ship the binding
test-first: one entry in the parameterized suite, cancel ≤50 ms + re-invoke, TTFA compared
against the system renderer's recorded ~178.8 ms baseline, C2-store provisioning, zero-egress
default.

## The runtime decision — the research changes the premise

`ARCHITECTURE.md:706`'s open question (C/C++ shim vs ONNX/CoreML vs MLX) was written when the
Swift ecosystem was thin. The 2026-09-12 research finds it mature:

- **CoreML/ANE ports with pre-converted models:** Jud/kokoro-coreml (**Apache-2.0**, SPM,
  streaming `AsyncStream` chunks, sentence-boundary chunking, ~99 MB 8-bit palettized model,
  24 kHz mono PCM, 6-16× realtime, macOS 15+); mweinbach/kokoro-runtime-swift (MLX + CoreML
  backends, phoneme-input oriented — more integration work); laishere/mattmireles conversions
  (7/5-stage ANE pipelines — vendor-own territory).
- **The phonemizer is no longer espeak-ng for English:** Misaki (hexgrad's G2P, Apple
  NaturalLanguage-based) is bundled in the strongest ports — the recorded "hidden cost of
  every option" is now a solved dependency for English; espeak-ng remains an option, not a
  requirement.
- **The C-shim/VoccaBridge reservation is stale:** the whisper precedent itself says a C-ABI
  bridge "needs no module boundary of its own; it only needs the lint" (`ARCHITECTURE.md:48-51`),
  and no maintained Swift Kokoro-on-onnxruntime path exists; the mature Swift ports make the
  reservation moot. The unit should record this overturn.

**Recommended family: CoreML/ANE via a Swift port**, the Parakeet precedent (CoreML/ANE,
one seam file, SPM dependency). **Primary candidate: Jud/kokoro-coreml** (Apache-2.0, the
streaming shape matches the seam's chunk stream; model bytes on HF — provenance/verify via
the C2 manifest discipline as a plan gate).

## The integration points (from the local map)

- **Seam surface (fixed):** `SpeechSynthesizer` (identity `"kokoro-82m"`, speak→chunk stream,
  cancel ≤50 ms + no chunk after + safe re-invoke), `AudioChunk`, `VoiceIdentity`,
  `SentenceChunker` — the binding implements exactly these four.
- **Suite entry (fixed):** `SpeechFixtureSuite.evaluate` + an env-gated suite file mirroring
  `SpeechSystemSuiteTests` (`VOCCA_RUN_REAL_SPEECH` presence gate); fixtures
  `three-sentence-reply` (≥1.0 s) + `short-reply` (≥0.25 s); cancelLatency ≤50 ms wall-clock;
  re-invoke full render.
- **Provisioning:** `ModelStore`/`ModelManifest`/`ModelDownloader`/`DefaultModelTransport`
  are **engine-agnostic and reusable unchanged** (string-keyed). Reachability is the only
  friction: the machinery lives in VoccaASR; VoccaSpeech may import only VoccaCore. **Cleanest
  path: dependency injection from the composition root** — `VoccaBootstrap` (which imports
  everything) provisions via the store and passes the model directory URL + voice into
  `KokoroEngine(modelDirectory:voice:)` as plain data; the engine never touches the store;
  no boundary amendment. The TTS manifest loader must NOT grow the EngineTier-closed
  `ShippedModelManifest` switch — a parallel loader in the speech side or bootstrap.
- **Lints to add:** (1) a Kokoro-runtime family lint (one permitted file —
  `VoccaSpeech/Kokoro/KokoroEngine.swift` — naming the port's identifiers, planted-violation
  + comment-strip controls, the ParakeetSeamTests shape); (2) an AVFoundation expected-set
  row if the engine touches AVFAudio (else avoid); (3) **no new URLSession file** — the port
  must be given model bytes, not URLs (the port's own downloaders are NOT used — Vocca
  provisions; the seam family keeps the port's networking out).
- **Zero-network probe:** the Kokoro engine joins `VoccaSpeech`'s driven work (construct +
  empty-speak + cancel) — **init must be pure-local** (no model load/download in init, the
  SystemSynthesizer precedent); empty-speak short-circuits before any model touch.
- **Floor:** 1949; the unit's tests raise it in the same commit (doctrine).

## Ambiguities / open questions

- **The port's G2P/phonemization mechanism** (Jud's README doesn't name Misaki explicitly in
  the snippets) — verified as a plan gate: license + provenance + phonemization + cancel
  semantics of the chosen port, pinned before the dependency lands.
- **The port's own model downloader must be suppressed** in Vocca (zero-network default) —
  the port receives a provisioned path; its network surface must never run. Pinned by the
  probe + the seam family lint.
- **Cold-load TTFA:** CoreML first-run latency is high (the ports' own docs say warm runs are
  much faster) — the engine's speak() must assume a provisioned+warm model (the ASR warm-start
  pattern); the TTFA measurement runs warm, and the cold-load cost is recorded as a
  provisioning/prepare fact, never as speak latency.
- **Voice set:** one shipped voice (af_heart, the standard embedding) in the manifest;
  the 54-voice on-demand downloaders of the ports are out of scope (zero-network).

## Honesty obligations (binding)

- The P3 gate stays uncleared; TTFA stays recorded, never gated; the record names the runtime
  decision + the reservation overturn, not as vibes but with the research cited.
- The dependency's license + the model bytes' digests are pinned before merge (the C2
  provenance discipline).