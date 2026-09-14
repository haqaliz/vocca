# Understanding: kokoro-binding (implementation unit)

> Phase 2 dig note. Source: `docs/planning/_card/issue.md` (the merged PRD-gate card) +
> three read-only mapping agents (seam surface, provisioning/composition, test/lint harness)
> + direct verification of the port's actual code (`Jud/kokoro-coreml` @ main, 2026-09-14).

## What this work really is

Land **Kokoro-82M** as the second real `SpeechSynthesizer` implementation (C9's second
half). The runtime decision is already made and ratified (CoreML/ANE via a Swift port,
DI from the composition root, one voice af_heart). The unit's first step is the **vetting
gate** — and the dig has largely executed it against the port's real code. Everything below
that contradicts the merged PRD is a **recorded correction**, not a drift.

## The seam surface (what the binding must conform to)

- `SpeechSynthesizer` (`Sources/VoccaCore/Speech/SpeechSynthesizer.swift:42-59`):
  `identity: VoiceIdentity`, `speak(_:) -> AsyncThrowingStream<AudioChunk, Error>`,
  `cancel() async`; contract: chunks in sentence order, empty text → empty stream,
  cancel halts ≤50 ms with no chunk after, cancel-then-reinvoke safe. Engine key
  `"kokoro-82m"` is already the seam's vocabulary (`:43`).
- `AudioChunk` (`AudioChunk.swift:29-47`): `bytes: [UInt8]`, `sampleRate: Double`,
  `channelCount: Int`, `duration: Double` — PCM format is the producer's contract.
- `VoiceIdentity` (`VoiceIdentity.swift:24-34`): `engineID` + `voiceName: String?`
  (`"af_heart"`).
