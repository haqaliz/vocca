# PRD — Dictation loop (wire capture → ASR → injection + live widget states)

> Phase: **P0** (last unshipped piece of the P0 core dictation loop). Unit slug:
> `dictation-loop`. Branch: `feat/dictation-loop/aliz`. Source: `_card/issue.md`
> (inline brief, approved via vocca-next 2026-08-12) + `_card/understanding.md`.

## Problem statement

Every seam of the P0 dictation loop exists as tested code — capture (`VoccaAudio`),
session lifecycle (`VoccaCore`), ASR (`VoccaASR`), injection + failsafe (`VoccaInject`,
`VoccaUI`) — and nothing connects them. `AppBootstrap.configure` sets only the activation
policy (`Sources/VoccaBootstrap/AppBootstrap.swift:52-68`), the widget ships only the
FAILSAFE surface, and the P0 gate — the founder dictating daily for 7 days
(`ROADMAP.md:100-104`) — is un-attemptable. The product, as a product, does not exist yet;
it is a library of seams. This unit makes it a tool.

Evidence this is the right next unit: `docs/planning/_card/understanding.md:114-116`
names loop wiring as the follow-on once `audio-capture` merges (it merged 2026-08-12,
`84f4817`); C5/C7/C8 are phase-gated behind the P0 gate (`ROADMAP.md:102-104`).

## Goals & success metrics

1. **A dictation cycle completes end to end on the founder's machine**: `⌥Space` down →
   OPENING → speak → RECORDING (live waveform) → `⌥Space` up → TRANSCRIBING → text lands
   in the focused field → DELIVERED → IDLE. Or, on any failure, FAILSAFE holds the text.
   First-execution pass/fail (a `SMOKE_CHECKLIST.md` entry, the `steps 22-35` precedent):
   in **Notes and TextEdit**, a 10-second utterance lands **verbatim**; a Secure Input
   field shows the reason-only notice and never receives text; `Esc` during RECORDING
   and during TRANSCRIBING discards and injects nothing; a short press (≈80 ms) returns
   to IDLE with no injector call; no crash and no stuck session across 20 cycles.
2. **The widget tells the truth about the microphone** (`PRODUCT_SPEC.md` principle 1,
   `:105-127`): state transitions come from the session machine's effects — the machine
   remains the only place session state lives (`ARCHITECTURE.md:355`) — and the waveform
   tracks real input level, never a canned animation (`PRODUCT_SPEC.md:87-88`). Pinned by
   a headless effect→projection test.
3. **Zero transcript loss, unchanged** (invariant I1): every `.ended` with non-empty text
   terminates in an injector call or a journaled failsafe hold. Pinned by a failure-
   injection test over the composed loop.
4. **Zero network in the default configuration, unchanged** (invariant I2): the zero-
   network probe drives a **full dictation cycle through the composed root**, and the
   coverage guard (`ZeroNetworkTests.swift:730-757`) passes with `VoccaAudio`/`VoccaASR`
   driven rather than placeholder.
5. **Session reliability**: 100 composed cycles over the seams — 100 started, 100 ended,
   0 overlapping, 0 orphaned, 100 transcripts delivered — the C1 acceptance extended to
   the loop.
6. Suite stays green under strict concurrency; test floor rises (623 today,
   `Scripts/test-with-floor.sh`).

## Personas & scenarios

**The founder (ICP stand-in).** A Mac user who dictates all day and will not ship audio to
the cloud. Scenario: cold install on a clean Mac → permissions granted → app launches →
model downloads in the background while the download window shows progress → first
dictation lands polished* text in Notes → a password field refuses honestly via FAILSAFE.
(*"Polished" is P1; P0 delivers raw ASR text — `ROADMAP.md:72`.)

**An accessibility-first user.** Hold-to-talk is impossible for them; the toggle
configuration of the same machine (`PRODUCT_SPEC.md:291`) must be wired through the root
and honest: a toggle session is bounded by the 120 s ceiling, the tap-disabled stop and
the system triggers, per the session-lifecycle spec.

## Requirements

### Must-have

