# C2 — Local ASR behind `ASREngine`

**Type:** feat · **Id/slug:** `local-asr` · **Branch:** `feat/local-asr/aliz`
**Owner:** aliz · **Source:** inline brief (no GitHub issue exists)

---

## Brief

Build C2: the `ASREngine` protocol (`transcribe(AudioBuffer) async throws -> Transcript`,
with per-segment timings, confidence, and engine identity) and Parakeet TDT 0.6B v3 via
FluidAudio as the first implementation, model download-on-first-run with integrity
verification and resumable transfer into Application Support, and warm-model residency.

Write the acceptance tests first, exactly as `CAPABILITY_ROADMAP.md:60` names them: a
fixture suite (clean, accented, noisy, 60 s, 200 ms utterances) transcribing within WER
tolerance **with the network interface down as part of the test**, plus an assertion that
the engine reports its identity so output is never mis-attributed.

## Caveats the dig must not be surprised by

- The C1 `audio-capture` aspect must merge first and its hand-over type (complete/incomplete
  buffer) is the input to this seam.
- The fixture assets and the CI model-provisioning strategy are unwritten in the planning
  docs and must be decided.
- FluidAudio is the repo's first external SPM dependency.
- The download-progress surface is the first real use of the still-placeholder `VoccaUI`.

## Grounding

- Capability definition: `docs/technical/CAPABILITY_ROADMAP.md` C2 (lines 50–66); seam table line 299.
- Phase: **P0** — core dictation loop (`docs/ROADMAP.md` weeks 1–4; week-2 milestone at line 82).
- Risk register: R5 (Parakeet ecosystem thin, `docs/ROADMAP.md:304`), R3 (latency ceiling, `:302`).
