# Understanding: feat/turn-taking-barge-in

> Deep-dig note for C10 (`CAPABILITY_ROADMAP.md:269-285`), produced 2026-09-15 from the
> card (`docs/planning/_card/issue.md`), four parallel research passes (code map, PRD
> house style, VAD/EOU recorded facts, harness conventions) and one web pass on the
> Silero VAD ecosystem. This is the unit's working understanding; the PRD is the
> binding artifact.

## What the work really is

C10 is the **first P3 capability** — the "smarter than SKI" half of the wedge
(`ROADMAP.md:184-188`). Everything before it earned the right to be here; the
`SpeechSynthesizer` seam with its ≤50 ms cancel contract (`VoccaCore/Speech/`) is the
shipped precondition, and its record explicitly hands off "playback/ducking is C10's
(`VoccaAudio/Playback/`)" (`docs/STATUS.md:96`).

The unit builds **machinery, not surface**: the VAD/TurnDetector/Playback seams with two
implementations each, the barge-in coordinator, the echo gate, the streaming capture
conformance — proven headlessly in CI, env-gated on real audio, and wired into nothing
user-visible. The CONVERSING widget state, dual-mode hotkeys and the injection
prohibition are C11's (`PRODUCT_SPEC.md` §5; ratified in the interview 2026-09-15).

## Affected areas (code map, from the research pass)

| Area | Today | C10 |
|------|-------|-----|
| `VoccaCore/Speech/` | `SpeechSynthesizer`, `AudioChunk`, `VoiceIdentity`, `SentenceChunker` | Untouched (load-bearing inputs) |
| `VoccaCore/SessionMachine.swift` | Synchronous, main-actor-confined dictation machine (no `SessionActor` — the §12 diagram's sketch was rejected) | Pattern precedent for the new turn-taking loop |
| `VoccaAudio/` | Capture only: `MicrophoneSource`, `AudioCaptureGraph`, `AudioRingBuffer` (SPSC), `SpeculativeFeed` | Gains `Playback/` (reserved at `ARCHITECTURE.md:107`), `VAD/` (reserved at `:108`), and a `StreamingCapture` conformance of the existing capture seam |
| `VoccaASR/` | The only module that may import FluidAudio (H8b lint) | Home of the `SileroVAD`/`ParakeetEOU` adapters + the family-lint amendment |
| `VoccaBootstrap/AppBootstrap.swift` | Composition root (3286 lines); probe contract: models never prepared inside `configure` | May gain a recipe (like `kokoroSynthesizer(store:)`), never a user wiring |
| `VoccaNetworkProbe/` | `PROBE-SPEECH` (SpeechDrive) precedent | `PROBE-TURN` drive; the loop's default work over the fallback implementations (zero model bytes, zero network) |
| `Tests/HarnessTests/` | Floor **1978** (`test-with-floor.sh:1639`); family lints; two-variable env gates; parameterized suites | New seam lints, the conversational-set harness, the env-gated real suite |

## Key decisions already made (recorded, not re-litigated)

- **Barge-in signal path** budgeted to the 200 ms gate (`ARCHITECTURE.md:571-578`): VAD
  fires → coordinator receives interrupt → `synthesizer.cancel()` (≤50 ms, shipped
  contract) → ducked and stopped → interrupted reply discarded → capture already running
  so the interrupting words are in the buffer. Capture is continuous, never started at
  interrupt time.
- **Echo rejection** (`ARCHITECTURE.md:573`): known-output reference cancellation, plus a
  hard gate discarding capture whose energy correlates with the synthesizer's output
  within the playback window. Verified on speakers, not headphones (`ROADMAP.md:306`).
  Open question 4 (`ARCHITECTURE.md:727`): may need more than reference cancellation on
  some hardware — budget real time for it. Interview: the deterministic gate + SMOKE
  verification, not full AEC.
- **Turn scoring**: false cutoffs weighted **5× worse** than late commits
  (`ROADMAP.md:211`); hold-to-talk remains available forever as the escape hatch
  (`ARCHITECTURE.md:577-579`) — the dictation machines (hold/toggle) are byte-for-byte
  untouched, and the P0 dictation path never runs VAD in either mode.
- **Seam doctrine** (principle 4): `VoiceActivityDetector` = `SileroVAD` + `EnergyVAD`;
  `TurnDetector` = `ParakeetEOU` + `SilenceThresholdDetector` (`ARCHITECTURE.md:262-263`).
  Seams deliberately separate (the EOU model replaces faster than the VAD).
- **Two-engine instances caution** (`ARCHITECTURE.md:344`): an app switching between
  output-only and input-output configurations may want two engine instances — flagged at
  C9; the playback-time decision is C10's. The voice loop is a separate audio path from
  the dictation rings (one realtime producer per ring; the SPSC warrant holds).

## Research finding that reshaped the card's biggest caveat

The card's nearest feasibility risk — "a Swift port must be vetted as Jud/kokoro-coreml
was" — **largely dissolves**: the Silero VAD ecosystem on Apple Silicon is mature, and
FluidAudio — already a pinned dependency (`from: 0.12.4`, the Parakeet precedent) —
ships Silero VAD itself: `VadManager(config:vadModel:)` with a manually staged CoreML
bundle (`silero-vad-unified-256ms-v6.2.1.mlmodelc` from `FluidInference/silero-vad-coreml`,
offline, no download attempts when the bundle is present — its docs show the exact
staging shape the C2 store already implements). `ROADMAP.md:15` said as much in 2026:
FluidAudio ships "an EOU (end-of-utterance) model, VAD, and diarization behind a Swift
SDK."

What remains **genuinely unverified** and is the vetting gate's job:
1. The SDK's **actual** `VadManager` API surface (recorded at C2 for the batch ASR
   surface only; no EOU/VAD names are recorded in-repo) — verified against the SDK's
   code, not its README (the Misaki-correction precedent).
