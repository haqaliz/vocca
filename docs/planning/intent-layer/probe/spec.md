# Aspect spec: probe

> Source: `docs/planning/intent-layer/prd.md` R7, R9, R10 · Branch `feat/intent-layer/aliz`
> · Date 2026-09-22.

## Problem slice and user outcome

The composition root wires the intent machinery additively and the zero-network probe
drives it: the shipped default resolves nothing and spawns nothing, the full voice round
trip is exercised inside the interposer, and the dictation path stays byte-for-byte
untouched.

## In-scope requirements

- `AppBootstrap.configure` gains the additive intent composition (the C11/C12/C13 shape,
  `AppBootstrap.swift:642-684` precedent): `IntentWiring` composed over the shared
  executor (`root.actionExecutor`), the enablement catalog, and — per R7 — the
  `NullIntentResolver` in the default configuration (unwired posture, `intentResolved=0`).
  New nullable root slots on `DictationLoopRoot` (`intentWiring`, `intentResolver`
  facts).
- `Sources/VoccaNetworkProbe/IntentDrive.swift` — the PROBE-INTENT drive composing the
  recipe over probe doubles (stub provider over real temp stores or `InMemoryMCPTransport`):
  utterance → resolve → gate → confirmationRequired → card → confirm → audit row
  reconstructs. Default-configuration facts: `intentResolved=0`, `spawnsSubprocess=false`.
  The drive mints the module witness; the report is an effect-not-reference string.
- `Tests/HarnessTests/ZeroNetworkTests.swift` — the quartet: `expectedIntentLifecycle`
  constant (fields each an effect of the run), the verbatim assertion on the
  default-configuration run, the `intentPayload(of:)` accessor, and the guard-the-guard
  test (fails closed on empty/malformed/repeated fields, refuses a weakened constant).
- The wiring-family lint leg: the intent families confined to
  `{IntentWiring.swift, AppBootstrap.swift, IntentDrive.swift}` (+ the Core seam files);
  planted-violation and comment-strip controls.
- **G5 re-anchor:** `AppBootstrap.swift`'s digest recomputed in the same commit as the
  wiring (never edit-to-match); the dictation digests (`SessionMachine.swift`,
  `DictationPipeline.swift`) unchanged.

## Out-of-scope boundaries

- No new probe mode (intent rides the default-configuration path, the
  `PROBE-ACTIONS`/`PROBE-CONVERSE` precedent). No `Process`, no spawn, no network. No
  change to the interposer or the module-coverage set (no new module).

## Acceptance criteria (test-first)

1. The default-configuration run reports `intentResolved=0` and `spawnsSubprocess=false`,
   verbatim against the expected constant.
2. The guard-the-guard test refuses a weakened/empty/malformed constant.
3. The PROBE-INTENT drive's own composition completes a full voice round trip (resolve →
   confirm → audit row) over real temp stores.
4. The wiring-family lint refuses a planted violation and survives comment stripping.
5. The dictation digests are unchanged; `AppBootstrap.swift`'s digest is re-anchored in
   the same commit (the pin test's constant updated deliberately).

## Dependencies and sequencing

Depends on `intent-seam`, `converse-step`, and `action-round-trip` (the recipe). Last
code aspect before `record`.

## Open questions / risks

The probe's stub provider must expose a call log (the `ProbeActionProvider` shape) so the
"confirm → invoke exactly once" effect is observable. The expected-lifecycle fields must
each be an effect of the run — a field the drive could fake without the guard noticing is
called out per-field (the `spawnsSubprocess=false` precedent,
`ZeroNetworkTests.swift:1881-1885`).