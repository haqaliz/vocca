# Dictation loop — wire capture → ASR → injection + live widget states

> Source: inline brief (no GitHub issue filed — `gh issue list` returns "No Issues" for
> this repo). Handed off from the `vocca-next` session on 2026-08-12, which picked this
> as the single highest-leverage unshipped capability.

## Brief

Build the P0 dictation loop: wire hotkey → session machine → MicrophoneSource → ASREngine
(Parakeet/whisper selection) → LadderInjector → failsafe in `AppBootstrap.configure`, and
ship the minimal live widget states (IDLE → RECORDING with a waveform driven by real input
level → TRANSCRIBING → collapse), per `docs/planning/_card/understanding.md:114-116`, which
names this as the follow-on unit once `audio-capture` merges (it merged 2026-08-12, `84f4817`).

The completeness bridge already shipped in `MicrophoneSource.swift:191` — do not rebuild it.

Caveat: no part of the loop runs in CI (no Accessibility/TCC/mic on a hosted runner), so
acceptance is test-first over the existing seams: a composed-loop test driving the real
session machine with fake source/engine/injector that asserts the transcript reaches the
injector and the widget state transitions IDLE→RECORDING→TRANSCRIBING→IDLE/FAILSAFE; the
zero-network probe extended to drive a full dictation cycle through the composed root; a
level→waveform mapping test headless; and a `SMOKE_CHECKLIST` entry for the first real
speak→waveform→text-lands run on the founder's machine (steps 22–35 precedent).

Wire hold-to-talk and the toggle configuration of the same machine through the root, per
the session-lifecycle spec.

## Context pulled from the repo (vocca-next run)

- P0 building blocks are all merged on `master` as of 2026-08-12:
  - C1 hotkey + session machine + watchdog + tap adapter (project-skeleton, hotkey-source,
    session-lifecycle aspects; `feat/audio-capture/aliz` merged as `84f4817`).
  - C1 audio capture: `VoccaAudio/AudioCaptureGraph.swift`, `MicrophoneSource.swift`
    (the `SessionAudioSource` conformance; `missingSampleCount` filled from the ring's
    `refusedSampleCount` at `MicrophoneSource.swift:191`).
  - C2 local ASR: `ASREngine` seam in `VoccaCore`; Parakeet in `VoccaASR/Parakeet/`.
  - C3 second ASR engine: whisper.cpp in `VoccaASR/Whisper/`; engine selection value
    (`EngineSelection`) with its decision table.
  - C4 injection ladder: `LadderInjector` in `VoccaInject/Ladder/`; failsafe surface in
    `VoccaUI` (`FailsafePanel`); `TranscriptHolder` single-slot seam in Core.
- **Not shipped:** any composition root wiring (`AppBootstrap.configure` only sets the
  activation policy — `AppBootstrap.swift:52`), the live widget states (only FAILSAFE,
  EnginePicker and DownloadProgress surfaces exist in `VoccaUI`), and the C7 latency
  instrumentation (out of scope here; P2 owns the numbers).
- `PRODUCT_SPEC.md` owns the widget's user-visible behavior: IDLE → OPENING → RECORDING
  (live waveform, "it heard me" signal) → TRANSCRIBING → DELIVERED, plus FAILSAFE;
  Reduce Motion maps the waveform to a static level meter.
- `ROADMAP.md` P0 milestone week 1: "`⌥Space` down/up drives `AVAudioEngine`; widget shows
  a live waveform | 100 press/release cycles, zero missed or stuck sessions".
- The P0 gate (`ROADMAP.md:100-104`) — founder dictates daily for 7 days — is
  un-attemptable until this loop exists. C5/C7/C8 (P1/P2) are phase-gated behind it.
- Test floor: 623 tests in `Tests/HarnessTests/`, run via `Scripts/test-with-floor.sh`
  (a bundle contract per config + the headless suite under strict concurrency).