**R1 — The composed loop (root wiring).** `AppBootstrap.configure` wires: hotkey tap →
`SessionEventSink`/`ScheduledWatchdog` → `SessionMachine` with `MicrophoneSource`; the
`deliverEffect` closure (the single route by which audio leaves the machine —
`SessionEffect.swift:53-59`) matches `.ended`, reads `outcome.content.audio`
(`AudioBuffer`, already the ASR seam's type), transcribes, and injects. No intra-machine
hooks; the machine is untouched.

**R2 — Engine lifecycle.** The selected engine (`EngineSelection`, default Parakeet v3)
resolves once at launch and `prepare()` runs in the background with the existing download
UI (`ModelDownloadSession` seam); the session re-resolves the engine at its start
(resolve-once, `EngineSelectionConsumptionTests` precedent) and refuses honestly — via
the R5 notice — if the engine is not prepared, instead of recording into a void. Per-
session swap behavior is unchanged: only `engineIdentity` differs at the boundary.

**R3 — Injection routing.** On `.ended` with non-empty text: `LadderInjector.inject(_:into:)`
with the seeded allowlist order (`DefaultInjectionStrategyOrder(allowlist:
SeededInjectionAllowlist())`) and `JournalTranscriptHolder` as both `FailsafeHandoff` and
panel `TranscriptHolder`. `.widgetFailsafe` is a success outcome under I1. **Empty text
(short press) skips injection entirely** — no injector call, no failsafe (nothing was
said and nothing is lost), straight back to IDLE. **A cancelled session never injects**:
the wiring checks the outcome's cancelled/completed shape (`SessionOutcome.swift:93-101`),
and `Esc` during TRANSCRIBING cancels the in-flight transcribe and discards its result
(`PRODUCT_SPEC.md:129`) — aborting a dictation must not type it into the field.

**R4 — Live widget states.** `VoccaUI` gains the P0 state set — IDLE / OPENING /
RECORDING / TRANSCRIBING / DELIVERED / FAILSAFE (CONVERSING is P3) — as a headless
reducer over the machine's effects (the `FailsafeState`/`EnginePickerState` precedent,
`ModuleBoundaryTests.swift:297-305` constrains `VoccaUI` to import only `VoccaCore`):
- OPENING within one frame of key-down, target app named (`PRODUCT_SPEC.md:33-38,78-79`).
- RECORDING: live waveform from real input level; elapsed timer after 3 s; "esc to
  cancel" after 2 s; the 110 s ceiling warning (`PRODUCT_SPEC.md:86-90,129`).
- TRANSCRIBING: waveform freezes, indeterminate progress (`:93-95`).
- DELIVERED: ✓ + target for ~600 ms, then collapse (`:50,98`).
- Reduce Motion → static level meter instead of waveform (`:289`).
- The widget never takes focus (`:22`).

**R5 — Honest failure surfaces.** `FailsafeReason` gains **two** cause-specific cases,
each with its own copy-table entry and journal-safe spelling (the `FailsafeReason.swift:28-41`
enum and the FAILSAFE copy table both extend; a reason that lies about the cause is worse
than one that says exhausted):
- `.modelUnavailable` — engine not prepared when the session started (model still
  downloading / missing): "Voice processing isn't ready yet — try again in a moment."
- `.transcriptionFailed` — `prepare()` or `transcribe()` failed mid-loop: "Voice
  processing failed. Nothing was lost — you can try again."

