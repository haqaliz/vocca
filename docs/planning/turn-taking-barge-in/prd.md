# PRD: turn-taking-barge-in (C10 — the P3 voice loop's turn-taking + barge-in)

> Source card: `docs/planning/_card/issue.md` (inline brief, 2026-09-15; no GitHub issue
> exists). Understanding: `docs/planning/_card/understanding.md`. Four founder decisions
> ratified 2026-09-15 at the requirements interview: **FluidAudio `VadManager`** as the
> real VAD implementation (the Parakeet precedent — the dependency is already pinned, no
> new package), **seam-only posture** (no user-visible surface; the CONVERSING widget
> state and dual mode are C11's), **echo gate + SMOKE** (energy-correlation gate and
> playback-window gating fully headless; the on-speakers truth is a SMOKE step, never
> full AEC), **scripted CI corpus + founder-recorded real set** (the ≥95% turn-commitment
> harness runs in CI over a scripted corpus; the human-labelled real set is SMOKE 131).

## Problem Statement

Vocca can dictate, and now it can *render* speech (`SpeechSynthesizer`, C9 complete) —
but it cannot **talk back**. The wedge's second half ("smarter than SKI",
`ROADMAP.md:186`) needs a loop that knows when a person has *finished a turn* — which is
not the same as when they stopped making noise (`CAPABILITY_ROADMAP.md:271`) — and that
can be **interrupted mid-reply** without feeling broken. Neither exists: there is no
`VoiceActivityDetector`, no `TurnDetector`, no playback path, no ducking, and no
barge-in coordinator anywhere in `Sources/` — `VoccaAudio/Playback/` and
`VoccaAudio/VAD/` are reservations on paper (`ARCHITECTURE.md:107-108`), and the
`SpeechSynthesizer` ≤50 ms cancel contract — "a barge-in that leaks the tail of the
utterance is a barge-in that does not work"
(`Sources/VoccaCore/Speech/SpeechSynthesizer.swift:37-38`) — has no consumer.

The P3 exit gate (`ROADMAP.md:215-219`) — a full spoken exchange with barge-in, keyboard
untouched — is structurally unreachable until this unit ships. Everything downstream
(C11 dual mode, C13 actions) composes on top of this loop. And the two risks the
roadmap registers for this phase are both high-impact: **R6** (endpointing false
cutoffs, the "cut me off mid-sentence" failure — High/High) and **R7** (barge-in echo,
the mic transcribing Vocca's own voice — the zero-tolerance metric). The unit is the
first realtime-path change since C1 (`_card/issue.md:52-53`), so it ships as machinery
with the recorded posture: no gate passes, no user-visible surface, numbers recorded
never gated.

## Goals & Success Metrics

- **G1 — Two new seams with two real implementations each.** `VoiceActivityDetector`
  (`SileroVAD` + `EnergyVAD`) and `TurnDetector` (`ParakeetEOU` +
  `SilenceThresholdDetector`) per the seam table (`ARCHITECTURE.md:262-263`); the seams
  are deliberately separate because the EOU model replaces on a faster cycle than the
  VAD (`CAPABILITY_ROADMAP.md:282`). The doctrine (ROADMAP principle 4) is satisfied at
  ship, or its interim state is recorded honestly and amended later — never papered over
  (the C9 first-half precedent).
- **G2 — Barge-in halt within the 200 ms gate.** The composed loop, driven by a
  scripted user-speech injection during synthetic playback, halts output within
  **≤200 ms** of speech detection (`ROADMAP.md:210`), discards the interrupted reply
  cleanly, and the interrupting audio is fully preserved — the buffered words are
  already in the capture, which is continuous and never started at interrupt time
  (`ARCHITECTURE.md:571-578`). Measured headlessly over the injected clock; the real
  measurement is a SMOKE row, recorded never gated.
- **G3 — Echo rejection: the deterministic half ships, the speakers half is SMOKE.**
  The hard gate that discards capture whose energy correlates with the synthesizer's own
  output within the playback window (`ARCHITECTURE.md:573`) is built and headlessly
  proven (synthetic overlapped signals); known-output reference cancellation rides as
  the second line; **0 instances of Vocca transcribing its own output**
  (`ROADMAP.md:212`) is verified on speakers as SMOKE 133 — never a CI number.
- **G4 — Turn-commitment scoring with the 5× weighting, runnable in CI.** The
  conversational-set harness scores correct turn commitment at **≥95%**
  (`ROADMAP.md:211`) with **false cutoffs weighted 5× worse than late commits**
  (`ARCHITECTURE.md:575`); it runs in CI over a scripted/seeded corpus with
  human-labelled boundaries transcribed into a fixture format, and over the
  founder-recorded real set as SMOKE 131 — recorded, never gated.
- **G5 — The dictation path is untouched.** Hold-to-talk remains available forever as
  the escape hatch (`ARCHITECTURE.md:577-579`); the hold/toggle machines, the ring
  ownership handover, the ledger and the injection ladder are byte-for-byte inputs, not
  re-litigations. Pinned by a byte-level or source-scan guard that the dictation files
  did not change shape.
- **G6 — Zero-egress, zero model bytes in the probe.** The loop's default work in the
  zero-network probe runs over the fallback implementations (`EnergyVAD`,
  `SilenceThresholdDetector`) — no model artifact, no SDK, no network. The real
  implementations' artifacts provision through the C2 store (download → verify →
  marker, digests pinned from actual bytes, the kokoro-82m.json pattern), never inside
  `configure` (the probe contract).

