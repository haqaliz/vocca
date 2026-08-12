# Aspect spec — `widget-live-states`

Parent: `docs/planning/dictation-loop/prd.md` (R4, S2). Module: `VoccaUI` (imports only
`VoccaCore` — `ModuleBoundaryTests.swift:297-305`), `VoccaCore` (seams), `VoccaAudio`
(level conformance).

## Problem slice

The widget ships only FAILSAFE today. The loop needs the five P0 states — IDLE / OPENING
/ RECORDING / TRANSCRIBING / DELIVERED — as a **projection** of the machine's effects
(`ARCHITECTURE.md:355`: the machine is the only place session state lives), with a
waveform that tracks real input level (`PRODUCT_SPEC.md:87-88`), the spec's timers, and
Reduce Motion handling (`:289`). The widget never takes focus (`:22`).

## In scope

1. **Core-owned effect projection**: `VoccaUI` gains a headless reducer (the
   `FailsafeState`/`EnginePickerState` precedent) mapping `SessionEffect`s +
   `SessionOutcome` content into the widget state set; every transition pinned by tests
   (effect-by-effect agreement with the machine).
2. **States and spec behaviors**:
   - IDLE: thin dormant pill.
   - OPENING: entered on key-down within one frame; target app named (`→ Slack`); no
     waveform (`PRODUCT_SPEC.md:33-38`).
   - RECORDING: live waveform from real input level; elapsed timer after 3 s; "esc to
     cancel" after 2 s; 110 s ceiling warning (`:86-90,129`).
   - TRANSCRIBING: waveform freezes, indeterminate progress (`:93-95`).
   - DELIVERED: ✓ + target for ~600 ms, then collapse (`:50,98`).
   - FAILSAFE: existing surface, unchanged.
3. **Level seam**: a Core protocol (`LiveLevelSource`) the reducer/views consume,
   fakeable headless; `VoccaAudio` ships the real conformance — a peak published by the
   capture graph's realtime callback, read on the main actor. Waveform mapping
   (level → bar heights) is a pure function, table-tested. A canned waveform is a spec
   violation (`:88`).
4. **Timers via an injected clock** (the `TestClock` precedent): the 3 s / 2 s / 110 s /
   600 ms transitions are time-based only in the projection layer and are driven by the
   reducer's clock in tests — the reducer itself stays decision-pure.
5. **Reduce Motion**: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` maps
   the waveform to a static level meter (`:289`), headless-tested via the injected flag.
6. **Views**: SwiftUI pill + states, non-activating presentation matching `FailsafePanel`
   conventions (never takes focus), target label, waveform view, progress view.

## Out of scope

CONVERSING (P3); sounds; settings; waveform smoothing/audio processing beyond the level
mapping; any state the machine does not emit (the projection cannot invent states).

## Acceptance (test-first)

1. RED first: projection reducer decision-table tests; level→bar mapping tests; timer
   tests over the injected clock; Reduce Motion mapping tests.
2. IDLE→OPENING within one frame of the machine's `.opening` effect; RECORDING only
   after the machine reports it — the projection never claims the mic is open before the
   machine does.
3. Waveform input is the real level source when present — asserted by wiring the
   conformance test and by the smoke checklist's first-execution step.
4. Full suite green via `Scripts/test-with-floor.sh`.

## Dependencies / sequencing

Consumes the machine's effect stream (already exists). Parallel with `loop-wiring` for
the reducer half; the root wiring that feeds the effect stream and owns the level source
lands in `loop-wiring`'s root phase.

## Open questions

- Waveform refresh cadence (target ~60 ms) is plan-level; the level read must not block
  the realtime callback.