Both render as a **reason-only** FAILSAFE notice (no held text — there is none; the
panel's text area shows the reason, ⌘C/⏎ disabled for this variant). Dismissable; never
auto-dismissed (reducer stays time-free).

**R6 — Toggle configuration through the root.** Both hold-to-talk and the toggle
configuration of the same machine are wired and machine-level tested (the toggle has no
physical key-up; it is bounded by ceiling + tap-disabled stop + system triggers per the
session-lifecycle spec). The visible toggle control belongs to the settings surface — out
of scope here.

**R7 — The probe drives the composed loop.** `VoccaNetworkProbe` exercises a full
dictation cycle through the real machine, real watchdog, real injector, stub engine, and
a fake capture-graph seam — asserting zero `connect(2)` calls — and the module witness
list gains the modules it now actually drives.

**R8 — Acceptance is test-first, in this order.** (1) Composed-loop test over the seams
(100 cycles, fake source/engine/injector; state projection pinned effect-by-effect;
failure injection: engine throws → R5 notice; ladder exhausts → FAILSAFE holds text;
empty buffer → no injector call). (2) Probe extension (R7). (3) Level→waveform mapping
headless. (4) `SMOKE_CHECKLIST.md` entries: the loop's first real execution
(speak → waveform → text lands), engine-readiness refusal, Secure Input through the loop,
a toggle session, a short press.

### Should-have

- **S1 — Target resolution at key-down**: `TargetContext` (bundle ID, window title) is
  resolved on key-down and shown in OPENING/RECORDING/DELIVERED ("→ Slack"); the same
  context is injected into at key-up. A focus change mid-session does not retarget — the
  widget already said where it was going (`PRODUCT_SPEC.md:70`).
- **S2 — Ceiling warning copy** at 110 s (part of R4's timer set).

### Nice-to-have

- **N1 — Soft tick / confirmation sounds** (spec: optional, default ON, defeatable).
  Blocked on a settings surface existing; deferred.

## Technical considerations

- **Phase and gating**: P0. Completes `ROADMAP.md:80-87`'s milestones (hotkey+capture,
  ASR, second engine, ladder, failsafe are shipped; this is the loop that joins them and
  the first thing that can attempt the `🚦` gate at `ROADMAP.md:100-104`).
- **Composition root**: wiring lives in `VoccaBootstrap.configure` (drivable by the
  probe — `AppBootstrap.swift:20-30`); `App/VoccaApp.swift` stays the pinned shim
  (`BundleConfigurationTests.swift:484-516`). This is a deliberate dependency change:
  `VoccaBootstrap` gains edges in `Package.swift:108-112`; `ModuleBoundaryTests`
  (composition-root rule, `:200-220`) is updated accordingly.
- **Latency budget**: P0 records, P2 owns the numbers (`ROADMAP.md:98`). But the wiring
  must not add decisions to the critical path: no work between key-up and transcription
  that the machine already does; ASR runs after `.ended`; the OPENING state exists
  precisely because `AVAudioEngine.start()` is 42–114 ms (`CaptureStartTiming`).
- **Injection reliability**: the ladder is unchanged and already the real thing; the loop
  adds one `inject` call per session and the failsafe presentation on `.widgetFailsafe`
  (`FailsafePanel.presentHeldTranscript()`, the root's responsibility — no push from the
  seam).
- **Privacy/local-first**: everything stays on-device; the probe (R7) is the permanent
  zero-network release blocker extended to the loop.
- **Pluggability**: the loop consumes seams; it introduces no new one. A hosted ASR
  provider would slot in at `ASREngine` with zero loop changes.
- **Module boundaries**: `VoccaUI` renders the projection over a Core-owned state/effect
  surface (it may import only `VoccaCore`); the waveform's level publisher must be
  fakeable headless and not tie `VoccaUI` to `VoccaAudio`.

## Risks & open questions

- **R1 (AX silent no-op) / R2 (Secure Input)** (`ROADMAP.md:300-301`): retired by C4's
  ladder; the loop must route through it and never bypass the allowlist gate. The Secure
  Input path through the composed loop is a smoke item (R8).
- **New: first-dictation model download.** A 470 MB–1.6 GB download cannot sit inside
  TRANSCRIBING. Mitigation (approved): background prepare at launch + honest refusal
  (R2/R5).
- **New: mid-session focus change.** Decided: target fixed at key-down (S1); the widget's
  indicator promise wins. If the founder finds this wrong in daily use, the P0 gate
  review revisits it.
- **New: waveform truthfulness.** The level path crosses a realtime callback
  (`AudioCaptureGraph` tap) into a MainActor projection; the mapping must be tested
  headless and the real path's first execution is a smoke item. A canned waveform is a
  spec violation (`PRODUCT_SPEC.md:88`).
- **CI cannot execute the loop** (no Accessibility, no TCC, no mic on hosted runners):
  the standing limit (`SMOKE_CHECKLIST.md`); every decision is above the seams and
  tested; the founder's machine is the loop's first CI.
- **Open: app display name for the target indicator** — bundle ID → "Slack" resolution
  (via `NSRunningApplication`, in the root) is plan-level; the projection carries the
  resolved name string.

## Out of scope

- CONVERSING state and everything P3+ (dual mode, barge-in, VAD/EOU) —
  `CAPABILITY_ROADMAP.md:205-238`.
- AI cleanup (C5/C6 — raw transcript is injected verbatim, per P0 scope discipline
  `ROADMAP.md:72-74`).
- Latency instrumentation, warm start, streaming/speculative ASR (C7 — P2 owns the
  numbers; `ROADMAP.md:98`).
- Per-app strategy memory / matrix harness (C8).
- Settings surface: toggle control, sounds (N1), hotkey rebinding.
- Model registry / out-of-tree provider proof (C14).
- Sounds and any audio feedback beyond the states above.

## Proposed aspects (for tech-plan; each independently buildable and test-first)

| Aspect | Boundary | Requirements |
|--------|----------|--------------|
| `loop-wiring` | Composition root: effect→ASR→injector routing in `VoccaBootstrap`, engine lifecycle (resolve-once, background prepare, refusal gate), Esc-cancel semantics, empty-text policy, target-at-key-down, toggle configuration. The machine is untouched. | R1, R2, R3, R6, S1 |
| `widget-live-states` | `VoccaUI` projection reducer + views for IDLE/OPENING/RECORDING/TRANSCRIBING/DELIVERED, waveform level publisher (fakeable) + Reduce Motion, timers (3 s, 110 s, 2 s esc hint, 600 ms collapse). | R4, S2 |
| `failure-surfaces` | The two `FailsafeReason` cases, copy-table entries, reason-only panel variant, presentation wiring from the root. | R5 |
| `probe-full-cycle` | Zero-network probe drives a complete dictation cycle; module witness list + coverage guard updated. | R7 |
| `smoke-checklist` | First-execution + loop smoke entries in `SMOKE_CHECKLIST.md` (docs-only). | R8(4) |

Rough shape: `loop-wiring` is the largest; `widget-live-states` depends on nothing from it
for its reducer (effects are Core-owned), so both can proceed in parallel after a shared
`SessionEffect` vocabulary check; `failure-surfaces` slots in before `loop-wiring` lands
(its refusal gate needs the reason), `probe-full-cycle` last, `smoke-checklist` alongside.
