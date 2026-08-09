# C3 — Second ASR engine (whisper.cpp)

> Source: inline brief (no GitHub issue filed; slug id). Handed off from the
> `vocca-next` session on 2026-08-09.

## Brief

Build C3: whisper.cpp large-v3-turbo as the second `ASREngine` implementation, per
`CAPABILITY_ROADMAP.md:72-85` — a thin C bridge, Metal-accelerated, behind the existing
seam, reusing the shipped `ModelDownloader`/`ModelStore` from C2 for the GGUF artifact.

Acceptance is test-first: the same fixture suite runs parameterized over both engines
(`CAPABILITY_ROADMAP.md:81`; fixture-suite spec M12 already parameterizes), plus the
runtime-swap test that asserts no caller above the seam changes and only `engineIdentity`
differs.

Caveats to plan around: Swift 6 strict concurrency across the C ABI, no real-engine
inference in CI (env-gated like `ParakeetEngineWERTests`), and the zero-network invariant —
inference must make zero calls in the default path.

Note that the C1 audio-capture branch must merge before the P0 gate can clear, but C3
itself depends only on C2.

## Context pulled from the repo (vocca-next run)

- C2 (local ASR, Parakeet TDT 0.6B v3 via FluidAudio) is merged on `master` — `ASREngine`
  seam in `VoccaCore`, one real implementation in `VoccaASR/Parakeet/`.
- C4 (injection ladder) is merged on `master`; C1's audio capture is in flight on
  `feat/audio-capture/aliz`.
- The fixture suite is parameterized over `ASREngine` from day one
  (`docs/planning/local-asr/fixture-suite/spec.md:34`), so C3 is a swap, not a rewrite.
- `ROADMAP.md:304` (R5): whisper.cpp is the structural hedge against a thin Parakeet
  ecosystem; roadmap week-2 milestone requires "both engines transcribe the same fixture;
  swapping requires no caller change".
- `PRODUCT_SPEC.md:193` names the engine picker row: "Whisper turbo — Slower, broader
  language coverage. [ download ]"; per-engine model tiers are part of C3
  (`CAPABILITY_ROADMAP.md:79`).
- No C3 planning docs exist yet — `docs/planning/` has only `audio-capture-hotkey/`,
  `injection-ladder/`, `local-asr/`, `_card/`.
