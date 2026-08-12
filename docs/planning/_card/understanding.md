# Dictation loop — understanding (Phase 2)

## What this unit really is

The last unshipped piece of P0. Every seam of the dictation loop exists as tested code
(C1 capture + session machine, C2/C3 ASR, C4 injection + failsafe); nothing connects them,
and the app's composition root (`AppBootstrap.configure`, `Sources/VoccaBootstrap/AppBootstrap.swift:52-68`)
only sets the `.accessory` activation policy. This unit wires the loop and ships the live
widget states the product spec owns.

## Affected areas (from the dig)

1. **Session → ASR handoff.** The machine hands outcomes out through the `deliverEffect`
   closure (`SessionEventSink.swift:54,62-64`); `.ended(SessionOutcome)` is the only route
   by which audio leaves (`SessionEffect.swift:53-59`), and `outcome.content.audio` is
   already the ASR seam's type — `AudioBuffer` (`AudioBuffer.swift:99`). There is no
   intra-machine hook; the wiring matches on `.ended` and calls `engine.transcribe(_:)`.
2. **ASR construction.** One engine per session start, resolved once
   (`EnginePickerView.swift:28-39`, pinned by `EngineSelectionConsumptionTests`): a
   `ModelStore` + shipped `ModelManifest` + transport + clock build `ParakeetEngine` or
   `WhisperCppEngine`; `prepare()` once; `transcribe` per buffer. Selection source is
   `EnginePickerState.selection` (default Parakeet v3).
3. **Injection.** `LadderInjector.inject(_:into:)` (`VoccaInject/Ladder/LadderInjector.swift`)
   with `DefaultInjectionStrategyOrder(allowlist: SeededInjectionAllowlist())`; the
   failsafe handoff is `JournalTranscriptHolder` (durable before `hold` returns), which is
   both the ladder's `FailsafeHandoff` and the panel's `TranscriptHolder`. `.widgetFailsafe`
   is a **success** outcome under invariant I1. The panel is presented by the root *after*
   `inject` answers `.widgetFailsafe` — the seam has no push.
4. **Widget states.** `PRODUCT_SPEC.md:24-68` owns the states; the one-frame IDLE→RECORDING
   claim is amended (`:105-127`, measured 42/114 ms engine start → OPENING comes first).
   Waveform tracks real input level (`:87-88`), Reduce Motion → static level meter
   (`:289`), widget never takes focus (`:22`). `VoccaUI` imports only `VoccaCore`
   (`ModuleBoundaryTests.swift:297-305`) — live states land there behind a Core-owned
   state projection, mirroring the `FailsafeState`/`EnginePickerState` reducer precedent.
5. **Composition root.** `VoccaBootstrap` currently depends on nothing
   (`Package.swift:108-112`); wiring it means a deliberate, reviewed dependency change.
   The zero-network probe must drive the composed root — `VoccaAudio`/`VoccaASR` are
   placeholders in its module witness list and the coverage guard
   (`ZeroNetworkTests.swift:730-757`) fails on any module not driven.
6. **Toggle mode.** The session machine already has toggle as a second configuration
   (session-lifecycle spec); the root wires both hold-to-talk and toggle. The accessibility
   requirement is at `PRODUCT_SPEC.md:291` (the `:257` cite in `CAPABILITY_ROADMAP.md:36`
   is stale — flag for correction).

## Constraints that shape the plan

- **Test-first over seams, always.** No part of the loop runs in CI: no Accessibility grant,
  no TCC, no microphone (`CLAUDE.md`; `SMOKE_CHECKLIST.md`). Acceptance = composed-loop
  tests over fakes (the `SessionTestDoubles`/`ASRTestDoubles` precedent) + the probe driving
  a full cycle + a `SMOKE_CHECKLIST` entry for the founder's machine.
- **Zero-network invariant is a release blocker.** Anything wired into
  `AppBootstrap.configure` is inside the probe's reach — that is the point of the module
  (`AppBootstrap.swift:20-30`).
- **`VoccaApp.swift` is pinned** character-for-character by
  `BundleConfigurationTests.testAppTargetSourceIsOnlyAShimToTheBootstrapModule`
  (`BundleConfigurationTests.swift:484-516`) — all wiring goes in the package.
- **SessionMachine is the only place session state lives** (`ARCHITECTURE.md:355`) — the
  widget renders a projection; the machine must be the source of truth for
  IDLE/RECORDING/TRANSCRIBING transitions.
- Test floor: 623 tests, run via `Scripts/test-with-floor.sh`; strict concurrency, any
  warning fails CI.

## Open questions for the interview

1. **Widget state span**: does the loop unit ship OPENING + DELIVERED too, or only
   IDLE/RECORDING/TRANSCRIBING (per the handoff brief)? PRODUCT_SPEC owns all states;
   CONVERSING stays P3 regardless.
2. **Where the waveform's level comes from**: the spec says "tracks input level" — the
   capture graph's tap delivers frames; the projection must publish a level the widget
   observes (MainActor-safe). Fakeable headless.
3. **What happens on ASR failure mid-loop**: engine unavailable / prepare failed — the
   transcript-holder invariant says nothing is lost; raw text path? error to failsafe with
   a reason? (Cleanup is P1 — no cleanup in the loop; the injector takes the raw
   transcript.)
4. **Probe scope**: full composed cycle through the probe (microphone over a fake graph
   seam + stub engine + ladder with probe fakes) — confirm that's in scope for this unit
   vs. a lighter "wire but assert at seam boundaries" shape. (The coverage guard pushes
   toward driving the real modules.)
5. **Empty/short utterance policy**: a 20 ms press yields an empty buffer; engine policy
   says an empty buffer → empty transcript. Should the loop skip injection for empty text?
   (No injection call for `text == ""`?) PRODUCT_SPEC silent about it.