## User Personas & Scenarios

- **The barge-in consumer (the future C11/C13 user).** A person in a conversation with
  Vocca who interrupts mid-reply. The reply ducks and stops within 200 ms; the
  interrupting words were captured from the first syllable (continuous capture); the
  interrupted reply is discarded cleanly. What they must never feel is the tail of the
  reply leaking over their words, or their first syllable being eaten.
- **The endpointing pessimist (R6's victim today).** Someone burned by a voice tool that
  "cut me off". The loop prefers a late commit over a false cutoff by a 5× margin, and
  hold-to-talk remains as the ground-truth escape hatch.
- **The privacy auditor.** The widget always tells the truth about the microphone
  (`PRODUCT_SPEC.md:11`). Because this unit wires no user-visible surface, no silent
  listening state exists: continuous capture is composed only in the probe and the
  env-gated suites until C11 gives it a visible state. This is a requirement, not a
  side effect.
- **The next capability (C11 dual mode).** The loop is the substrate: C11 adds the
  visible CONVERSING surface, the second hotkey and the mode machine on top of this
  unit's machinery (`CAPABILITY_ROADMAP.md:288-302`).

## Requirements

### Must-have

- **R1 (sdk-vetting gate — the unit's first aspect, facts pinned in the first commit):**
  FluidAudio's actual VAD/EOU surface verified against the SDK, not its README (the
  Misaki-correction precedent): the `VadManager` API shape (model staging, config,
  hysteresis), the EOU model's availability and shape, and whether the pinned
  `from: 0.12.4` already carries them or needs a version bump (a reviewable
  CI/dependency decision like the Xcode 26 bump). The model artifact: exact release,
  digests pinned from the **actual** provisioned bytes, manifest in the C2-store pattern.
  Corrections recorded verbatim in `_card/understanding.md`; a provenance/manifest pin
  test RED first. **If the EOU surface differs from the PRD's assumption, the record
  corrects it; if the EOU is absent, `TurnDetector`'s real implementation is pending and
  the interim state is recorded honestly — never a fabricated conformance.**
- **R2 (`VoiceActivityDetector` seam):** frame-level speech/silence decision over
  `AudioBuffer` chunks, `SileroVAD` (FluidAudio adapter) + `EnergyVAD` (pure,
  headless, in the core) behind it. Deterministic contract tests: known speech/silence
  fixtures classify correctly; the seam never names an engine; callers never branch on
  implementation.
- **R3 (`TurnDetector` seam):** turn-commitment decision on a candidate pause,
  `ParakeetEOU` (FluidAudio adapter) + `SilenceThresholdDetector` (pure, headless)
  behind it. The commitment is a scored decision with a threshold, not a silence
  timer alone (`CAPABILITY_ROADMAP.md:275`); below threshold keep listening, above
  threshold commit.
- **R4 (streaming capture):** a `StreamingCapture` conformance of the existing capture
  seam — continuous capture that never releases the device, yielding a chunk stream for
  the voice loop — owned separately from the dictation rings (the SPSC warrant holds;
  one realtime producer per ring, `AudioRingBuffer.swift:60-68`). The dictation
  `MicrophoneSource` path is byte-for-byte untouched. Headless over the capture graph
  seam (the `MicrophoneSource` test precedent); the realtime conversation itself is
  executed by nothing in CI (the tap-adapter precedent) — the decisions above the seam
  are tested there.
- **R5 (playback + ducking):** the `PlaybackEngine` seam (chunk stream → output,
  duckable, cancel-to-silence within the barge-in budget) with an `AVAudioEngine`-based
  implementation in `VoccaAudio/Playback/` — the reserved directory
  (`ARCHITECTURE.md:107`) gains its first file, and the AVFoundation expected-import set
  gains the reviewed amendment (the ParakeetEngine precedent). Ducking is a first-class
  operation: the level ramps down before cancel completes so the halt is a duck, not a
  click.
- **R6 (the barge-in loop):** a `TurnTakingLoop` coordinator (the `SessionMachine`
  precedent: VoccaCore, synchronous, owner-isolated, seams injected as plain data and
  closures). States: listening (continuous capture + VAD) → uttering (speech
  accumulating) → committed (EOU fires) → reply scheduled → playing (ducked, cancellable)
  → barge-in (VAD speech during playback → `synthesizer.cancel()` ≤50 ms + duck → reply
  discarded → listening, interrupting words preserved). The ≤50 ms contract is consumed,
  not re-litigated.
- **R7 (the echo gate):** the hard gate discarding capture whose energy correlates with
  the synthesizer's output within the playback window (`ARCHITECTURE.md:573`), plus
  known-output reference cancellation as the second line. Pure and headless-testable:
  synthetic overlapped signals gate deterministically; silence during playback never
  gates.
- **R8 (the acceptance harness):** the conversational-set scorer with the 5× false-cutoff
  weight, running over a scripted corpus in CI (seeded fixtures with labelled turn
  boundaries; a planted false-cutoff genuinely fails — a gate that cannot fail proves
  nothing) and over the founder-recorded set as SMOKE 131; the barge-in acceptance
  (halt ≤200 ms + interrupting audio fully captured) headless over the injected clock;
  the echo acceptance (loopback, zero transcription) headless at the gate level.
- **R9 (composed, honest wiring):** the probe drives the loop's default work over the
  fallback implementations (`PROBE-TURN`, the `SpeechDrive` shape); the env-gated real
  suite follows the two-variable gate pattern (`VOCCA_*`); nothing user-visible is
  wired; the floor (1978) ratchets with the unit's first commit's tests.

### Should-have

- **S1 — VAD hysteresis configuration** (onset/offset thresholds, min-speech/min-silence)
  carried as plain data from the composition root, injectable per the SDK's actual
  surface (recorded at R1), so the real and fallback implementations can be tuned
  together in the env-gated suite.
- **S2 — A replayable corpus format** for the conversational set (audio + labelled
  boundaries + expected commitments), committed as fixtures so the founder's SMOKE 131
  recording can be added without changing the harness.

### Nice-to-have

- **N1 — A widget-independent "speaking" indicator hook** (a state-change callback on the
  loop) that C11's surface can consume — present in the loop, wired by nothing.
- **N2 — Playback-volume duck level as a knob** (plain data, default -6 dB-ish ramp),
  so C11 can tune it without touching the loop.

## Technical Considerations

- **Phase/layer:** P3 (`ROADMAP.md:184-221`); voice-loop layer. The unit builds ahead of
  the uncleared P2/P3 gates with the posture named (`_card/issue.md:46-49`), matching
  the kokoro-binding record. No capability from C9 onward is blocked on this unit's gate
  status.
- **Module map (unchanged rules, new files):** seams + `EnergyVAD` +
  `SilenceThresholdDetector` + the loop + the echo gate in `VoccaCore` (imports
  nothing); the FluidAudio adapters in `VoccaASR` (the only module that may import
  FluidAudio — the H8b lint gains the VAD/EOU family amendment with planted-violation +
  comment-strip controls, the `KokoroSeamBoundaryTests` shape); playback in `VoccaAudio`
  with the AVFoundation expected-set reviewed amendment; composition recipe in
  `VoccaBootstrap` (never inside `configure`); `PROBE-TURN` in `VoccaNetworkProbe` with
  the module-coverage cross-check updated.
- **Privacy:** zero-egress by construction — no URL is ever handed to any SDK surface
  (the port-downloader-suppression pin precedent); artifacts provision via the C2 store;
  the probe's settle window and interposer cover the loop's default work; the
  mic-truthfulness principle (`PRODUCT_SPEC.md:11`) is preserved because no silent
  listening state exists in the app.
- **Latency budget:** the 200 ms barge-in gate decomposes as VAD frame (~30 ms) →
  coordinator → `cancel()` (≤50 ms) → duck → silence, with capture already running
  (`ARCHITECTURE.md:571`). Headless assertions run over the injected clock; real
  numbers are SMOKE rows.
- **Dependencies:** FluidAudio stays the only ASR-adjacent dependency; a version bump
  may be required by R1 (reviewable). The dictation path, the ring SPSC warrant, the
  injection ladder and the ledger are inputs, not re-litigations.
- **CI edits:** the expected-import set amendment, the H8b family amendment, the probe
  coverage cross-check, the floor ratchet — each in the same commit as the tests it
  counts.
- **Floor:** 1978 (`Scripts/test-with-floor.sh:1639`), ratcheted per aspect in the same
  commit; the env-gated suite's visible skips count as executed.
- **SMOKE:** 131 (real conversational set + turn commitment), 132 (real barge-in halt on
  real playback), 133 (echo rejection on speakers) — appended after step 130, each a
  recorded-never-gated row with the state-entered check.

## Risks & Open Questions

| # | Risk / Question | Tie | Mitigation |
|---|-----------------|-----|------------|
| O1 | **FluidAudio's actual VAD/EOU surface differs from the PRD's assumptions** (no SDK VAD/EOU names are recorded in-repo; only the batch ASR surface was spiked at C2) | R1 | The vetting gate is the first aspect; corrections recorded verbatim, the Misaki precedent. **RESOLVED (sdk-vetting, 2026-09-15): no bump — the resolved 0.15.7 (revision `41540ea237350afe5117a082b5c28eda642d0612`) already carries the full VAD/EOU surface under the pinned `from: "0.12.4"`; the surface is verified from the SDK's code and recorded in `_card/understanding.md`.** |
| O2 | **The EOU model is absent or unpinned in the SDK** — `TurnDetector`'s real implementation would be pending | R1/R3 | Interim state recorded honestly (C9 first-half precedent); `SilenceThresholdDetector` ships as the second implementation either way. **RESOLVED (sdk-vetting, 2026-09-15): EOU is PRESENT at 0.15.7 but ASR-integrated** — `StreamingEouAsrManager` runs the Parakeet streaming pipeline and EOU is a decoding byproduct (`eouDetected`/callback), not a standalone scored call; the `sdk-adapters` aspect must plan around that shape (feed audio chunks, observe the EOU signal — or record the interim state honestly if the integrated shape is unusable as a standalone seam). No "pending" state recorded now. |
| O3 | **Echo rejection on speakers may need more than reference cancellation on some hardware** (`ARCHITECTURE.md:727`) | R7 | The deterministic gate ships; SMOKE 133 verifies on speakers and records the truth, never a claim |
| O4 | **Realtime coexistence**: playback and capture in one process is new (the two-engine-instance caution, `ARCHITECTURE.md:344`) | R4/R5 | Separate audio paths, the SPSC warrant per ring; the realtime conversation is env-gated/SMOKE-only by the tap-adapter precedent |
| O5 | **The 200 ms gate headroom** — the composed path must fit cancel (≤50 ms, measured 70-90 ms on a loaded CI runner for the stub) + duck + VAD frame | R6 | The headless assertions run over the injected clock at the *contract* thresholds; the real row is SMOKE 132, never a CI gate |
| O6 | **`VadManager` hysteresis surface** may not be injectable for headless determinism | S1 | The adapter wraps it with injectable thresholds (recorded at R1); EnergyVAD stays fully deterministic either way. **RESOLVED (sdk-vetting, 2026-09-15): hysteresis IS exposed as plain `Sendable` data** — `VadSegmentationConfig` (min/max durations, `negativeThreshold`/`negativeThresholdOffset`, `effectiveNegativeThreshold(baseThreshold:)`) injectable from the composition root; the wrap-with-injectable-thresholds fallback is not needed. The `sdk-adapters` aspect must use `VadSegmentationConfig` carried as plain data. |

## Out of Scope

No user-visible surface; no CONVERSING widget state, no dual mode, no second hotkey
(C11); no agent/reply generation (C13); no actions; no VAD or endpointing in the
dictation path (P0 machines untouched, `ROADMAP.md:74`); no toggle-gap closure
(unassigned, `session-lifecycle/spec.md:102-113`); no full acoustic echo cancellation
beyond the gate + reference lines; no EOU beyond turn commitment (no diarization, no
speaker labeling); no transcript surface for replies (`PRODUCT_SPEC.md:379` is C11/C13's
question); no converse-mode ledger folding (dictation outcomes only).

---
## Aspect decomposition

| Aspect | Boundary |
|--------|----------|
| `sdk-vetting` | The unit's first aspect and first commit: FluidAudio's VAD/EOU surface verified against the SDK (API shape, staging, hysteresis, EOU availability, version coverage), corrections recorded in `_card/understanding.md`, the manifest + digests from actual bytes, any version bump, the provenance pin RED first. |
| `voice-detection` | The `VoiceActivityDetector` + `TurnDetector` seams (VoccaCore), `EnergyVAD` + `SilenceThresholdDetector` (pure, headless), the deterministic contract tests, the seam lints, the floor ratchet. |
| `sdk-adapters` | `SileroVAD` + `ParakeetEOU` (FluidAudio adapters, VoccaASR, one file per seam), the H8b family amendment (planted-violation + comment-strip), the env-gated real suite (two-var gate), the probe's construct leg (no model bytes). |
| `streaming-capture` | The `StreamingCapture` conformance (VoccaAudio): continuous capture, chunk stream, ownership contract, headless over the capture-graph seam, dictation path byte-for-byte untouched. |
| `playback-ducking` | The `PlaybackEngine` seam (VoccaCore) + the AVAudioEngine implementation (VoccaAudio/Playback/), ducking as a first-class operation, the AVFoundation expected-set reviewed amendment, the family lint. |
| `barge-in-loop` | The `TurnTakingLoop` coordinator (VoccaCore), the echo gate + reference-cancellation line, the conversational-set harness with the 5× weighting + scripted corpus, the composed headless acceptance (200 ms halt, interrupting audio preserved, echo zero), `PROBE-TURN`, the env-gated composed suite. |
| `record` | SMOKE steps 131-133, the STATUS/CLAUDE.md/ARCHITECTURE.md sync, the floor, the honesty block. |

Sequencing: `sdk-vetting` first (facts the adapters and the loop need), then
`voice-detection` → `sdk-adapters` → `streaming-capture` + `playback-ducking`
(independently parallel after `voice-detection`), then `barge-in-loop` (the composed
acceptance), `record` last.
---
## Findings from the sdk-vetting gate (2026-09-15)

> R1's record, produced by the unit's first aspect against the SDK's **code** in the
> worktree's own checkout (`.build/checkouts/FluidAudio/`, resolved **0.15.7**, revision
> `41540ea237350afe5117a082b5c28eda642d0612` — newer than the plan's expected 0.15.5; per the
> plan's Edge case 2, newer + surface verifies → recorded, no STOP). Each fact with its
> `file:line` and verbatim quote is in `docs/planning/_card/understanding.md` (the full
> vetting record); this appendix is the PRD-facing summary.

1. **`VadManager` API shape (verified).** `public actor VadManager` with
   `chunkSize = 4096` (256 ms @ 16 kHz), `sampleRate = 16000`, `isAvailable`, `process(_:)`
   over `URL`/`AVAudioPCMBuffer`/`[Float]`, and THREE public inits: `init(config:
   progressHandler:)` (the ModelHub download path — the one the app must never take),
   `init(config:vadModel:)` (pre-loaded `MLModel` — the store-compatible staging path the
   adapter must use), `init(config:modelDirectory:progressHandler:)` (directory staging).
   Streaming surface `makeStreamState()`/`processStreamingChunk(...)`; segmentation
   `segmentSpeech(...)`. **Beta Status doc comment recorded** (adapter risk note, not a
   blocker): "not been extensively tested in production environments".
2. **Hysteresis (O6 resolved — exposed as plain data).** `VadConfig`
   (`defaultThreshold` 0.85, `debugMode`, `computeUnits` default `.cpuAndNeuralEngine`) and
   `VadSegmentationConfig` (`minSpeechDuration` 0.15, `minSilenceDuration` 0.75,
   `maxSpeechDuration` 14.0, `speechPadding` 0.1, `silenceThresholdForSplit` 0.3,
   `negativeThreshold`/`negativeThresholdOffset` 0.15, `effectiveNegativeThreshold
   (baseThreshold:)`) are `Sendable` structs injectable from the composition root — the
   wrap-with-injectable-thresholds fallback is NOT needed; the `sdk-adapters` aspect must use
   `VadSegmentationConfig` carried as plain data (S1).
3. **EOU (O2 resolved — present but ASR-integrated, the shape correction).**
   `StreamingEouAsrManager` is PRESENT at the resolved version with `StreamingChunkSize`
   (`ms160` default / `ms320` / `ms1280`) and model files `streaming_encoder.mlmodelc`,
   `decoder.mlmodelc`, `joint_decision.mlmodelc`, `vocab.json` (`ModelNames.ParakeetEOU.
   requiredModels`). **The EOU is a decoding byproduct, not a standalone scored call**: the
   manager runs the whole Parakeet streaming pipeline and EOU fires via
   `eouDetected`/`eouCallback` with the `eouDebounceMs` (default 1280) rule — the
   `sdk-adapters` aspect must plan around this integrated shape (feed audio chunks, observe
   the EOU signal — or record the interim state honestly if unusable as a standalone
   `TurnDetector` implementation; no "pending" state recorded now).
4. **Version pin (O1 resolved — no bump).** The pinned `from: "0.12.4"`
   (`Package.swift:36`) resolves to **0.15.7** (revision
   `41540ea237350afe5117a082b5c28eda642d0612`), which already carries findings 1-3 →
   **no Package.swift edit**; `Package.resolved` stays gitignored (the revision is a
   recorded fact, not a committed pin). `0.x` semantics: a future 0.16+ resolves silently
   under the range — a silent update surfaces in the pin family and the sdk-adapters suite.
5. **The VAD artifact.** `ModelNames.VAD.sileroVadFile` =
   `silero-vad-unified-256ms-v6.2.1.mlmodelc`, repo `FluidInference/silero-vad-coreml`; the
   artifact is a **bare `.mlmodelc` directory** (five files — no tarball), staged anywhere
   and handed to `VadManager(config:vadModel:)`; the SDK bundles NO model (its download init
   goes through ModelHub — the adapter must use the pre-loaded init + the C2 store, never
   the download init); the 32 ms variant is unreferenced in the SDK (only the 256 ms unified
   model is named at v6.2.1). The shipped manifest (`Sources/VoccaASR/Models/Manifests/
   silero-vad.json`, `engineID "silero-vad"`, `version "1"`, `sdkDirectory "vad"`) pins
   per-file digests + byte counts computed from the ACTUAL provisioned bytes
   (`Scripts/provision-vad-fixtures.sh`); the env-gated digest-verification row lands in
   `sdk-adapters`.
6. **License.** The SDK's own `LICENSE` is **Apache-2.0** (re-verified verbatim). The
   artifact repo's HF card metadata + README claim **MIT** (parent `snakers4/silero-vad`),
   but the repo carries **no LICENSE file** — surfaced to the integrator (plan Edge case 4
   partial), not silently absorbed.
7. **Toolchain.** The SDK declares `swift-tools-version: 6.0` and `platforms:
   [.macOS(.v14), .iOS(.v17)]` — matches our 6.0, below our `.v15`: no CI toolchain change,
   no platform bump.

**Staging layout for the `sdk-adapters` env-gated suite:** the staged bundle is
`<root>/silero-vad/1/vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/` with the verified marker
at `<root>/silero-vad/1/verified`; `VOCCA_MODEL_DIR=<root>` gates the suite.
