# Understanding — latency instrumentation (C7 first slice)

## What the work is really asking

P0's week-4 milestone promises "Failsafe + **telemetry-free instrumentation** — Widget retains
last transcript with ⌘C; **local-only latency/success counters**" (`docs/ROADMAP.md:86`). The
failsafe half shipped; the counters did not. ROADMAP's P0 success metrics also say latency is
"measured and recorded, but not yet a gate" (`ROADMAP.md:98`) — so this unit is P0-completing,
even though CAPABILITY_ROADMAP files the full C7 (instrumentation + warm start + widget-only
streaming) under P2. The slice is: **make the loop's own numbers observable, on-device, with a
regression gate — without touching warm start or streaming.**

## What exists to build on (verified in code)

- `EngineTiming` (VoccaASR/Parakeet/EngineTiming.swift) — actor, in-memory ledger, three
  `Kind`s; Parakeet records coldLoad/warmTranscribe/firstAfterLaunch; **whisper records
  nothing** (owns a clock, unwired). Nobody reads the ledger.
- `InjectionResult.elapsed` — ladder duration already measured per injection via injected
  clock (VoccaCore/InjectionResult.swift:41).
- `CaptureStartTiming` — the measured engine-start figures (114 ms jack / 42 ms array).
- `DictationPipeline` (VoccaCore) — the routing decision table: cancelled → idle, empty →
  idle, transcription failure → reasonOnly(.transcriptionFailed), widgetFailsafe →
  transcriptHeld, delivered rungs → idle. Every route out of a session is named here.
- `SessionMachine.elapsed` — recording duration already tracked.
- Composition root: `AppBootstrap.deliver(_:)` and `present(surface:)` fold pipeline surfaces
  into widget events — the natural place a session's outcome is observable end to end.
- Zero-network probe drives a full cycle headless (ProbeEngine stub); fixture suite + WER
  scorer exist; real-engine runs env-gated (`VOCCA_MODEL_DIR`).

## The shape of the slice

1. **A span vocabulary in VoccaCore** — capture-close / ASR / cleanup / inject, each with a
   monotonic elapsed. Cleanup has no implementation yet (C5 unbuilt): the span exists as a
   slot that records nothing today, so C5 slots in without touching the vocabulary. Pure
   stdlib types (no Foundation/Dispatch — CoreBoundaryTests forbids them).
2. **Per-session success counters** — one record per session: route taken, spans, outcome
   (delivered / held / reason-only), counters that are written on *every* exit path (abort,
   failsafe, delivery) — the "never go missing" acceptance.
3. **A local-only store** — in-memory histogram, user-inspectable; **never transmitted**
   (zero-network probe asserts no connect(2) during a measured cycle; the histogram lives in
   VoccaCore so nothing below it can send it).
4. **Benchmark harness** — headless, replays fixtures through the composed route; asserts the
   span contract end to end in CI; the real p50/p95 number is env-gated to the founder's
   machine (the WER precedent). The regression gate is a CI test that fails when the
   benchmark regresses.
5. **Honest measurement discipline** — the measure-timers lesson: record the process's
   suppression state (`getpriority(PRIO_DARWIN_PROCESS, 0)`) beside any wall-clock claim.

## Ambiguities / open questions

- **Where the counters live** (VoccaCore `LatencyLedger`-style type vs. a new module). Core
   is the natural home: vocabulary + zero network, and Bootstrap/UI can read it.
- **Cleanup span semantics** — absent today; record as `nil`/skipped, or 0? (Proposal: absent
  spans are recorded as "not present", never fabricated as 0.)
- **Persistence** — in-memory only for this slice, or a small on-disk tail like the journal
  (which is `FileManager`-gated to one file)? The brief says "local-only histogram the user
  can inspect" — a UI surface is out of scope (no settings surface exists; C11/P3 territory),
  but a headless "inspect" (print/read) path is in.
- **Success counter definition** — "success" = transcript reached the target app
  (rung delivered), vs. reached the user (failsafe held counts as success-with-caveat)?
  P0's metric is "first-method-success ≥90%" — the counter should record rung used +
  verified, so the P0 matrix metric is derivable from it.
- **Regression gate thresholds** — CI runs stubs only; the gate can assert *contract*
  (spans present, no network) and *relative* regression (a seeded slow span fails the gate),
  not absolute p50/p95. Absolute numbers stay the founder's env-gated run.

## Contradictions / flags

- `WhisperCppEngine.swift:67-68` owns a clock "for C7's latency ledger" — the slice should
  wire whisper's recording to match Parakeet's, or the ledger is only half-populated.
- The brief names a "cleanup" span, but cleanup (C5) is unbuilt and phase-gated behind the
  P0→P1 gate; the span is vocabulary-only this slice — do not build cleanup.
- Nothing may enter the OSS core that transmits telemetry; the "never transmitted" assertion
  is a hard requirement, not a preference (R11, ROADMAP.md:310).

## Placement

Layer: the loop itself (capture → ASR → inject) plus its outcome accounting. Phase: P2 by
capability tag, but this slice completes P0's milestone 7 — it does not advance past any gate.