2. **EOU availability and shape** — if FluidAudio's EOU surface differs from the PRD's
   assumption, the record corrects it; if it is absent, the seam's real implementation is
   pending and the interim state is recorded honestly (the C9 first-half precedent).
3. The **model artifact**: exact release/version, digests pinned from actual bytes,
   manifest in the kokoro-82m.json pattern.
4. The **version pin**: whether `from: 0.12.4` already carries VAD/EOU or needs a bump
   (a CI/dependency decision, reviewable like the Xcode 26 bump).

> **All four closed by the vetting record below (2026-09-15):** the `VadManager` surface is
> verified from the SDK's code, the EOU is present but ASR-integrated (shape correction
> recorded), the artifact's manifest pins digests from actual bytes, and the version pin needs
> no bump (0.15.7 carries the surface).

## Ambiguities resolved in the interview (2026-09-15, founder-ratified)

1. **VAD implementation**: FluidAudio `VadManager` (Parakeet precedent), not a separate
   port. EnergyVAD stays the fallback/test implementation.
2. **Posture**: seam-only, the C9 posture — no activation, no widget state.
3. **Echo depth**: energy-correlation gate + playback-window gating (headless-testable),
   reference cancellation as the second line, speakers verification as a SMOKE step.
4. **Conversational set**: scripted/synthetic corpus + scoring harness (5× false-cutoff
   weight) runs in CI; the founder-recorded human-labelled set is SMOKE 131.

## Open questions carried into the PRD

- FluidAudio's exact VAD/EOU API surface and version coverage (vetting gate, first
  aspect).
- Whether `VadManager`'s hysteresis config (onset/offset/min-speech/min-silence) is
  exposed for headless determinism, or the adapter must wrap it with injectable
  thresholds.
- The loop coordinator's module placement follows the `SessionMachine` precedent
  (VoccaCore, synchronous, owner-isolated, double-injected) — no new architecture is
  invented, but the concrete shape is the plan's.
- The AVFoundation expected-import set gains a reviewed amendment for the playback file
  (the ParakeetEngine precedent).
