# PRD — isolate PROBE-INTENT-DEFAULT from the real phrase file

**Issue:** #65 · **Capability:** C13 follow-on · **Phase:** P4 (probe hygiene, no gate)

## Problem

`PROBE-INTENT-DEFAULT` is asserted as a whole line by the zero-network invariant. Its
`resolver=` field is derived from the root's per-turn provider — but the store behind that
provider is built by `AppBootstrap.configure` over the **real** `intent-phrases.json`
(`IntentPhraseStore.defaultDirectory`). Two consequences:

1. **A dev machine can flip the invariant.** A real phrase file with `"keywordFallback": true`
   makes the composed provider a `CompositeIntentResolver`, and the line fails for a reason
   that has nothing to do with the code under test. The suite's own diagnostic already calls
   this "a known limitation".
2. **The probe reads user data it does not need.** The line's purpose is the *composition's*
   default, not the contents of the founder's file; an empty directory proves the same facts.

## Requirements

| ID | Requirement |
|----|-------------|
| R1 | `AppBootstrap.configure` accepts an optional `intentPhraseDirectory`, defaulted to `nil`. |
| R2 | `nil` keeps the shipped path byte-for-byte: `IntentPhraseStore.defaultDirectory(...)`. |
| R3 | The probe passes a fresh temp directory under `FileManager.default.temporaryDirectory` and removes it when the drive ends. |
| R4 | `PROBE-INTENT-DEFAULT` reports `store.location=temporary`, derived from the composed root's own store (the same evidence shape as `PROBE-INTENT-PHRASE`). |
| R5 | The guard test refuses a line that loses `store.location=temporary`, and refuses the known-limitation diagnostic. |

## Non-goals

- Changing `PROBE-INTENT-PHRASE` / `-COMPOSITE` / `-UNFILTERED` (already temp-directory drives).
- Injecting any other store's directory.
- Changing what the default resolves (`intentResolved=0` stays).

## Acceptance

1. The pinned line gains `store.location=temporary` and the whole-line assertion passes.
2. The guard test asserts the field and its value.
3. A source pin asserts `configure` carries the defaulted seam and the probe uses it.
4. `PROBE-INTENT-DEFAULT` is identical on a machine with and without a real phrase file.
