# Aspect spec — `loop-wiring`

Parent: `docs/planning/dictation-loop/prd.md` (R1, R2, R3, R6, S1). Modules: `VoccaCore`
(new decision/orchestration types), `VoccaBootstrap` (composition root), `VoccaInject`
(public adapter surface), `Package.swift`, `Tests/HarnessTests`.

## Problem slice

The seams exist and nothing connects them: `AppBootstrap.configure` sets only the
activation policy (`AppBootstrap.swift:52-68`). This aspect is the composed loop —
hotkey → session machine → `MicrophoneSource` → ASREngine → `LadderInjector` → failsafe —
with the engine lifecycle, honest refusal, cancellation, empty-text and target-at-key-down
semantics, and the toggle configuration. The machine is **untouched** (its `deliverEffect`
closure is the only hand-off point; `SessionEffect.swift:53-59`).

## In scope

1. **A Core-owned pipeline decision** (headless-testable, no window/AppKit): given a
   `SessionEffect.ended(SessionOutcome)` plus an `ASREngine`, a `TextInjector` and a
   `TranscriptHolder`, decide and execute:
   - `.cancelled` outcome → discard, no transcribe, no inject (Esc-cancel; `PRODUCT_SPEC.md:129`).
   - empty text (short press) → no injector call, no failsafe, straight to idle.
   - non-empty text → `transcribe` → `inject` → on `.widgetFailsafe` present the held
     transcript; on transcribe failure → `.transcriptionFailed` notice.
2. **Engine lifecycle**: resolve the selection once at launch
   (`EnginePickerState.selection`, default `.parakeetV3`); background `prepare()` with
   the existing download UI (`ModelDownloadSession`); per-session readiness gate — an
   unprepared engine refuses honestly with `.modelUnavailable` and the session never
   opens the microphone.
3. **Composition root**: `AppBootstrap.configure` builds the machine
   (`SessionMachine(configuration:ceiling:clock:audioSource:captureStartTiming:
   .whenTheOwnerAsks)`), `ScheduledWatchdog` (shipping `deferOpening`), `TapHealthTimer`
   root ownership, `CGEventTapSource.start(delivering:)`, `MicrophoneSource(AudioCaptureGraph)`,
   the engine + `LadderInjector` (seeded allowlist, `JournalTranscriptHolder` as handoff
   and panel holder), `TargetResolution`, and the failsafe panel — and wires the effect
   stream to both the pipeline and the widget projection. Probe-safe (no run-loop
   dependency in `configure`; tap `.unavailable` without a grant is logged, not fatal).
4. **Target resolution at key-down** (S1): resolve `TargetContext` on key-down, display
   in the widget's OPENING/RECORDING states, inject into that same context at key-up.
   Requires making `AXSource`/`SystemSecureInputRead` (or a public factory over
   `TargetResolution`) reachable from `VoccaBootstrap` — they are `internal` today
   (`AXSource.swift:59`, `SecureInputRead.swift:42`); H7 seam lints still hold (one file
   per system family, unchanged).
5. **Toggle configuration** (R6): the same machine, `activation: .toggle`; wired and
   machine-level tested; bounded by ceiling + tap-disabled stop + system triggers (per
   session-lifecycle spec). No visible control (settings surface is out of scope).
6. **Package/module changes**: `VoccaBootstrap` gains its dependencies
   (`Package.swift:108-112`); `ModuleBoundaryTests` updated where the composition-root
   rules require.
7. **The composed-loop acceptance test** (R8-1): 100 cycles over the seams — fake hotkey
   events, `RecordingSource`, `StubEngine`, probe-style injector fakes — 100 started, 100
   ended, 0 overlapping, 0 orphaned, 100 transcripts delivered or failsafe-held; failure
   injection: engine throws → notice; ladder exhausts → FAILSAFE holds; empty buffer →
   no injector call; cancelled session → no injector call.

## Out of scope

Live widget states (see `widget-live-states`); the probe's full cycle (see
`probe-full-cycle`); engine picker persistence (C14); sounds; settings; cleanup (P1).

## Acceptance (test-first)

1. RED first: the composed-loop test, pipeline decision-table tests (cancelled / empty /
   failure / exhausted), engine-lifecycle tests (readiness gate, resolve-once).
2. Cancelled session never injects; empty text never calls the injector; unprepared
   engine never opens the mic.
3. Every terminal path ends in an injector call, a journaled hold, or a reason notice —
   zero transcript loss (I1), asserted by the failure-injection suite.
4. Full suite green via `Scripts/test-with-floor.sh`; strict concurrency clean.

## Dependencies / sequencing

`failure-surfaces` first (the refusal gate and failure paths produce its reasons).
`widget-live-states` reducer can proceed in parallel (it consumes the same effect stream);
the root wiring that joins them lands here. `probe-full-cycle` last.

## Open questions

- App display name for the target indicator (bundle ID → "Slack"): resolve via
  `NSRunningApplication` in the root (AppKit is already imported there).
