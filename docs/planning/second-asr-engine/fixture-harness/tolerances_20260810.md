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
- whisper.cpp: provisional table seeded from Parakeet's; **measured on whisper's output for the
  first time 2026-09-04** — both tiers (turbo + q5_0), all six fixtures, WER 0.0000 each,
  cleared with margin, **no re-baseline**; the seeded tables stand. The full measured rows,
  artifact digests and same-run companions (streamed cycle, short-audio, O(n²)) live in
  `docs/planning/settings-live-controls/verification-smoke/tolerances_20260829.md` — the
  current measured-values record.

## Measured values (first real runs, 2026-09-01)

| Engine | Run | Machine | Model artifact | Outcome | Date |
|--------|-----|---------|----------------|---------|------|
| Parakeet | `ParakeetEngineWERTests` (SMOKE 18) | founder's machine (arm64, Apple Silicon) | provisioned `parakeet-tdt-0.6b-v3/1` (verified, `ManifestDigestVerificationTests` 8/8) | **All six fixtures within the provisional table** (clean/spike-clip/accented/noisy/sixty-second ≤ ceilings; two-hundred-ms ≤ one substitution), 14.2 s, `ModelHub.offlineMode` asserted, zero network | 2026-09-01 |
| Parakeet (streaming) | `ParakeetStreamingWERTests` (SMOKE 124) | same | same | Exactly one non-empty final on the clean fixture, Parakeet-attributed, 0.224 s | 2026-09-01 |
| whisper.cpp (turbo) | `WhisperCppEngineWERTests` (SMOKE 19) | founder's machine (arm64, Apple Silicon) | provisioned `whisper-large-v3-turbo/1` — `ggml-large-v3-turbo.bin` sha256 `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` (1,624,555,275 B), manifest-verified (SMOKE 102) | **All six fixtures WER 0.0000** (two-hundred-ms: 1 substitution, "Test") — seeded table cleared with margin, no re-baseline; streamed cycle (10 partials, final == batch text-for-text), short-audio rows (no refusal), O(n²) 7.82× recorded | 2026-09-04 |
| whisper.cpp (q5_0) | `WhisperCppEngineWERTests` (SMOKE 19) | same | provisioned `whisper-large-v3-turbo-q5_0/1` — `ggml-large-v3-turbo-q5_0.bin` sha256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` (574,041,195 B), manifest-verified (SMOKE 102) | **All six fixtures WER 0.0000** (two-hundred-ms: 1 substitution, "Test") — q5_0 measured against the turbo table, same verdict: cleared with margin, no re-baseline; O(n²) 8.09× recorded | 2026-09-04 |

No margin/sign-off re-derivation was made in either run: the provisional Parakeet numbers
(2026-09-01) and the provisional whisper numbers (2026-09-04, both tiers) cleared with margin,
so nothing moved — the seeded tables stand in the two test files. A re-baseline still lands
there, in exactly those two places, per the procedure above.
