# Latency instrumentation — C7 first slice (local-only spans + success counters)

> Source: inline brief (no GitHub issue filed — `gh` reports no issues for this repo).
> Handed off from the `vocca-next` session on 2026-08-14, which picked this as the single
> highest-leverage unshipped capability.

## Brief

Build C7's first slice: local-only latency/success instrumentation for the dictation loop —
the unshipped half of P0 week-4 milestone 7 (`docs/ROADMAP.md:86`). Instrument the loop with
named capture-close / ASR / cleanup / inject spans plus per-session success counters, rendered
as a local-only histogram the user can inspect; a test asserts zero network calls and that no
span is ever transmitted, and a headless benchmark replays the existing fixture suite asserting
the span contract end-to-end (the real p50 ≤ 400 ms / p95 ≤ 800 ms run is env-gated on the
founder's machine, like the WER tests — CI runs stubs, and the measure-timers suppression-state
discipline applies). Acceptance tests come first: span accounting for every route into and out
of a session, counters that never go missing on aborts/failsafe paths, and the regression-gate
test that fails CI when the benchmark regresses. Caveat: real numbers need the real engine on
M-series hardware; CI proves the plumbing, the founder's machine sets the numbers. Deferred to
later C7 slices: warm start and widget-only streaming partials.

## Context pulled from the repo (vocca-next + deep-dig runs)

- Everything the loop is made of shipped on `master` as of 2026-08-12 (C1 capture+hotkey,
  C2 Parakeet ASR, C3 whisper.cpp, C4 injection ladder, dictation-loop unit). P0 milestone 7's
  *failsafe* half shipped; its *"local-only latency/success counters"* half did not.
- The numbers exist but nothing reads them:
  - `EngineTiming` (`Sources/VoccaASR/Parakeet/EngineTiming.swift`) — actor with an in-memory
    ledger of coldLoad / warmTranscribe / firstAfterLaunch samples; Parakeet records,
    whisper does not (it owns a clock, unwired). Doc comment: "C7's latency work reads the
    ledger."
  - `InjectionResult.elapsed` (`Sources/VoccaCore/InjectionResult.swift:41`) — ladder duration
    per session already measured via the injected `MonotonicClock`.
  - `CaptureStartTiming` (`Sources/VoccaCore/CaptureStartTiming.swift`) — 114 ms jack / 42 ms
    array numbers recorded so "C7 would optimise against the right figure".
- No histogram/span code exists anywhere in `Sources/` (only spike tools have private
  stopwatches). The recovery journal writes only failsafe-held transcripts, no timings.
- CI can't run the real loop (no mic/TCC/AX); the zero-network probe
  (`Sources/VoccaNetworkProbe/`) drives a full dictation cycle through the composed root with
  stub engine; the fixture suite (`Tests/Fixtures/*.wav`) + `WER` scorer exist; real-engine
  runs are env-gated via `VOCCA_MODEL_DIR` (`ParakeetEngineWERTests`, `WhisperCppEngineWERTests`).
- Measurement discipline precedent: `Scripts/measure-timers.sh` records
  `getpriority(PRIO_DARWIN_PROCESS, 0)` beside every row (suppression state) and runs under
  `taskpolicy -b`.
- `ARCHITECTURE.md:589` names the benchmark harness (replays fixtures, asserts p50/p95, fails
  CI on regression) as C7's deliverable; `docs/planning/injection-ladder/prd.md:220` and
  `docs/planning/dictation-loop/prd.md:201` defer all of C7 explicitly.
- Phase placement: C7 is tagged P2 in `CAPABILITY_ROADMAP.md`, but its instrumentation slice
  completes P0's own week-4 milestone; P0 records latency, P2 gates it (`ROADMAP.md:98`).
- Test floor: 836 tests via `Scripts/test-with-floor.sh`.
