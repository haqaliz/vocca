# Fixture provenance

| File | Purpose | Source | License | Status |
|---|---|---|---|---|
| `spike-clip.wav` | The F1 spike's timing fixture (~8.9 s, 16 kHz mono) | macOS `say` (Alex, 180 wpm) rendering a fixed paragraph, converted with `afconvert` | Generated — no third-party content | **TTS stand-in for timing only.** It measures *how long transcription takes*, not *how well it transcribes* — TTS audio is unrepresentatively clean. The C2 WER suite's real fixtures (the founder's own voice, per the founding decision) are recorded under `fixture-suite` and will live alongside this file. |

The spike measured durations against this clip; the full fixture suite's provenance (recording
settings, golden transcripts, WER tolerances) is `fixture-suite`'s deliverable.