- SMOKE step numbering: 131+ (129/130 are the TTFA rows).

## Honesty obligations (binding)

- **No P2/P3 gate passes**; the unit builds ahead of uncleared gates with the posture
  named (the kokoro-binding record, not a drift). Turn-commitment, barge-in-halt and echo
  numbers are **recorded, never gated**; SMOKE steps are their only real executions.
- **No user-visible surface ships**; PRODUCT_SPEC's mic-truthfulness principle
  (`PRODUCT_SPEC.md:11`) is preserved by construction — continuous capture is composed
  only in probe/suites until C11 gives it a visible state.
- **The dictation path is untouched**: the hold/toggle machines, ring ownership, the
  ledger and the injection ladder are byte-for-byte inputs, not re-litigations.
- **Zero network**: the VAD/EOU artifacts provision through the C2 store (user-triggered,
  digest-verified, never inside `configure`); nothing hands a URL to any SDK surface; the
  probe drives the fallback implementations.
- **A seam with one implementation is not a seam**: if the EOU is unavailable in the
  pinned SDK, the interim state is recorded and amended later — never papered over.

## Vetting record (sdk-vetting, 2026-09-15)

> The six verification facts, read from the SDK's **code** (not its README — the
> Misaki-correction precedent) in the worktree's own checkout (`.build/checkouts/FluidAudio/`,
> resolved **0.15.7**, revision `41540ea237350afe5117a082b5c28eda642d0612` — NEWER than the
> plan's expected 0.15.5/`19600a485baa4998812e4654b70d2bab8f2c9949`; per the plan's Edge case 2,
> newer + surface verifies → recorded, no bump, no STOP). Each finding: fact → `file:line` →
> verbatim quote.

