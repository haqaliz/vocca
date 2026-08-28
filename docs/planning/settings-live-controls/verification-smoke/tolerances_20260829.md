# Whisper tolerance record — the re-baseline this aspect makes possible (2026-08-29)

Mechanism doc in the house shape (`deterministic-cleanup/eval-harness/tolerances_20260815.md`,
`warm-start-streaming/.../tolerances_20260825.md`): **this file records measured values only.**
The numbers themselves live where they have always lived — the two tolerance tables in
`Tests/HarnessTests/WhisperCppEngineWERTests.swift` and
`Tests/HarnessTests/ParakeetEngineWERTests.swift` — and a re-baseline lands there, in exactly
those two places.

**This aspect introduces no new number.** It introduces a check, a set of smoke steps and this
record. Nothing here declares a threshold, because nothing here has measured one.

## What this file adds, and what it does not

`docs/planning/second-asr-engine/fixture-harness/tolerances_20260810.md` is and stays **the**
explanation of the per-engine WER tolerances and their mechanism — the provisional tables, the
measure → margin → sign → land procedure, and the rule that a failing run re-baselines rather
than relaxes. It is not restated here; two explanations of one mechanism is how they drift.

What this file adds is what `verification-smoke` made available and 2026-08-10 could not have:

1. **A measured-values table with a row per real run**, so a run that happens leaves a record
   behind. `tolerances_20260810.md` carries prose status instead, and prose status is how "no
   real run exists yet" survived four months of the repository saying so.
2. **The artifact hashes as a required field.** Until `ManifestDigestVerificationTests` existed
   there was no honest way to name the bytes a WER was measured on: the manifest's digests were
   themselves unverified. After `SMOKE_CHECKLIST.md` step 102 passes, the manifest's `sha256`
   entries *are* the artifact's hashes, verified against the disk, and a recorded run can name
   the model it measured rather than the model it believed it measured.
3. **The ordering constraint.** Step 104 is void — not failed, void — if step 102 has not passed
   for the artifact the run used. A WER measured against unverified bytes measures an unknown
   model, and recording it would close a question that is still open.

## Status, stated exactly

| Claim | Status |
|---|---|
| The whisper tolerance table is measured on whisper | **No.** Seeded from Parakeet's table (`tolerances_20260810.md`), never measured on whisper's output. |
| Whisper has transcribed anything, ever | **No.** `SMOKE_CHECKLIST.md` step 19 is unexecuted; steps 96 and 103 are the first executions through the product. |
| The shipped whisper manifests are defective | **Unknown, and not the claim.** The `{}` placeholder digest appears in no manifest, no entry declares a 0- or 2-byte size, and no digest repeats. What is unverified is provenance: `672367e` added both files with no provisioning run recorded behind it. Step 102 is the first comparison against bytes. |
| Anything passes or fails a release gate on these numbers | **No**, and nothing will until the procedure below has run once. |

## Measured values (filled by the founder's real run)

One row per real run. An empty table is the honest state and is left visible.

| Run | Machine (model id / chip) | Artifact (`engineID`/`version`, verified per step 102) | `clean` | `spike-clip` | `accented` | `noisy` | `sixty-second` | `two-hundred-ms` | Date |
|-----|---------------------------|--------------------------------------------------------|---------|--------------|------------|---------|----------------|------------------|------|
| _(none yet — `SMOKE_CHECKLIST.md` step 19 is the first execution)_ | | | | | | | | | |

The `two-hundred-ms` column records the substitution count, not a WER: its bound is a rule (at
most one substitution), carried for both engines by `RealEngineWERRunner`'s `specialRules`.

The artifact column names the manifest's `engineID`/`version` **and** the digest of each file
from that manifest, which step 102 has verified against the disk. Recording a run without it
names no model at all: three tiers ship, two of them are whisper, and their directories were the
same directory until 2026-08-28.

## The re-baseline procedure

The procedure is `tolerances_20260810.md`'s — measure, add the founder's per-fixture margin,
founder-signs, land in exactly the two test files, and a failing run re-baselines rather than
relaxes. This aspect changes two things about executing it:

1. **Step 102 first.** Verify the manifests against the provisioned bytes before the run. Void
   the run otherwise.
2. **Record here.** The measured row lands in the table above — machine, artifact hashes, the six
   figures, the date — before the numbers move in the test files. A number that moved with no row
   behind it is a number nobody can check.

Both tables still move together. The two engines run the same six fixtures, and re-baselining one
alone hides a regression in the other.

## Where the numbers live

`WhisperCppEngineWERTests.swift` and `ParakeetEngineWERTests.swift`, one table each, as
`tolerances_20260810.md` says. No number in this file, no number in the smoke steps, no number in
`ManifestDigestVerificationTests` — which asserts an equality against measured bytes and never a
threshold. Nothing to single-source, because nothing new was introduced.
