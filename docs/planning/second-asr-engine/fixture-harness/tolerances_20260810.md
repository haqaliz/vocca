# WER tolerance record — provisional tables and the re-baseline procedure (2026-08-10)

> The **only** place the per-engine WER tolerances and their mechanism are explained; the
> numbers themselves live in exactly two files — `ParakeetEngineWERTests.swift` and
> `WhisperCppEngineWERTests.swift`, each with its own table, each marked provisional. Nothing
> else in the repo asserts a WER number.

## The provisional tables (both engines, seeded from Parakeet)

| Fixture | Parakeet (provisional) | whisper.cpp (provisional) | Bound |
|---|---|---|---|
| `clean` | 0.10 | 0.10 | WER ceiling |
| `spike-clip` | 0.10 | 0.10 | WER ceiling |
| `accented` | 0.12 | 0.12 | WER ceiling |
| `noisy` | 0.20 | 0.20 | WER ceiling |
| `sixty-second` | 0.10 | 0.10 | WER ceiling |
| `two-hundred-ms` | 1.0 | 1.0 | at most **one substitution** (a rule, not a WER ceiling — `fixture-suite/spec.md:60`; carried identically for both engines by `RealEngineWERRunner`'s `specialRules`) |

**Provisional by decision, never by claim.** The fixtures are TTS stand-ins
(`Tests/Fixtures/FIXTURES.md` labels them) — unnaturally clean audio, so these numbers are a
starting point seeded from Parakeet's first real run, not a measurement of whisper.cpp. The
whisper table was **not** set from any real whisper run (none exists yet); it is Parakeet's
table copied as the mechanism's required starting point (PRD M6). Nothing passes or fails a
release gate on these numbers until the procedure below has run.

## The mechanism (PRD M6): measured + margin, founder-signed

1. **Measure.** On the founder's machine, with `VOCCA_MODEL_DIR` set to the store-shaped
   whisper install (`Scripts/provision-asr-fixtures.sh --engine whisper-large-v3-turbo`), run
   `WhisperCppEngineWERTests`. The run prints the per-fixture WER (the runner's violation
   errors carry the full ledger). Record the six numbers — the measurement, not the guess.
2. **Margin.** For each fixture: `tolerance = measured WER + margin`, where the margin is the
   headroom the machine-to-machine spread needs (a different core count, a quieter or louder
   room, a different clip of the same register). The margin is chosen by the founder for each
   fixture; a fixture that measures 0.0 still gets a nonzero margin (a perfect TTS clip is not
   a perfect room).
3. **Sign.** The founder signs off the table — the record of the run that produced it (machine,
   model artifact hash from the manifest, date) is cited in this file.
4. **Land.** The signed numbers replace the provisional ones in **exactly two files**: the
   whisper table in `WhisperCppEngineWERTests.swift`, the parakeet table in
   `ParakeetEngineWERTests.swift`. Both tables move together — the two engines run the same
   suite, and a re-baseline that moved only one would hide a regression in the other.
5. **A failing run re-baselines, never silently relaxes.** A real-run failure is the correct
   outcome; the fix is the re-baseline procedure above with data in hand. A tolerance is never
   raised without a measured WER + margin and the founder's sign-off behind it.

## Where the final numbers land: F2

The founder's real recordings (F2) replace the TTS stand-ins in `Tests/Fixtures/` and the
provisional tables are re-measured against them with the same procedure — the numbers settle
only then. The mechanism is fixed now; only the numbers move, in the two test files this
record names.

## Current status

- Parakeet: provisional table as shipped at C2; passed its first real run (2026-08-09,
  `CLAUDE.md`) — the numbers have **not** been re-derived with margin/sign-off yet.
- whisper.cpp: provisional table seeded from Parakeet's; **no real run exists yet** — the
  manifest is uncommitted (pending the founder's artifact download) and the test skips
  without `VOCCA_MODEL_DIR`.
