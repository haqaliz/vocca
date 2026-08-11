# Aspect spec — `asr-seam`

Parent PRD: [`../prd.md`](../prd.md) · Capability C2 · Phase P0
Depends on: C1 `audio-capture` merge for the bridge task only (this aspect's core is unblocked)

---

## Problem slice

The product's whole pluggability claim — a better local model, a community engine, the
future hosted tier slots in without a rewrite — needs an `ASREngine` seam that exists as
**code**, not prose. `ARCHITECTURE.md:219-229` specifies the protocol and §4 names the
vocabulary; none of it is implemented, and `VoccaASR` is a placeholder leaf while
`VoccaCore` (which must own the seam) has no ASR types at all.

This aspect makes the seam real: the vocabulary, the protocol, the empty-buffer policy, and
the C1→C2 completeness link — the point where "short by N samples" stops being a count a
nobody reads and becomes a fact on the `Transcript`.

**User outcome:** nothing visible yet. The outcome is structural: a caller (the probe today,
the app at C4) can `transcribe` through a seam whose contract is pinned by tests, and C3's
whisper.cpp will be a swap rather than a rewrite.

**Why it is the first aspect:** it is pure `VoccaCore` + tests — no FluidAudio, no network,
no model, fully headless. It is the repository's entire pattern: the decision lives where
the tests can reach it.

---

## What this aspect inherits — decided, do not relitigate

| # | Constraint | Where it came from |
|---|---|---|
| 1 | **`ASREngine` is owned by `VoccaCore`**, which imports nothing. The protocol, the vocabulary, and the error cases live there. | `ARCHITECTURE.md:219-229`, `:129-156`, `:186-190`; `CoreBoundaryTests` |
| 2 | **16 kHz mono Float32 is the only format at the seam boundary.** Engines that want something else convert internally, never the caller. | `ARCHITECTURE.md:129-135`; `CapturedAudioFormat.interchange` (audio-capture) |
| 3 | **`Transcript.engine` is non-optional.** Attribution is invariant I1; downstream code must never be able to mis-attribute output. | `ARCHITECTURE.md:140-141` |
| 4 | **Streaming is optional-with-default.** The protocol declares it; the batch default buffers-and-transcribes. `supportsStreaming == false` at C2. | `ARCHITECTURE.md:226-228`; PRD M1 |
| 5 | **An empty buffer is a legitimate answer.** C1: "an empty buffer is a legitimate answer: a 20 ms press captured almost nothing"; live presses under ~122 ms lose the opening. `transcribe` must return a valid empty `Transcript`, never error. | `SessionAudioSource.swift:95-97` (audio-capture); `plan_20260806.md:185-187`; PRD M3 |
| 6 | **The completeness count is the invariant's next link.** C1's Phase 5 hands over a buffer marked short-by-N; the count must surface in the `Transcript` or short audio masquerades as complete. | `plan_20260806.md:331-334`; PRD M4; I1 `ARCHITECTURE.md:15` |
| 7 | **The seam lint pattern.** The H7 pattern (`HotkeySeamBoundaryTests` — one file permitted to name a framework) will be applied to FluidAudio in `parakeet-engine`; nothing in this aspect needs it. | `HotkeySeamBoundaryTests` |
| 8 | **Apache-2.0 headers on every new file; the test floor ratchets in the same commit that adds tests.** | `LicenseHeaderTests`; `Scripts/test-with-floor.sh` |
| 9 | **`VoccaAudio` is where the bridge lives** (the adapter that produced the captured audio). It becomes an adapter module at audio-capture Phase 5, importing `VoccaCore`. | `plan_20260806.md:341`; PRD M4 |

---

## In scope

- `EngineIdentity` (`id`, `displayName`, `isLocal`) — `Sendable`, `Hashable`, `Codable`.
- `AudioBuffer` — 16 kHz mono Float32 `[Float]` with an asserted `sampleRate` (trapping
  init + a testable validity predicate, the `CapturedAudioFormat` pattern); computed
  `audioDuration`.
- `TranscriptSegment` — `text`, `range`, `confidence: Float?`.
- `Transcript` — `text`, `segments`, **non-optional `engine`**, `isFinal`, `audioDuration`,
  and **`missingSampleCount: Int`** (the completeness link; 0 = complete).
- `VoccaError` — `modelUnavailable(EngineIdentity, reason:)`, `transcriptionFailed(EngineIdentity, underlying:)` (+ `.cancelled` if the §6 vocabulary needs it).
- `ASREngine` — `identity`, `supportsStreaming`, `prepare()`, `transcribe(_:)`,
  `stream(...)` with a **batch default implementation** in an extension.
- The **empty-buffer policy** pinned by tests on a stub engine: ~0 samples → valid empty
  `Transcript` (`text == ""`, `audioDuration` actual), never an error.
- The **bridge** (gated on the `audio-capture` merge): captured Buffer → `AudioBuffer`,
  carrying `refusedSampleCount` as `Transcript.missingSampleCount`; lives in `VoccaAudio`.
- Amend `ARCHITECTURE.md` §4: the `Transcript` vocabulary gains `missingSampleCount`; the
  §4 text is corrected to match what shipped (the C1 pattern).

## Out of scope

- **The Parakeet/FluidAudio implementation** — `parakeet-engine` aspect. `VoccaASR` stays a
  leaf placeholder here (its adapter move is that aspect's).
- **The downloader / model lifecycle** — `model-downloader` aspect.
- **Fixtures, WER, CI model cache, the offline suite** — `fixture-suite` aspect (the probe
  extension with the real engine lives there too).
- **Download UI** — `download-ui` aspect.
- **Streaming behaviour** — C7; the protocol only declares it.
- **Any network, any model, any Application Support access.**

---

## Acceptance criteria (tests written first)

1. **Vocabulary contract.** `EngineIdentity` carries its three fields; `AudioBuffer`
   accepts exactly 16 kHz mono and its validity predicate rejects every near miss
   (44.1 kHz, stereo, 0-sample-rate); `audioDuration == samples.count / 16000`.
2. **Attribution.** A stub engine's `transcribe` returns a `Transcript` whose `engine`
   equals the stub's `identity`, and the field is non-optional — mis-attribution is
   structurally impossible (the C2 acceptance's identity clause,
   `CAPABILITY_ROADMAP.md:60`).
3. **Empty buffer.** `transcribe(AudioBuffer(samples: []))` on the stub returns a valid
   empty `Transcript` (`text == ""`, `audioDuration == 0`) — no throw (PRD M3).
4. **Batch default.** The stub that does not implement `stream` still satisfies the
   protocol; its inherited `stream` buffers the chunks and yields exactly one final
   `Transcript` whose text equals the concatenated transcription.
5. **Completeness link** (gated on the `audio-capture` merge). An incomplete captured
   buffer (refused N samples) converts to a `Transcript` with `missingSampleCount == N`;
   a complete one → `0`; an empty one → valid empty `Transcript` with `missingSampleCount`
   unchanged from the source (PRD M4, three clauses like the C1 Phase-5 RED).
6. **Module discipline.** `VoccaCore` still imports nothing (`CoreBoundaryTests` green);
   `VoccaASR` remains a leaf; every new file carries the Apache-2.0 header; the test floor
   is ratcheted in the same commits.

---

## Dependencies and sequencing

- Phases 1–2 (vocabulary, seam) are **unblocked** — they are pure `VoccaCore` + tests and
  do not touch anything the `audio-capture` branch is changing.
- Phase 3 (the bridge) **requires the `audio-capture` merge**: the captured Buffer type
  with `refusedSampleCount` is defined there (`plan_20260806.md` Phase 5). If the merge has
  not landed when this plan reaches Phase 3, stop and ask — do not invent the captured
  type.
- `parakeet-engine` follows, opening with the F1 spike.

---

## Open questions / risks

- **Does `AudioBuffer` conform to `CapturedAudio`?** The session machine's custody is
  generic over `CapturedAudio`; the seam input is `AudioBuffer`. Decision recorded here:
  **no conformance in this aspect** — the bridge converts, the machine stays generic. If
  C4's wiring argues otherwise, that is C4's amendment, not C2's.
- **`range` representation** on `TranscriptSegment`: `Range<TimeInterval>` (explicit, no
  empty-range ambiguity) — decided; revisit only if a consumer needs `ClosedRange`.