- `SentenceChunker` (`SentenceChunker.swift:40`): the chunker the binding must use
  (or the port's own — see below).
- `SystemSynthesizer` (`Sources/VoccaSpeech/System/SystemSynthesizer.swift`): the
  template — one render per sentence chunk, generation-tagged flag cancel (never call
  the renderer's stop API — stale output is dropped by generation, `:57-61`),
  `onTermination` cancels the producer task (`:109-111`), init pure (`:94-99`).

## The suite (how the binding proves itself)

- Shared body `SpeechFixtureSuite.evaluate(_:fixtures:)`
  (`Tests/HarnessTests/SpeechFixtureSuite.swift:62`): three legs per instance — full
  render, cancel after one chunk of a second speak (≤50 ms wall-clock measured from
  before `cancel()` to `next()` returning nil), full re-invoke.
- Real-engine suite shape: `SpeechSystemSuiteTests` (`Tests/HarnessTests/`), env-gated
  on `VOCCA_RUN_REAL_SPEECH` presence (`:57-61`), fixtures `three-sentence-reply`
  (≥1.0 s) + `short-reply` (≥0.25 s), per-chunk duration > 0, TTFA row printed
  `SPEECH-TTFA ... recorded-never-gated` (`:116-118`). Kokoro mirrors this in its own
  class (`SpeechKokoroSuiteTests` shape); CI runs the skip path (skips still count in
  the executed tally).
- Headless pins in the `SystemSynthesizerTests` shape + the seam pins in
  `SpeechSynthesizerSeamTests` (identity, empty, order, cancel, re-invoke).
- Probe: `Sources/VoccaNetworkProbe/SpeechDrive.swift:86-114` drives
  construct → empty-speak → cancel; `ZeroNetworkTests` module-coverage cross-check
  (`:1449-1476`) requires every `Sources/` module to be driven. **Kokoro stays inside
  `VoccaSpeech`** — a new module would fail the suite until driven.

## The vetting gate — executed against the port's code (2026-09-14)

**The port exists and is structurally viable.** `Jud/kokoro-coreml` (10 stars, 66
commits, Apache-2.0 — LICENSE verified verbatim; product `KokoroCoreML`; latest
v0.11.2; `platforms: [.macOS(.v15)]`; **`swift-tools-version: 6.2`**).

1. **Init accepts a model directory** — `public init(modelDirectory: URL, phonemizer: any Phonemizer? = nil, forceCPU: Bool = false) throws`
   (`KokoroEngine.swift:168-201`): guards `ModelManager.modelsAvailable` (file check —
   **no network**), **throws** `modelsNotAvailable` when absent (it does NOT
   auto-download), loads tokenizer + `VoiceStore`, then spawns a background warmup
   thread. The downloader (`ModelDownloader.swift`) is only reachable through the
   explicit public static `KokoroEngine.download(to:)` — **never called by the
   library's init/speak paths**; `isUpToDate`/`latestModelTag` are dead code in the
   library. **Zero-network library by construction.**
2. **Per-sentence synchronous synthesis** — `synthesize(text:voice:speed:) ->
   SynthesisResult` (`samples: [Float]` 24 kHz mono, `duration`, `realTimeFactor`)
   (`KokoroEngine.swift:206-216`, `:1224-1263`). This is the PRD's R1b guaranteed
   cancel path, verbatim: one call per `SentenceChunker` sentence, cancel between
   calls, stale results discarded by generation. ~100 ms per chunk (README) — so the
   **≤50 ms halt contract requires cancel to terminate the stream without waiting for
   the in-flight call** (finish the continuation from `cancel()`, drop the orphaned
   result by generation; the SystemSynthesizer shape). The port's streaming
   `speak() -> AsyncStream<SpeakEvent>` (`:1070-1186`, `.audio(AVAudioPCMBuffer)`)
   is NOT needed and its AVFAudio surface is deliberately avoided (see lints).
3. **Phonemization is NOT Misaki — a recorded correction.** The port bundles its own
   English G2P (`Sources/KokoroCoreML/G2P/`: `EnglishG2P.swift`, `Lexicon.swift`,
   `EnglishNum2Word.swift`, `PennTagUtil.swift`; resources `us_gold.json` /
   `us_silver.json`, ~3 MB each, `.process("Resources")`) with a neural fallback via
   `Jud/swift-bart-g2p` (`BARTG2P`, Apache-2.0 — same LICENSE blob; models bundled in
   package resources: `bart_g2p.safetensors` 3 MB + reranker; **no runtime download**).
   The PRD/understanding's "Misaki (hexgrad's G2P) replaces espeak-ng" claim is
   wrong for this port; the record must say what the port actually does.
4. **Model artifact** — `kokoro-models.tar.gz` on GitHub Releases, `models-2026-03-23`
   (three `models-*` releases exist; the port picks the first, newest). Contains
   `kokoro_frontend.mlmodelc`, `kokoro_backend.mlmodelc`, `voices/` (binary .bin
   voices incl. af_heart), and `vocab_index.json` (verified shape at provisioning
   time). **One tarball** — unlike the ASR manifests' per-file entries: the manifest
   pins the tarball (digests from the ACTUAL provisioned bytes) and the bootstrap
   extracts idempotently (`/usr/bin/tar xzf`), then points the engine at the
   extracted directory. The store's `sdkDirectory` field does not extract; the
   extraction is bootstrap-side.
5. **Toolchain blocker — CI cannot build the dependency today.** Both the port and
   its BART dependency declare `swift-tools-version: 6.2`; Vocca CI is pinned to
   `XCODE_MAJOR: 16` (`.github/workflows/ci.yml:58`, Swift 6.0/6.1) → resolution
   fails. Local toolchain: Swift 6.3.3 (Xcode 26.6) — fine. **CI must move to
   Xcode 26.x** (verify availability on the macos-15 runner at plan time) or the
   dependency cannot land. This is a deliberate, reviewable CI edit.

## The integration points (from the mapping agents, file:line)

- **Package.swift**: add `.package(url: "https://github.com/Jud/kokoro-coreml.git",
  from: "0.8.0")` (port README; pin decision at plan time) after `:36`; add
  `.product(name: "KokoroCoreML", package: "kokoro-coreml")` to the `VoccaSpeech`
  target's dependencies (`:114-118`); add `"VoccaSpeech"` to the `VoccaBootstrap`
  target's dependencies (`:139-152`). Tools-version of OUR package stays 6.0.
- **`VoccaSpeech/Kokoro/KokoroEngine.swift`** (the one file): `identity.engineID ==
  "kokoro-82m"`, `voiceName` from plain data; **init pure-local** (no port-engine
  construction — that is a model load; the port's init does file IO + spawns a
  warmup thread); lazily construct the port engine on first `speak` (a prepare step
  at launch is the ASR warm-start parallel); empty-speak short-circuits before any
  port touch; per-sentence `synthesize` loop; generation-tagged flag cancel that
  finishes the stream without waiting for the in-flight call; safe re-invoke.
- **Provisioning (VoccaBootstrap, NOT VoccaSpeech — adapter rule)**: the EngineTier-
  closed `ShippedModelManifest.load(for:)` switch must NOT grow
  (`Sources/VoccaASR/Models/ShippedModelManifest.swift:48-50`, `:62-69`); a parallel
  string-keyed loader + `Sources/VoccaASR/Models/Manifests/kokoro-82m.json` rides the
  existing `.copy("Models/Manifests")` resource (`Package.swift:78`); `VoccaBootstrap`
  provisions via `ModelStore.downloadIfMissing(manifest:transport:)` (string-keyed
  surface, `ModelStore.swift:236-262`) + extracts + computes the directory
  (the `ParakeetEngine.loadDirectory()` pattern, `ParakeetEngine.swift:175-178`) +
  constructs `KokoroEngine(modelDirectory:voice:rate:)`. **Launch-only** — never in
  `AppBootstrap.configure`'s body (probe contract, `AppBootstrap.swift:2296-2304`).
  Repository constant beside `AppBootstrap.swift:838-845`, NOT the closed
  `repositoryURL(for:)` switch. **Store single-flight slot is not per-manifest**
  (`ModelStore.swift:244-247`): a TTS provision racing the ASR download silently
  skips — sequence TTS after ASR preparation.
- **Zero-network**: the port's `download()` static is never called — the family lint
  + the probe pin it; `DefaultModelTransport` is the only URLSession file (reused,
  no new one); BART G2P models are bundled (verified — no download surface).
- **Lints**: new Kokoro-runtime family lint in the `SpeechSeamBoundaryTests` shape
  (one permitted file `Kokoro/KokoroEngine.swift`, planted-violation + comment-strip
  controls, port identifier prefixes); **no AVFoundation row needed** — the binding
  uses `SynthesisResult.samples: [Float]`, never `SpeakEvent.audio(AVAudioPCMBuffer)`,
  so no AVFAudio import and no expected-import-set amendment; the AVSpeech/AVAudio
  family stays confined to `System/SystemSynthesizer.swift`
  (`SpeechSeamBoundaryTests.swift:75-83`).
- **Digest verification gap**: `testEveryShippedManifestMatchesTheProvisionedBytes`
  loops `EngineTier.allCases` (`ManifestDigestVerificationTests.swift:296`) — the TTS
  manifest needs its own verification row for "digests pinned in-repo" to hold.
- **Floor**: `Scripts/test-with-floor.sh:1569` — `MINIMUM_EXECUTED_TESTS=1949`; every
  new test ratchets it in the same commit (and the ledger paragraph pattern should be
  restored — the last raise's ledger entry is missing).
- **SMOKE_CHECKLIST.md:2722-2740** (step 129): the Kokoro TTFA row becomes step 130,
  same 4-part format, `KOKORO-TTFA` line, recorded-never-gated; the system renderer's
  ~178.8 ms baseline is the comparison.

## Ambiguities / open questions

- **CI Xcode bump**: `XCODE_MAJOR 16 → 26` — verify Xcode 26.x exists on the
  macos-15 runner image at plan time; the bump is in scope for this unit (the
  dependency cannot build otherwise). Alternatives (vendoring/forking with a lowered
  tools-version) are worse and not recommended — they fork the trust boundary the
  vetting gate is meant to pin.
- **Version pin**: `from: "0.8.0"` (README) vs exact/upToNextMinor — the port is
  young; pin policy decided at plan time (a moved dependency under us is a silent
  behavior change; the digests pin the model, not the code).
- **Extraction idempotency**: the tarball downloads once (store marker); extraction
  must be idempotent and marker-guarded (temp dir + rename, or extract-if-absent) —
  plan detail, test-first.
- **First-speak warm cost**: CoreML model compile is a prepare fact, never speak
  latency (PRD G4); the bootstrap should prepare the Kokoro engine at launch like
  ASR (`prepareAndAssemble`, `AppBootstrap.swift:2372-2414`).
- **Cancel semantics**: finish-the-stream-from-cancel vs wait-for-in-flight — the
  ≤50 ms contract forces the former; pinned in the plan, asserted by the suite.
- **TTFA comparison**: SMOKE 129's ~178.8 ms is the system renderer's; Kokoro's row
  is measured warm, recorded, never gated.

## Honesty obligations (binding)

- The P2 and P3 gates stay uncleared; the unit builds ahead of them (the recorded
  posture, `docs/STATUS.md:110-111`). TTFA stays recorded, never gated.
- The record must name the **Misaki correction** and the **tools-version/CI bump**
  as findings of the vetting gate, cited against the port's code — not as vibes.
- The dependency's license + the model bytes' digests are pinned before merge (C2
  provenance discipline); digests are generated from the ACTUAL provisioned bytes,
  never copied from the port's README.