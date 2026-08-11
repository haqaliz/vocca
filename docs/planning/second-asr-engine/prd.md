# C3 — Second ASR engine (whisper.cpp large-v3-turbo): PRD

> `docs/planning/second-asr-engine/prd.md` — Phase 3/4 output, 2026-08-09.
> Source: `docs/planning/_card/issue.md` (inline brief from `vocca-next`) +
> `docs/planning/second-asr-engine/understanding.md` (Phase 2 dig).
>
> **Status: SHIPPED 2026-08-10** — implemented per the six aspect plans
> (`bridge-integration`, `whisper-engine`, `model-lifecycle`, `fixture-harness`,
> `engine-picker`, `ci-wiring`), merged to `master`. Open founder steps recorded in
> `docs/SMOKE_CHECKLIST.md` steps 19–21: the first real whisper WER run and the
> weights-license record sign-off.

## Problem Statement

The `ASREngine` seam in `VoccaCore` has exactly one real implementation — Parakeet TDT
0.6B v3 via FluidAudio (C2, merged). Guardrail 7 says a seam with one implementation is
"not a seam; it's an assertion" (`CAPABILITY_ROADMAP.md:329`), and R5 names the concrete
risk: Parakeet's ecosystem is thin, "a break leaves us stranded" (`ROADMAP.md:304`). The
P0 week-2 milestone requires a second engine behind the same protocol — "both engines
transcribe the same fixture; swapping requires no caller change" (`ROADMAP.md:83`) — and
C14's out-of-tree seam proof is defined as running the *full C2/C3 fixture suite*
(`CAPABILITY_ROADMAP.md:290`). Without C3, the pluggable claim is decoration and the
hedge is a promise.

## Goals & Success Metrics

1. **The seam is proven, not asserted.** The same fixture suite runs parameterized over
   both engines; both pass their (provisional) WER tolerances
   (`CAPABILITY_ROADMAP.md:81`).
2. **Swapping is invisible above the seam.** A runtime mid-session-boundary swap test
   asserts the only observable difference is `engineIdentity` on the transcript
   (`CAPABILITY_ROADMAP.md:81`); adding the engine touches zero call sites.
3. **The engine is switchable in settings without restart**, with honest tradeoff copy
   (`PRODUCT_SPEC.md:189-196`).
4. **Model tiers exist per engine** — large-v3-turbo (1.5 GiB) default, q5_0 (547 MiB)
   constrained tier (`CAPABILITY_ROADMAP.md:79`).
5. **Zero network calls during inference** (I2): the whisper engine's path makes no
   transport use; the interposer probe keeps covering the whole machine.
6. **CI stays honest**: the headless suite passes (any warning fails); real-engine WER
   runs are env-gated exactly like `ParakeetEngineWERTests` (`VOCCA_MODEL_DIR`); the test
   floor ratchets in the same commit.

## User Personas & Scenarios

- **The privacy-literal user** (ICP): wants dictation that never leaves the machine;
  C3 is invisible to them — same hotkey, same widget, better resilience.
- **The multilingual / accuracy-first user**: Whisper's broader language and accuracy
  coverage is their escape hatch from Parakeet's 25-language envelope
  (`PRODUCT_SPEC.md:193`).
- **The constrained-Mac user**: M1-class hardware; drops to the q5_0 tier instead of
  falling off a cliff (`CAPABILITY_ROADMAP.md:79`).
- **The future contributor / hosted-tier evaluator**: checks the one test that proves
  the seam is real — both engines, one test body.

## Requirements

### Must-have

- **M1 — `WhisperCppEngine` conforms to `ASREngine`** (`identity` =
  `"whisper-large-v3-turbo"`, `supportsStreaming = false`, `prepare()` load-once
  idempotent, `transcribe(_:)`). Actor, never on the main actor, Swift 6 strict
  concurrency clean (any warning fails CI). Batch `stream` comes free from the protocol
  default.
- **M2 — Integration via the official XCFramework binary target.** whisper.cpp v1.9.2
  xcframework, checksum-pinned in `Package.swift` (51 MB, Metal embedded via
  `GGML_METAL_EMBED_LIBRARY`, links Accelerate+Metal+Foundation, arm64+x86_64 macOS).
  No vendored source.
- **M3 — One-file-per-seam discipline for the C family.** The bridge file —
  `VoccaASR/Whisper/WhisperCAPI.swift` — is the one file permitted to name whisper.cpp
  identifiers, with an H8b-style two-sided seam lint (permitted file names the family,
  nothing else in `Sources/` may; no laundering routes), matching the H7/H8b precedent
  (`ARCHITECTURE.md:124-135`). `VoccaASR` keeps importing only `VoccaCore`
  (module-boundary lint); the `VoccaBridge` module from `ARCHITECTURE.md:40` is **not**
  introduced (see Open Questions).
