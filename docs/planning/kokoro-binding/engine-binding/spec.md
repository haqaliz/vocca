# Spec: engine-binding

> Aspect of `kokoro-binding` (C9 second half). Source: `docs/planning/kokoro-binding/prd.md`
> (G2/G3/G4/G6, R3/R4). The seam/suite/probe maps are in `docs/planning/_card/understanding.md`.

## Problem slice

`KokoroEngine: SpeechSynthesizer` — the second real implementation, one file, strict
seam conformance, provable in the parameterized suite, driven by the zero-network probe.

## In-scope

- `Sources/VoccaSpeech/Kokoro/KokoroEngine.swift` — the one file naming the port's family:
  `identity.engineID == "kokoro-82m"`, voiceName from plain data; **init pure-local**
  (no port-engine construction — that is a model load; the port's init does file IO +
  spawns a warmup thread); **lazy port-engine construction** on first non-empty speak
  (memoized, with the failure memoized too); one port `synthesize(text:voice:speed:)`
  call per `SentenceChunker` sentence; chunk conversion from `SynthesisResult.samples`
  (`[Float]`, 24 kHz mono) → `AudioChunk` (Float32 little-endian bytes via bitPattern,
  `sampleRate: 24000`, `channelCount: 1`, `duration = count/24000`); empty-speak
  short-circuit before any port touch; **cancel** = generation-tagged flag + **finish the
  in-flight stream continuation immediately** (the ≤50 ms contract must not wait for the
  ~100 ms in-flight call; the orphaned result is discarded by generation — the
  SystemSynthesizer "never call the renderer's stop API" shape); safe re-invoke;
  `continuation.onTermination` cancels the producing task; absent-models → a recorded
  clean error, never a crash.
- `Tests/HarnessTests/KokoroEngineTests.swift` — headless pins (no model, no network).
- `Tests/HarnessTests/SpeechKokoroSuiteTests.swift` — the env-gated suite entry
  (`VOCCA_RUN_REAL_SPEECH` + `VOCCA_KOKORO_MODEL_DIR` presence gates, `SpeechSystemSuiteTests`
  shape) + the `KOKORO-TTFA` recorded-never-gated row.
- `Tests/HarnessTests/KokoroSeamBoundaryTests.swift` — the Kokoro-runtime family lint
  (one permitted file under `VoccaSpeech/`, planted-violation + comment-strip controls,
  the `ParakeetSeamTests` shape; the scan is `VoccaSpeech/`-scoped, so the bootstrap and
  probe may name the engine — the Parakeet precedent).
- `Sources/VoccaNetworkProbe/SpeechDrive.swift` — a Kokoro leg (construct with an empty
  temp directory + empty-speak + cancel, new report keys); module coverage unchanged
  (VoccaSpeech already driven).

## Out-of-scope

- No manifest/provisioning (the `provisioning` aspect), no bootstrap wiring, no UI, no
  playback (C10), no AVFAudio (the binding touches only `SynthesisResult.samples` — no
  expected-import-set row, the existing AVSpeech/AVAudio family pin is untouched).

## Acceptance (test-first)

1. **Headless pins** (run in CI, no model): identity (engineID `kokoro-82m`, voiceName
   from input, distinct from system); init with a nonexistent directory does not throw
   (purity); `speak("")` → empty stream, no throw, no port touch (even with a nonexistent
   directory); non-empty `speak` with a nonexistent/empty directory → the recorded mapped
   error (asserted identity, not a crash); `cancel()` with nothing in flight is a safe
   no-op; sample→`AudioChunk` conversion pins (byte count = 4×samples, sampleRate,
   channelCount, duration) via an internal static (`@testable import VoccaSpeech`, the
   `SystemSynthesizer.audioChunk(from:)` precedent).
2. **The family lint**: no `VoccaSpeech/` file outside `Kokoro/KokoroEngine.swift` names
   the Kokoro-runtime family (prefixes: `Kokoro`, `SpeakEvent`, `SynthesisResult`,
   `VoiceStore`, `EnglishG2P`, `BARTG2P`, `Phonemizer`); the permitted file actually
   names it; planted-violation and comment-strip controls pass. The permitted file does
   not `import AVFAudio`/`AVFoundation` (no expected-set amendment) and does not name
   `URLSession`.
3. **The suite entry** (env-gated, runs on the founder's machine): `three-sentence-reply`
   ≥1.0 s + `short-reply` ≥0.25 s; chunks in order, per-chunk duration > 0;
   cancelLatency ≤50 ms wall-clock with no chunk after; re-invoke renders fully.
4. **TTFA** (env-gated): warm run (a warm-up leg first — the port's CoreML compile is a
   prepare fact, never speak latency), measured and printed `KOKORO-TTFA … recorded-never-gated`,
   compared against the system renderer's ~178.8 ms baseline in the record only — never a gate.
5. **The probe**: the Kokoro leg runs inside the interposed process (construct + empty-speak
   + cancel) with zero egress observed; the module-coverage cross-check still passes
   (module unchanged).
6. The floor ratchets with the new tests in the same commit (currently 1949); the ledger
   paragraph is restored.

## Dependencies / sequencing

- After `port-vetting` (the dependency must resolve). Before `provisioning` (the suite's
  real run needs the provisioned models, but the headless pins and lints do not).

## Open questions / risks

- The port's `synthesize` is synchronous; the cancel design must finish the stream from
  `cancel()` without waiting — the suite's cancel leg is the judge (it measures the
  ≤50 ms wall-clock including `cancel()` + `next()`).
- The port's `init` throw mapping: the exact `KokoroError` cases are pinned by the headless
  test against the port's actual error type (read at implementation time).