# Spec: speech-seam

> Aspect of `kokoro-voice-output` (PRD rev 2026-09-12, G1/G3/G4/G5/G8, R1/R2/R4, S2).

## Problem slice

The P3 voice loop's foundation: the `SpeechSynthesizer` seam in `VoccaCore` (plain-data
vocabulary), the sentence chunker, and the seam's contract pinned by stubs — before any real
engine exists. Fully headless.

## In scope

- **R1 (vocabulary, `VoccaCore`, imports nothing):**
  - `AudioChunk` — plain `Sendable` struct: `bytes: [UInt8]`, `sampleRate: Double`,
    `channelCount: Int`, `duration: TimeInterval` (frames ÷ rate, computed by the producer).
  - `VoiceIdentity` — plain `Sendable` struct: `engineID: String`, `voiceName: String?`.
  - `SpeechSynthesizer` protocol (`ARCHITECTURE.md:301-305` shape):
    `var identity: VoiceIdentity { get }`,
    `func speak(_ text: String) -> AsyncThrowingStream<AudioChunk, Error>`,
    `func cancel() async` — documented contract: halts output **≤50 ms**; the stream
    terminates promptly after cancel; safe to cancel and immediately re-invoke (no deadlock,
    no session corruption).
  - Empty text: `speak("")` yields an empty stream (no chunks, no error) — pinned.
- **R2 (chunker):** `SentenceChunker` in `VoccaCore` (pure function, headless):
  `func sentenceChunks(of text: String) -> [String]` — splits on sentence-ending punctuation
  (`.` `!` `?` `…`), keeping the punctuation on the chunk; trims surrounding whitespace;
  drops empty chunks; a run with no sentence boundary stays whole (never splits mid-word);
  whitespace-only input → `[]`.
- **R4 (contract pins + parameterized suite, headless):**
  - `StubSynthesizer` in Tests (deterministic: pre-arranged chunks, injected yield delay,
    records `cancel` invocations) — CI's implementation.
  - Contract pins (the `ASREngineSeamTests` pattern): identity attribution; empty text →
    empty stream; chunks in sentence order; cancel mid-stream → stream terminates promptly
    with no chunks after cancel; cancel-then-immediate-reinvoke → the second `speak` renders
    fully (no deadlock).
  - The parameterized suite body (the C3 `ASRFixtureSuite` shape): `evaluate(_ synth: any
    SpeechSynthesizer, fixtures:)` — for each fixture: non-empty audio of **pinned plausible
    duration** (a known ~3-4 s utterance must render ≥1 s of PCM); chunk ordering; then the
    cancel (≤50 ms wall-clock) and re-invoke legs. One body, run over the stub in CI and over
    the real engine env-gated (the second aspect).
- **G8 (floor):** `Scripts/test-with-floor.sh` — `MINIMUM_EXECUTED_TESTS` ratcheted 1930 →
  **1949** in the same commit as the new tests (the script's deliberate-reviewed-edit
  doctrine; fixing the record drift from the last units).

## Out of scope

- No AVFoundation names in Core (CoreBoundaryTests), no real engine, no playback, no UI, no
  network, no benchmark (that is the second aspect).

## Acceptance criteria (test-first)

1. RED: the contract pins fail against the current tree (no `SpeechSynthesizer` type exists —
   compile RED is the right reason for a new seam).
2. GREEN: all pins + the chunker table + the suite body over the stub pass; Core imports
   nothing; the floor ratchet lands with the tests (floor 1949, executed ≥1949).
3. The chunker's table covers: multi-sentence, no-boundary run stays whole, punctuation kept,
   whitespace-only → [], empty → [], whitespace trimming, sentence-internal periods
   ("Mr. Smith went." — the period after Mr. is NOT a boundary by construction: the chunker
   requires a boundary to be followed by whitespace-or-end; pinned).

## Dependencies & sequencing

- First aspect (the second compiles against the seam). Depends on nothing else.

## Open questions / risks

- Sentence-internal abbreviation handling is intentionally shallow (the `space-after`
  rule) — pinned as the shipped behavior; a smarter segmenter is a later unit's choice.
- The ≤50 ms cancel contract is measured over the stub with an injected delay; the real
  engine's cancel timing is the second aspect's env-gated leg.