1. **`VadManager` API shape** — `Sources/FluidAudio/VAD/VadManager.swift`:
   `public actor VadManager` (`:14`); `public static let chunkSize = 4096` (`:22`, "Model expects
   4096 new samples (256ms at 16kHz) plus 64-sample context (total 4160)"), `public static let
   sampleRate = 16000` (`:26`), `public var isAvailable: Bool { return vadModel != nil }`
   (`:30-32`); `process(_:)` overloads over `URL` (`:44`), `AVAudioPCMBuffer` (`:58`), `[Float]`
   (`:74`); THREE public inits — `init(config:progressHandler:)` (`:79-92`, the ModelHub
   download path the app must never take), `init(config:vadModel:)` (`:103-107`, "Initialize
   with pre-loaded model" — the store-compatible staging path), `init(config:modelDirectory:
   progressHandler:)` (`:110-122`, directory staging). **Beta Status doc comment, verbatim
   (`:9-12`):** "**Beta Status**: This VAD implementation is currently in beta. While it performs
   well in testing environments, it has not been extensively tested in production environments.
   Use with caution in production applications." — a finding (adapter risk note), not a blocker.
   Streaming surface: `VadManager+Streaming.swift` — `makeStreamState()` (`:6`),
   `processStreamingChunk(_:state:config:returnSeconds:timeResolution:)` (`:11-17`).
   Segmentation: `VadManager+SpeechSegmentation.swift` — `segmentSpeech(_:config:)` (`:12`),
   `segmentSpeech(from:totalSamples:config:)` (`:22`), `segmentSpeechAudio(_:config:)` (`:55`).
2. **Hysteresis exposure (O6/S1)** — `Sources/FluidAudio/VAD/VadTypes.swift`: `VadConfig`
   (`:4-21`; `defaultThreshold: Float = 0.85`, `debugMode: Bool = false`,
   `computeUnits: MLComputeUnits = .cpuAndNeuralEngine` — all `public var` on a `Sendable`
   struct) and `VadSegmentationConfig` (`:24-91`; `minSpeechDuration 0.15`,
   `minSilenceDuration 0.75`, `maxSpeechDuration 14.0`, `speechPadding 0.1`,
   `silenceThresholdForSplit 0.3`, `negativeThreshold: Float? = nil`,
   `negativeThresholdOffset 0.15`, `minSilenceAtMaxSpeech 0.098`,
   `useMaxPossibleSilenceAtMaxSpeech true`), with
   `effectiveNegativeThreshold(baseThreshold:)` (`:85-90`). **Verdict: hysteresis IS exposed as
   plain `Sendable` data, injectable from the composition root — the
   wrap-with-injectable-thresholds fallback is not needed.** The streaming path consumes it
   per call: `processStreamingChunk` takes `config: VadSegmentationConfig = .default`, and
   `streamingStateMachine` derives the entry/exit pair from it
   (`VadManager+Streaming.swift:44-51`). The `sdk-adapters` aspect must use
   `VadSegmentationConfig` carried as plain data (S1 satisfied by injection, no wrapper).
3. **EOU availability and shape (O2)** — `Sources/FluidAudio/ASR/Parakeet/Streaming/EOU/
   StreamingEouAsrManager.swift`: **PRESENT** at the resolved version.
   `StreamingChunkSize` (`:16-151`; `ms160` default — "Default configuration, well-tested with
   ~8-9% WER on LibriSpeech test-clean", `ms320` `:36`, `ms1280` `:47`; `chunkSamples` 2560/
   10080/20480 `:53-63`). Model files via `ModelNames.ParakeetEOU.requiredModels`
   (`Sources/FluidAudio/ModelNames.swift:643-648` — the plan's `:501-514` line ref was the
   older checkout's; observed here): `streaming_encoder.mlmodelc`, `decoder.mlmodelc`,
   `joint_decision.mlmodelc`, `vocab.json`. **The shape correction, recorded verbatim: the EOU
   is ASR-integrated, not a standalone scored call** — `StreamingEouAsrManager` runs the whole
   Parakeet streaming pipeline (native Swift mel spectrogram → loopback streaming encoder →
   `RnntDecoder.decodeWithEOU`), and EOU is a decoding byproduct: `eouDetected`/`eouCallback`
   (`:201-207`), confirmed via `eouDebounceMs` (default 1280, `:213`) and the pure
   `evaluateEouDebounce` rule (`:300-326`); `eouSignal: decodeResult.eouDetected` (`:660`).
   This differs from the PRD's assumption of a `ParakeetEOU` adapter as a free-standing
   `TurnDetector` implementation — the `sdk-adapters` aspect must plan around
   `StreamingEouAsrManager`'s integrated shape (feed it audio chunks, observe
   `eouDetected`/callback — or record the interim state honestly if the integrated shape is
   unusable as a standalone seam; the C9 first-half precedent). EOU present → no "pending"
   state is recorded now. The conformance decision is `sdk-adapters`', not this gate's.
4. **Version coverage (O1)** — the WORKTREE's own `Package.resolved` after the setup resolve:
   `fluidaudio` → **0.15.7**, revision `41540ea237350afe5117a082b5c28eda642d0612` (the plan's
   fallback record of 0.15.5/`19600a48...` is the primary checkout's value from earlier in the
   day; 0.15.7 resolved from the same `from: "0.12.4"` range). The resolved sources carry
   findings 1-3 → the pinned range ALREADY carries the VAD/EOU surface → **no bump**;
   `Package.swift:36` untouched. `0.x` semantics: a future 0.16+ resolves silently under
   `from: "0.12.4"` (minor is breaking) — a silent update surfaces in the pin family and the
   sdk-adapters suite (the kokoro precedent, Edge case 7).
5. **The VAD model artifact** — `Sources/FluidAudio/ModelNames.swift:622-630`:
   `public enum VAD { public static let sileroVad = "silero-vad-unified-256ms-v6.2.1"`,
   `sileroVadFile = sileroVad + ".mlmodelc"`, `requiredModels: Set<String> = [sileroVadFile]`;
   repo `case vad = "FluidInference/silero-vad-coreml"` (`:5`). Staging shape from
   `Documentation/VAD/GettingStarted.md:37-78`: the `.mlmodelc` **DIRECTORY** staged anywhere,
   handed to `VadManager(config:vadModel:)`; **verbatim `:78`:** "Use `FileManager` to confirm
   the `.mlmodelc` directory exists before constructing the manager. When the bundle is
   present, no fallback download attempts occur." Two sub-checks: (a) **bundled? NO** — no
   `.mlmodelc` anywhere in the SDK checkout; the download init goes through ModelHub
   (`VadManager.swift:124-147`, default base `~/Library/Application Support/FluidAudio/Models`
   `:149-154`) → the adapter must use the pre-loaded init + the C2 store, never the download
   init. (b) **32 ms variant? UNREFERENCED** in `Sources/` (grep empty); the only `32ms`
   mention is `Documentation/Benchmarks.md:314` prose ("8 chunks of 32ms" describing the batch
   processing of the 256 ms model) — not a model name. Only the 256 ms unified model is named
   at v6.2.1. **Observation:** the resolved SDK also ships an FSMN-VAD
   (`Sources/FluidAudio/VAD/Fsmn/FsmnVadManager.swift`, `ModelNames.swift:513`, repo
   `FluidInference/fsmn-vad-coreml`) — a second VAD family outside this unit's ratified pick;
   recorded for the adapter aspect's awareness, not a re-pick. The HF repo
   `FluidInference/silero-vad-coreml` ships the artifact as a **bare `.mlmodelc` directory**
   (five files: `analytics/coremldata.bin`, `coremldata.bin`, `metadata.json`, `model.mil`,
   `weights/weight.bin` — no tarball), so the manifest follows the SDK-shaped per-file pattern
   of `parakeet-tdt-0.6b-v3.json`, not the kokoro tarball shape.
6. **License** — the SDK's own `LICENSE` re-verified **Apache-2.0** in the worktree checkout
   (first lines verbatim: "Apache License / Version 2.0, January 2004 /
   http://www.apache.org/licenses/"). The artifact repo `FluidInference/silero-vad-coreml`:
   HF card metadata `license:mit` (`cardData.license` via the HF model API, 2026-09-15),
   README "**License:** MIT", parent model `snakers4/silero-vad` (MIT). **However, the repo
   carries NO LICENSE file** (the HF tree lists only `.gitattributes`, `README.md`,
   `config.json`, `graphs/`, model directories) — the plan's Edge case 4 partial: MIT is
   claimed by card metadata + README but is not verifiable from a repo LICENSE. **Surfaced to
   the integrator, not silently absorbed** (STOP-condition-class item; see the aspect report).
7. **Toolchain** — the SDK's `Package.swift` declares `// swift-tools-version: 6.0` and
   `platforms: [.macOS(.v14), .iOS(.v17)]` (also carries `Package@swift-6.2.swift` for newer
   toolchains): matches our 6.0, below our `.v15` — **no CI toolchain change, no platform
   bump**, as planned.

**The version-pin decision:** no bump. The resolved **0.15.7** (revision
`41540ea237350afe5117a082b5c28eda642d0612`) carries the full VAD/EOU surface under the
existing `from: "0.12.4"` range (`Package.swift:36`); `Package.resolved` stays gitignored (the
revision is a RECORDED fact, not a committed pin).

**The manifest** (`Sources/VoccaASR/Models/Manifests/silero-vad.json`): `engineID
"silero-vad"`, `version "1"`, `sdkDirectory "vad"`, five per-file entries under
`silero-vad-unified-256ms-v6.2.1.mlmodelc/`, digests + byte counts computed from the ACTUAL
provisioned bytes (`Scripts/provision-vad-fixtures.sh`, run 2026-09-15, each file also
cross-checked against the repo's declared content identity). Staging layout for the next
aspect's env-gated suite: `<root>/silero-vad/1/vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/`,
verified marker at `<root>/silero-vad/1/verified`, `VOCCA_MODEL_DIR=<root>`.