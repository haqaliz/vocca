# Aspect spec — `probe-full-cycle`

Parent: `docs/planning/dictation-loop/prd.md` (R7). Module: `Sources/VoccaNetworkProbe`,
`Tests/HarnessTests` (ZeroNetworkTests coverage guard).

## Problem slice

The zero-network probe drives the session lifecycle and two ladder runs, but the
`VoccaAudio`/`VoccaASR` entries in its module witness list are placeholders
(`VoccaNetworkProbe.swift:245-255`) and the coverage guard
(`ZeroNetworkTests.swift:730-757`) fails on any module not driven. The loop unit must
prove its composed root makes zero `connect(2)` calls end to end.

## In scope

1. **Probe-side fakes**: a `CaptureGraphSeam` fake with scripted ring writes (the
   `AudioRingBuffer` is `VoccaAudio`-owned; the probe drives `MicrophoneSource` over the
   seam exactly as `MicrophoneSourceTests` does), a stub `ASREngine` (the `StubEngine`
   shape, probe-local), and the existing probe ladder fakes.
2. **A full dictation cycle** driven through the composed root's wiring: press → opening
   → mic opens (fake graph delivers frames) → release → `.ended` → engine transcribes
   (stub) → injector runs (probe fakes) → result reported. Runs inside
   `exerciseDefaultConfiguration()` following the `@MainActor` semaphore+run-loop pattern
   of `InjectionDrive.swift:158-176`.
3. **Witness list + coverage guard**: `VoccaAudio` and `VoccaASR` are driven for real;
   placeholders removed; the guard's expected module set matches the probe's
   `PROBE-MODULES` line.
4. **Guard-the-guard intact**: the deliberate-connect positive/negative controls
   (`ZeroNetworkTests.swift:257,441,565`) still pass.

## Out of scope

Real-engine inference in the probe (env-gated WER suites stay the real-model execution
path); widget/window code (nothing in the probe touches the window server); anything
beyond the default configuration.

## Acceptance (test-first)

1. The extended drive reports a full-cycle result (frames in, transcript out, rung out).
2. `PROBE-OK` with zero `connect(2)`; the coverage-guard equality assertion passes.
3. A deliberate `connect(2)` still trips the interposer (controls unchanged).
4. Full suite green via `Scripts/test-with-floor.sh`.

## Dependencies / sequencing

After `loop-wiring` (it drives the composed root). `smoke-checklist` can reference its
results. No dependency on `widget-live-states`.
