# PRD: Kokoro Binding (C9's second half)

> Source card: `docs/planning/_card/issue.md` (the recorded follow-on from
> `kokoro-voice-output`). Four founder decisions ratified 2026-09-12: **CoreML/ANE Swift port**,
> **Jud/kokoro-coreml** (vetted at the plan gate), **DI from the composition root**,
> **one voice (af_heart)**.

## Problem Statement

C9's first half shipped the `SpeechSynthesizer` seam + the system renderer; the second
implementation — Kokoro-82M — is the recorded follow-on. The runtime question
(`ARCHITECTURE.md:706`: C/C++ shim vs ONNX/CoreML vs MLX) is the unit's first job: the
2026-09-12 research found a mature Swift CoreML/ANE ecosystem (pre-converted models on HF,
Apache-2.0 ports, Misaki G2P replacing espeak-ng for English) that overtakes the
VoccaBridge reservation's premise — the whisper precedent itself says a C-ABI bridge "needs no
module boundary of its own; it only needs the lint" (`ARCHITECTURE.md:48-51`). What happens if
we don't build this: the P3 voice loop's default voice stays a system voice; the "local Kokoro
TTS" promise in `VISION.md` stays unfulfilled; and the wedge's flagship differentiator —
talking back with a voice that isn't Siri's — stays unbuilt.

## Goals & Success Metrics

- **G1 — The runtime decision, made and recorded.** CoreML/ANE via a Swift port
  (Jud/kokoro-coreml, Apache-2.0), DI from the composition root, one voice (af_heart);
  the VoccaBridge C-shim reservation recorded as overtaken by the ecosystem (cited, not
  asserted). The phonemizer note updated: Misaki (English G2P) replaces espeak-ng in the
  chosen port — verified at the plan gate, not assumed.
- **G2 — The conformance.** `KokoroEngine: SpeechSynthesizer` in
  `VoccaSpeech/Kokoro/KokoroEngine.swift` (the one file naming the port's family — the
  ParakeetEngine shape): `identity.engineID == "kokoro-82m"`, voiceName from the plain-data
  voice input; `speak(_:)` → chunk stream (sentence boundaries via the port's chunking or the
  shipped `SentenceChunker`); `cancel()` ≤50 ms with zero chunks after + safe re-invoke (the
  generation-tagged flag pattern from `SystemSynthesizer`); **init pure-local** (no model
  load, no download — the probe's contract).
- **G3 — The suite entry.** The parameterized body runs over `KokoroEngine` env-gated
  (`VOCCA_RUN_REAL_SPEECH` presence gate, the `SpeechSystemSuiteTests` shape): fixtures
  `three-sentence-reply` (≥1.0 s) + `short-reply` (≥0.25 s), cancelLatency ≤50 ms wall-clock,
  re-invoke full render, per-chunk duration > 0.
- **G4 — TTFA measured, recorded, never gated.** Warm-run time-to-first-chunk measured and
  compared against the system renderer's recorded ~178.8 ms baseline (SMOKE 129's row gains a
  Kokoro line or a new row); the ≤300 ms P3 budget is never a CI gate. The cold-load cost is
  recorded as a provisioning/prepare fact, never as speak latency.
- **G5 — Provisioning, C2-disciplined.** The TTS manifest (model bytes + the af_heart voice
  artifact, digests pinned in-repo) rides the existing string-keyed store machinery
  unchanged; the composition root provisions and **injects the path** (no boundary
  amendment); the port's own downloaders never run (the seam family lint + the probe pin);
  the default configuration stays zero-egress.
- **G6 — The lints, deliberate.** A new Kokoro-runtime family lint (one permitted file,
  planted-violation + comment-strip controls); no new URLSession file; an AVFoundation
  expected-set row only if the engine touches AVFAudio; the probe drives the module's default
  work (construct + empty-speak + cancel).
- **G7 — The record.** The runtime decision + the reservation overturn + the TTFA numbers
  land in STATUS/CLAUDE.md/ARCHITECTURE.md (the open question 1 is closed with the decision);
  the floor ratchets with the unit's tests (currently 1949).

## User Personas & Scenarios

- **C10 (barge-in).** Cancels mid-utterance and re-invokes — the ≤50 ms contract is the
  binding constraint the port's per-sentence chunk loop must satisfy.
- **The founder.** The recorded payoff: a talking Vocca whose default voice is Kokoro's
  (af_heart), local, zero-egress — the `VISION.md` promise.
- **A future contributor.** The "add your own speech engine" path stays: one seam file + one
  suite entry + one family lint.

## Requirements

### Must-have

- **R1 (vetting gate, before the dependency lands):** the chosen port's license (Apache-2.0
  expected — verified against the repo's LICENSE file), its model bytes' provenance
  (HF repo + digests pinned in the TTS manifest), its phonemization mechanism (Misaki G2P —
  verified against the actual API, not the README snippet), and its cancel/chunk semantics
  (per-sentence yield — verified; a port that cannot interrupt per sentence is a blocker for
  the ≤50 ms contract and the pick is re-opened).