- **M4 — Model lifecycle reuses the shipped store.** `ModelStore`/`ModelDownloader`/
  `ModelManifest` are engine-agnostic and used as-is: checked-in manifests
  (`whisper-large-v3-turbo.json`, `whisper-large-v3-turbo-q5_0.json`) with real
  SHA-256/byteCount computed at provisioning time (upstream documents SHA-1 only);
  flat layout, `sdkDirectory: nil`; version directories immutable; provisioning script
  generalized from `Scripts/provision-asr-fixtures.sh` (currently Parakeet-hardcoded).
- **M5 — Contract fidelity.** Every returned `Transcript.engine == identity` (I1);
  empty buffer yields a valid empty transcript, never an error; errors map to
  `VoccaError.modelUnavailable` / `transcriptionFailed` with the engine identity and
  the underlying error intact.
- **M6 — Parameterized fixture suite over both engines.** One test body; per-engine
  tolerance tables; real-engine runs env-gated (`VOCCA_MODEL_DIR` precedent); stubs keep
  the headless suite fast and offline. **Tolerance mechanism (the acceptance's number):
  provisional whisper tolerances are set by a real env-gated run on the founder's
  machine over the six shipped fixtures — per-fixture WER recorded, tolerance =
  measured WER + margin, Parakeet's provisional numbers as the starting point, signed
  off by the founder, stored in exactly one place. TTS-stand-in fixtures stay
  provisional; F2 (founder recordings) replace the numbers later, in that same one
  place, for both engines.** Fallback if the first real run misses: re-baseline
  per-engine with the founder's sign-off — per-engine tolerances are the designed
  shape, not a shared number.**
- **M7 — Runtime swap test.** Mid-session-boundary swap asserts no caller above the
  seam changes and only `engineIdentity` differs; if adding the engine requires
  touching a call site, the test says so.
- **M8 — Minimal engine picker.** Radio row in the Speech tab:
  "◉ Parakeet v3 — Fastest. 25 European languages. [installed] / ○ Whisper turbo —
  Slower, broader language coverage. [download]" (`PRODUCT_SPEC.md:189-196`). Download
  triggered through the shipped Core-owned `ModelDownloadSession` seam (progress UI
  reused from C2's `download-ui`). Selection is a Core-owned value, switchable without
  restart, with a per-engine model-tier choice (turbo full / q5_0). This resolves the
  C2-deferred settings tension (`docs/planning/local-asr/prd.md:315-316`): the picker is
  the minimum that satisfies "switchable in settings" while honoring
  `ROADMAP.md:74`'s scope discipline; no settings beyond the Speech tab.
- **M9 — Zero-network default path.** No transport/`URLSession` usage anywhere in the
  whisper engine path (H8 already confines `URLSession` to one file; the lint stays).
  The zero-network interposer probe drives a whisper-engine fixture run.
- **M10 — Pre-merge license & attribution task.** Verify the GGUF weights license from
  a primary source and add attribution (NOTICE or equivalent) for whisper.cpp/ggml
  (MIT) and the converted weights; `Package.swift` binary target carries its license
  metadata.
- **M11 — CI budget.** Headless suite (including the new lint + parameterized harness)
  stays green under strict concurrency and within the 20-minute job budget; the
  binary-target build works on a macOS hosted runner (no GPU — CPU fallback is a
  supported whisper.cpp mode; env-gated real runs are the only GPU-dependent path).

### Should-have

- **S1 — Honest latency posture.** Picker copy states Whisper is slower than Parakeet
  (`PRODUCT_SPEC.md:193`); measured RTF figures are recorded in the smoke checklist /
  fixture notes once real runs exist (no unmeasured numbers anywhere).
- **S2 — Tier choice in the picker.** The constrained tier (q5_0) is selectable next to
  the engine choice (small menu or second row), gated to the Whisper engine.

### Nice-to-have

- **N1 — `initial_prompt` / language hint passthrough** on the C API for future
  custom-dictionary work (not exposed in P0).
- **N2 — `whisper_full_parallel`** if a benchmark shows a win; not a P0 commitment.

## Aspect Candidates (for tech-plan)

| Aspect | Boundary | Independence |
|--------|----------|--------------|
| `bridge-integration` | XCFramework binary target + checksum pin + **spike first**: package resolves, builds, and the new seam lint passes on a macOS runner | First task — de-risks everything else |
| `whisper-engine` | `WhisperCppEngine` actor + `WhisperCAPI.swift` bridge file + H8b-style C-family seam lint + contract fidelity (I1, empty buffer, attributable errors) | After bridge |
| `model-lifecycle` | Manifests (turbo + q5_0), provisioning script generalization, real SHA-256 pinning | Independent of engine (parallel) |
| `fixture-harness` | Parameterize the suite over engines; per-engine tolerance tables; env-gated real run; tolerance re-baseline mechanism | After model-lifecycle (needs artifacts); lint parallel |
| `engine-picker` | Speech-tab radio row + tier choice + `ModelDownloadSession` trigger + Core-owned selection | Independent (UI); depends on Core selection type |
| `ci-wiring` | Env-gated runner wiring, suite budget, floor ratchet | Last — integrates all |

## Technical Considerations

- **Phase:** P0, week-2 milestone (`ROADMAP.md:83`); depends only on C2 (merged). C1's
  audio-capture branch is a P0-gate prerequisite, not a C3 dependency
  (`_card/issue.md:21-22`).
- **Seam:** `ASREngine` proven (guardrail 7). `EngineIdentity.id` is already pinned by
  the shipped core (`Sources/VoccaCore/EngineIdentity.swift:28`); display name
  "Whisper turbo" per `PRODUCT_SPEC.md:193`.
- **Latency:** P0 records, P2 gates. Whisper is the slower engine by design; the
  default engine stays Parakeet. No latency number is claimed for C3 before a real run.
- **Privacy / local-first:** `isLocal = true` (no egress badge); inference makes zero
  network calls; model files land in Application Support under
  `models/whisper-large-v3-turbo/<version>/`; nothing leaves the device.
- **Swift 6 strict concurrency:** the `OpaquePointer`-holding actor pattern (Parakeet
  precedent); C pointers confined to one isolation domain; no `@unchecked Sendable`;
  no callbacks required for batch transcription (segments read after `whisper_full`
  returns).
- **Concurrency of the C API:** one `whisper_context` used by one thread at a time
  (documented contract); the actor serializes.

## Risks & Open Questions

- **R5 retired-by-construction** (`ROADMAP.md:304`) once the second engine merges; the
  hedge is real, not promised.
- **CI wiring is still pending for real-model runs** (F1 verdict on a macos-15 runner,
  `docs/planning/local-asr/fixture-suite/ci-wiring-decision_20260809.md`). C3 inherits
  the env-gated path regardless; the runner verdict may upgrade either engine's real
  run to CI later. Open: does the whisper real run ride the same env-gated harness from
  day one? (Yes — recommended; single mechanism, both engines.)
- **SHA-256 provenance** — upstream documents SHA-1; SHA-256 is computed and pinned at
  provisioning time by the founder. Open: none — recorded as a provisioning step.
- **Weights license** — verification is M10, pre-merge, on the founder.
- **Tolerances** — provisional per-engine tables (TTS stand-ins); F2 (founder
  recordings) set final numbers "in exactly one place". Open: if F2 lands before C3
  merges, use F2 numbers for both engines; otherwise provisional stands.
- **Open — `VoccaBridge` module:** ARCHITECTURE.md:40 anticipates it, but introducing
  it today would break the module-boundary lint (`VoccaASR` imports only `VoccaCore`).
  Decision in the plan: keep the one-file bridge inside `VoccaASR/Whisper/` (matching
  the CGEvent/keystroke precedent); amend ARCHITECTURE.md only if a later capability
  (C9's Kokoro) genuinely needs a shared C target.
- **Open — tier UI depth:** S2 (tier menu in the picker) vs API-only tier selection in
  C3. Recommended: S2 ships — the acceptance names a per-engine model-tier choice, and
  an invisible API-only tier fails the honest reading of `CAPABILITY_ROADMAP.md:79`.

## Out of Scope

- **Model registry UI** (disk used, remove, re-download) — C14
  (`download-ui/spec.md:54`); C3 ships only the picker row + download trigger.
- **Streaming ASR** — C7 (whisper.cpp batches by design; `CAPABILITY_ROADMAP.md:162`).
- **Auto-updating models** — `PRODUCT_SPEC.md:273`.
- **WhisperKit / other engines** — C3 is whisper.cpp large-v3-turbo only.
- **Cross-platform** — macOS only (guardrail 3).
- **Cloud in the OSS core** — none; this engine is local-only (`isLocal = true`).
- **Per-segment language detection UX** — the C API exposes it; P0 doesn't.
