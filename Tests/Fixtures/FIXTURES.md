# Fixture provenance

All fixtures are 16 kHz mono WAV, the interchange format (`CapturedAudioFormat.interchange`).
Each has a golden transcript `.txt` beside it; the WER scorer normalizes case and punctuation,
so the goldens are written naturally.

| File | Duration | Source | License | Status |
|---|---|---|---|---|
| `spike-clip.wav` | 8.86 s | macOS `say` (Alex, 180 wpm) | Generated — no third-party content | **TTS stand-in** (the F1 spike's clip; also `clean`'s audio) |
| `clean.wav` | 8.86 s | byte-identical copy of `spike-clip.wav` | Generated | **TTS stand-in** |
| `accented.wav` | 8.65 s | `say` (Daniel, 180 wpm) — the stand-in for the founder's accent register | Generated | **TTS stand-in** |
| `noisy.wav` | 8.86 s | `clean.wav` + deterministic sine hum (120/240/997 Hz) at **20 dB SNR**, mixed once and checked in | Generated | **TTS stand-in** |
| `sixty-second.wav` | 57.5 s | `say` (Alex, 185 wpm), a ~180-word paragraph | Generated | **TTS stand-in** |
| `two-hundred-ms.wav` | 0.50 s | `say` (Alex): the word "test" plus `say`'s leading/trailing silence | Generated | **TTS stand-in** — the speech itself is ~250 ms; the founder's real ~200 ms clip replaces it |

## The stand-in disclaimer

**TTS audio is unrepresentatively clean.** These fixtures measure *machinery* (the harness,
the scorer, the tolerance plumbing) and give provisional numbers only. The C2 WER suite's
real fixtures — the founder's own voice, per the founding decision — replace the stand-ins
under the `fixture-suite` aspect's F2 task; nothing about the harness changes when they land,
only the bytes.

## The provisional tolerances' home

The provisional WER tolerances (clean ≤ 0.10, accented ≤ 0.12, noisy ≤ 0.20, 60 s ≤ 0.10,
200 ms ≤ 1 substitution) live in exactly one place: `ParakeetEngineWERTests`. They are
provisional by decision — set from the founder's first real run, never guessed — and the
numbers move there, nowhere else.
