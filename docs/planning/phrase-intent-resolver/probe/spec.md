# Aspect: probe

## Problem slice

Prove, inside the zero-network interposer, that the composed default still resolves
nothing, spawns nothing and can't reach shell, and that a seeded phrase table round-trips
through the real recipe (PRD R8).

## In scope

- `VoccaNetworkProbe/IntentDrive.swift`:
  - **PROBE-INTENT-DEFAULT** becomes `resolver=PhraseIntentResolver resolves=1
    intentResolved=0 spawnsSubprocess=false intentShellRows=0`. **Corrected in planning:**
    no `phrases=` field here, because the composed root reads the real Application Support
    directory and the count would be machine-dependent. The count lives on
    PROBE-INTENT-PHRASE. `intentShellRows` now counts shell targets across the keyword seeds
    **and** the composed default's loaded phrase table.
  - **PROBE-INTENT-PHRASE** (new): a temp store seeded with one audit phrase and one shell row;
    output `phrases=1 resolved=1 card=yes invoked=1 shellRefused=1`. Every field is an effect of
    the run: the store's load count, the resolution, the widget store's card, the provider's
    call log, and the store's refusal log count.
- The guard-the-guard pair for each line: a planted `phrases=1` on the default and a planted
  `shellRefused=0` on the phrase line fail loudly.
- The harness test that asserts the probe output lines.

## Out of scope

Any other probe line, and the interposer itself.

## Acceptance criteria (failing tests first)

1. The probe test expects the new PROBE-INTENT-DEFAULT line and fails against the old one
   (RED).
2. It expects PROBE-INTENT-PHRASE with the exact fields (RED until the drive exists).
3. Both guard-the-guard plants fail.
4. The zero-network interposer records no violation across the whole probe run.
5. The default store location is asserted temporary (`store.isDefaultLocation=false`,
   the PROBE-SHELL precedent).

## Dependencies & sequencing

After wiring GREEN.
