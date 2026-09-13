# PRD: Kokoro Voice Output — the SpeechSynthesizer seam (C9, P3)

> Source card: `docs/planning/_card/issue.md` (handoff 2026-09-12). Four founder decisions
> ratified 2026-09-12: **defer the Kokoro runtime** (seam's proven half ships now; the
> binding is a follow-on unit), **seam only** (no user-visible surface this unit),
> **TTFA recorded, never gated**, **ratchet the floor to the true count (1949)**.

## Problem Statement

VoccaSpeech is the last placeholder module in the skeleton; the P3 voice loop — the wedge —
has no foundation. C9 (`CAPABILITY_ROADMAP.md:238-253`) is that foundation: the
`SpeechSynthesizer` seam with real implementations, cancellation as a first-class operation
(C10's barge-in depends on halting mid-utterance), sentence-level chunking, and a ≤300 ms
time-to-first-audio benchmark (`ROADMAP.md:209`). What happens if we don't build this: the
P3 phase has nothing to stand on — every later capability (barge-in, dual mode, the agent
loop) composes over this seam, and the roadmap's "first thing that isn't dictation" stays
unbuilt. The runtime question (`ARCHITECTURE.md:706` — C/C++ shim vs ONNX/CoreML vs MLX) is
real and explicitly unresolved; the architecture itself names the escape hatch:
`SystemSynthesizer` (AVSpeechSynthesizer) means "we can ship a talking Vocca regardless".

## Goals & Success Metrics

- **G1 — The seam exists in `VoccaCore`.** `SpeechSynthesizer` protocol + plain-data
  vocabulary (`AudioChunk`, `AudioStream`, `VoiceIdentity`, cancellation semantics) — no
  AVFoundation names cross the Core boundary (`CoreBoundaryTests` doctrine).
- **G2 — One shipped real implementation.** `SystemSynthesizer` (AVSpeechSynthesizer via
  `write(_:toBufferCallback:)` — renders PCM buffers without a playback device, the exact
  shape the seam's chunk stream needs). **The Kokoro binding is the recorded follow-on unit**;
  the record names the doctrine state honestly (one real impl shipped + the suite written to
  parameterize over the second when it lands; the runtime decision recorded with the options
  ranked per `ARCHITECTURE.md:706`).
- **G3 — Cancellation is first-class and fast.** `cancel()` halts output ≤50 ms
  (`CAPABILITY_ROADMAP.md:248`; the C10 barge-in budget depends on it); safe to cancel and
  immediately re-invoke without deadlock or audio-session corruption.
- **G4 — Sentence-level chunking.** `speak(_:)` yields chunks as sentences complete, so
  speech can begin before the full reply is synthesized; the chunker is a pure, headless,
  tested function.
- **G5 — The parameterized suite.** One test body runs over every implementation (the C3
  `ASRFixtureSuite` shape): known text → non-empty audio of **pinned plausible duration**
  (a known ~3-4 s utterance must render ≥1 s of PCM — a floor that catches truncation
  without flaking); cancellation ≤50 ms; cancel-and-re-invoke safety. CI runs the
  deterministic stub + the seam-contract pins; the real-engine half is env-gated.
- **G4 note — the chunking boundary is concrete:** the adapter renders **one utterance per
  sentence chunk** (the chunker's sentences become `AVSpeechUtterance`s), so per-chunk
  boundaries, cancel-and-re-invoke granularity, and "speech begins before the full reply"
  are the same mechanism — pinned by the stub's contract tests first.
- **G6 — TTFA measured, recorded, never gated.** The ≤300 ms time-to-first-audio benchmark
  runs env-gated and lands as a recorded SMOKE row (house rule: P3 metrics belong to the
  uncleared P3 gate).
- **G7 — The lints are amended deliberately, not fought.** `VoccaSpeech` moves leaf → adapter
  in `ModuleBoundaryTests`; the AVFoundation expected-import set gains the
  `VoccaSpeech/System/` file; the zero-network probe's placeholder witness is replaced by
  real driven work.
- **G8 — The floor ratchet.** `MINIMUM_EXECUTED_TESTS` raised to the true executed count
  (1949) in the deliberate reviewed edit the script's doctrine demands — fixing the record
  drift (the last units' "floor 1936 → 1949" claims were executed counts, never written into
  the script).

## User Personas & Scenarios

- **The P3 pipeline (the real consumer).** C10's barge-in calls `cancel()` mid-utterance and
  re-invokes immediately; C11's converse mode composes over the same seam. The seam's
  contract is what they compile against — it must be pinned before they exist.
- **A future contributor adding a TTS engine.** The "add your own speech engine" path is the
  seam + one adapter file + one env-gated suite entry (the C3 engine precedent).
- **The founder.** No user-visible surface this unit (ratified); the recorded payoff is a
  talking Vocca once the follow-on Kokoro binding lands and the C10 loop composes.

## Requirements

### Must-have

- **R1 (vocabulary, `VoccaCore`):** `AudioChunk` (PCM plain data: bytes, sample rate,
  channel count, duration), `VoiceIdentity` (engine + voice name, plain), the
  `SpeechSynthesizer` protocol per the architecture sketch (`ARCHITECTURE.md:301-305`):
  `identity`, `speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error>`, `cancel()
  async` (documented: halt ≤50 ms, safe to re-invoke). Core imports nothing.
- **R2 (chunker):** a pure sentence-level chunker (headless, unit-tested): splits text so
  each yielded chunk is a complete sentence when the source allows; bounded; never splits
  mid-word; handles empty/whitespace input (yields nothing, not an error).
- **R3 (SystemSynthesizer):** the adapter in `VoccaSpeech/System/` — AVSpeechSynthesizer
  `write(_:toBufferCallback:)` rendering PCM buffers into the chunk stream; per-chunk
  `VoiceIdentity` attribution; `cancel()` = `stopSpeaking(at: .immediate)` + stream
  termination; zero network by construction.
- **R4 (suite):** the parameterized suite (one body over injected implementations): non-empty
  audio of plausible duration; cancellation ≤50 ms; cancel-and-re-invoke safety; chunk
  ordering (complete sentences, in order). Stub implementation for CI; SystemSynthesizer
  env-gated.
- **R5 (benchmark):** the TTFA harness (time to first chunk) env-gated, recorded — a new
  SMOKE row (step 126, the next number after the current highest at step 125), never a CI
  gate.
- **R6 (wiring):** the zero-network probe drives the new module's default work (replacing the
  placeholder witness); `VoccaSpeech` gains the `VoccaCore` import via the reviewed
  leaf→adapter move.
- **R7 (lints):** AVFoundation expected-import set amendment; the seam-family one-file rule
  for the new `AVSpeechSynthesizer`/`AVFAudio` names.
- **R8 (floor):** `MINIMUM_EXECUTED_TESTS` 1930 → 1949 (deliberate reviewed edit in the same
  commit as the new tests).

### Should-have

- **S1:** the Kokoro follow-on card is written into the record (runtime options ranked per
  `ARCHITECTURE.md:706`: C/C++ shim via the reserved `VoccaBridge`, ONNX/CoreML on the ANE,
  bundled MLX path; plus the phonemizer dependency — espeak-ng — named as the hidden cost of
  every option).
- **S2:** the seam's contract is pinned by stub tests (the `ASREngineSeamTests` pattern)
  before the adapter exists (RED → GREEN).

### Nice-to-have

- **N1:** `VoccaSpeech/System/` renders with a chosen system voice + rate from plain
  settings data (no UI this unit — the knobs are data for the follow-on).

## Technical Considerations

- **Layer/phase:** P3 voice loop, first brick (`CAPABILITY_ROADMAP.md:238`); TTS layer,
  local-only, zero egress by construction (both the system renderer and the future Kokoro
  run from local resources; the zero-network probe drives the module). **Posture recorded:**
  the P2 gate is uncleared — the matrix feature closed by founder decision 2026-09-12
  (`docs/STATUS.md`) — this unit builds ahead of the gate with that named in the record.
- **Rendering vs playback:** the seam yields PCM chunks (rendering); playback + ducking is
  `VoccaAudio/Playback/` (reserved, `ARCHITECTURE.md:107`), C10's concern. This unit never
  plays audio.
- **AVSpeechSynthesizer `write(toBufferCallback:)`** renders `AVAudioPCMBuffer`s without a
  device — the chunk stream's natural source, and the reason the "plausible duration" and
  TTFA assertions are measurable headlessly-ish (real-engine runs stay env-gated per the C3
  precedent).
- **The two-engine doctrine, stated honestly:** ROADMAP principle 4 wants two real
  implementations shipped. This unit ships one (SystemSynthesizer) because the second
  (Kokoro) is blocked on an open architecture decision the founder chose to record, not
  force; the parameterized suite is written so the Kokoro adapter joins by adding one entry,
  and the record names the doctrine's interim state.
- **The record drift fix:** STATUS/CLAUDE.md called executed counts "floors"; the script's
  constant stayed 1930. G8 ratchets it in a deliberate edit — the script's own doctrine
  (`test-with-floor.sh:35-42`) demands the raise ride in the same commit as the tests it
  counts.

## Risks & Open Questions

- **The phonemizer is the hidden cost of every Kokoro runtime** (Kokoro is not end-to-end:
  text → espeak-ng phonemes → model). S1 names it so the follow-on card is not surprised.
- **AVSpeechSynthesizer rendering behavior on this machine** (voice availability, first-buffer
  latency, `write` semantics under `stopSpeaking`) is unmeasured — the env-gated suite +
  TTFA benchmark are the measurement, and a found blocker would surface there (fix
  test-first or record).
- **Chunking semantics for AVSpeechSynthesizer**: utterance-level callbacks map to
  sentence-level chunks; long sentences render as one buffer stream — the chunker's
  boundaries are the seam's contract, tested over the stub first.
- **The floor ratchet is a reviewed edit** — it must land with the C9 tests or the script's
  doctrine is violated (no bare constant raises).

## Out of Scope

- No Kokoro binding (recorded follow-on), no playback/ducking (C10), no UI surface (C10/C11),
  no voice-loop wiring, no P3 gate claims, no cloud, no network egress of any kind.

---

## Aspect decomposition

| Aspect | Boundary |
|--------|----------|
| `speech-seam` | The Core vocabulary + protocol + chunker + stub + contract pins (RED→GREEN, fully headless) + the floor ratchet. |
| `system-synthesizer` | The AVSpeechSynthesizer adapter + the parameterized suite's real half + TTFA benchmark (env-gated) + lints + zero-network probe wiring. |