- **R1b (the guaranteed cancel path):** the ≤50 ms contract does NOT depend on the port's
  streaming shape. The engine's baseline shape is the SystemSynthesizer pattern — **one
  render call per sentence chunk, cancel between calls** (the port's synchronous
  `synthesize` is fine); the port's streaming API is used only where its per-sentence
  interruptibility is proven at the vetting gate. TTFA is measured per the seam's chunk
  granularity either way.
- **R2 (the dependency):** `Jud/kokoro-coreml` lands in `Package.swift` as a product
  dependency of `VoccaSpeech`; its networking surface is never invoked (Vocca provisions).
- **R3 (the conformance):** `KokoroEngine` per G2 — one file, the port's identifiers confined
  there, plain-data init (model directory URL, voice, rate), the SystemSynthesizer cancel
  pattern, empty-speak short-circuit before any model touch.
- **R4 (the suite + probe):** the env-gated suite entry (G3); the probe drives the module
  (construct + empty-speak + cancel) with zero egress observed.
- **R5 (provisioning):** the TTS manifest + af_heart artifact with pinned digests —
  **the digests are generated from the ACTUAL provisioned bytes (sha256 over the downloaded
  files), never copied from the port's README numbers**, per the C2 provenance discipline;
  the bootstrap provisions via the existing store and injects the path; the port's
  downloaders suppressed by construction (no URL is ever handed to the port).
- **R6 (lints):** the Kokoro family lint; the AVFAudio/URLSession constraints per G6.
- **R7 (record):** G7's record edits (STATUS, CLAUDE.md, ARCHITECTURE.md open-question
  closure, SMOKE 129's Kokoro line, the floor ratchet).

### Should-have

- **S1:** a cold-load prepare measurement recorded (the port's first-load cost as a
  provisioning fact, the ASR warm-start parallel).
- **S2:** the `kokoro-voice-output` PRD's doctrine note updated (the two-implementation
  doctrine is now satisfied — Kokoro + SystemSynthesizer both real and shipped).

### Nice-to-have

- **N1:** more voices later via the store (the seam's voiceName knob is ready).

## Technical Considerations

- **Layer/phase:** P3 voice loop, TTS layer; local-only; the default configuration stays
  zero-egress (the probe + the port-downloader suppression are the enforcement).
- **DI shape:** `KokoroEngine(modelDirectory: URL, voice: String, rate: Float?)` built by
  `VoccaBootstrap` after `ModelStore.downloadIfMissing(manifest:transport:)` — the store's
  string-keyed surface is reusable unchanged; the EngineTier-closed `ShippedModelManifest`
  does NOT grow (a parallel TTS loader in the bootstrap or speech side).
- **Cancel mechanics:** the port yields per sentence (its README's chunking) — the engine's
  generation-tagged cancel takes effect at the next yield; a port that renders a whole
  utterance in one call cannot meet ≤50 ms and the vetting gate catches it.
- **The probe:** the engine's init + empty-speak + cancel run inside the interposed process;
  any deferred egress (settle window 0.75 s) fails the invariant.
- **Floor:** 1949 today; the unit's tests ratchet it in the same commit (doctrine).

## Risks & Open Questions

- **The port is young and single-maintainer** (2026-03, ~10 stars): the seam contains it (one
  file + one family lint + the suite), and the vetting gate records the dependency's state
  honestly. A port that fails the vetting re-opens the pick (mweinbach's packages are the
  alternates, license review pending).
- **The port's actual API may differ from its README** (chunking, cancellation, G2P inputs):
  the vetting gate verifies against code, and R4's suite is the behavior's judge.
- **Cold-load TTFA is high** (CoreML first-run compilation): warm-run measurement per G4;
  the cold cost is a prepare fact, never a speak-latency claim.
- **The port's internal downloads must never run:** suppressed by construction (provisioned
  bytes only) and pinned by the probe + the family lint.
- **P3 gate uncleared** (recorded posture, unchanged); TTFA stays recorded, never gated.

## Out of Scope

- No UI, no playback/ducking (C10), no 54-voice set, no boundary amendment (VoccaSpeech stays
  VoccaCore-only; DI carries the provisioned path), no espeak-ng, no P3 gate claims, no cloud.

---

## Aspect decomposition

| Aspect | Boundary |
|--------|----------|
| `port-vetting` | The dependency decision pinned: license, provenance, phonemization, cancel/chunk semantics verified against the port's code; `Package.swift` lands the dependency; the research + the reservation overturn recorded. |
| `engine-binding` | `KokoroEngine` (one file, the seam conformance), the Kokoro family lint, the env-gated suite entry, the probe wiring — test-first. |
| `provisioning` | The TTS manifest + af_heart artifact + digests, the bootstrap's store-provision + inject path, the port-downloader suppression pin, the record (STATUS/CLAUDE.md/ARCHITECTURE.md/SMOKE 129/floor). |