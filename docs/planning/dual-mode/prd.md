# PRD: dual-mode (C11 — dictate vs converse)

> Source card: `docs/planning/_card/issue.md` (inline brief, 2026-09-16; no GitHub issue
> exists). Understanding: `docs/planning/_card/understanding.md`. Six founder decisions
> ratified 2026-09-16 at the requirements interview: **ReplyGenerator seam + minimal local
> deterministic implementation** (the real agent slots in at C13), **state-only reply
> surface** (no reply text rendering; `PRODUCT_SPEC.md:379`'s design pass is C13's),
> **per-mode cleanup only** (per-mode ASR engine deferred with its own stored-shape
> design), **both chords rebindable** in Settings → General with the collision warning,
> **menu-bar mode toggle included**, **ledger stays dictation-only** (converse sessions
> are not folded).

## Problem Statement

Vocca's voice loop exists as machinery and is composed into nothing. C10 shipped
`TurnTakingLoop`, `PlaybackEngine`/`SystemPlayback`, and `StreamingCapture` on 2026-09-15
— and its own records name the consequence: "nothing wires the loop into the app until
C11" (`docs/STATUS.md:107`), continuous capture "is composed only in the probe and the
env-gated suites until C11 gives it a visible state. This is a requirement, not a side
effect" (`docs/planning/turn-taking-barge-in/prd.md:90`). The `onStateChange` hook is
present and wired by nothing (`Sources/VoccaCore/TurnTaking/TurnTakingLoop.swift:107-108`);
the `PlaybackLevel` duck knob is plain data consumed by nothing; and `SessionMode
{dictation, conversing}` is a declared-never-read enum (`Sources/VoccaCore/SessionMode.swift:25-31`)
with `CleanupContext.mode` hard-coded to `.dictation` at the pipeline's only construction
site (`Sources/VoccaCore/DictationPipeline.swift:442,468-470`).

The product consequence is the one `CAPABILITY_ROADMAP.md:311` names: "If the user can
ever be unsure whether they're dictating into a field or talking to the agent, they will
eventually say something to Vocca that lands in a Slack message to their boss. Mode
ambiguity here is not a UX papercut; it's the failure that gets the tool uninstalled."
Today there is no mode at all: one chord, one path, no converse surface, no structural
barrier between a conversation and an app field. The P3 exit gate (`ROADMAP.md:215-219`)
— a full spoken exchange with barge-in, keyboard untouched — is structurally unreachable
until this unit ships, and every downstream capability (C12 context, C13 actions) needs
a mode machine to attach to.

## Goals & Success Metrics

- **G1 — The mode machine is real and the prohibition is structural.** `SessionMode`
  becomes an explicit state machine (the roadmap's seam, `CAPABILITY_ROADMAP.md:321`):
  mode is selected by the chord that starts a session, never inferred; switching
  mid-session is impossible ("release, switch, start again",
  `PRODUCT_SPEC.md:198-201`); and **no `TextInjector` call is ever made from the converse
  path** — enforced by type or assertion, not discipline, and asserted by the roadmap's
  own acceptance test (`CAPABILITY_ROADMAP.md:319`). A mode-transition test asserts full
  state reset with no carryover of buffer, transcript, or target.
- **G2 — Two chords, two activations, one stored truth.** `⌥⇧Space` is the converse
  chord (`PRODUCT_SPEC.md:192`), persisted alongside the dictate chord, both rebindable
  from Settings → General with the collision warning (`PRODUCT_SPEC.md:252`). The
  equality match semantics (`SessionRules.swift:66-72`) already keep `⌥⇧Space` distinct
  from `⌥Space`; a converse press can never end a running dictate session, and vice versa
  — that would be implicit mode switching.
- **G3 — The CONVERSING surface is unmistakable.** Five simultaneous cues, per
  `PRODUCT_SPEC.md` §5's defense: hotkey, shape (pill with a distinct notch), color
  (clearly different hue, not a tint), label (`◈ Vocca`; in-state `◈ listening…` /
  speaking), and sound (a lower tick, distinct from dictate's). **The widget never shows
  a target app name in converse mode** — the absence of `→ AppName` is itself a mode
  signal (`PRODUCT_SPEC.md:198-201`). Color is the third cue, not the only one, because
  of color-vision deficiencies (`PRODUCT_SPEC.md:203`).
- **G4 — The loop is wired, honestly and headlessly where CI can reach it.** C10's
  recorded recipe is executed: the capture-stream driver over `StreamingCapture`, the
  `TurnTakingLoop` composition in `VoccaBootstrap`, committed utterance → ASR → cleanup →
  reply → `scheduleReply` → synthesizer render → `PlaybackEngine` playback with
  `reportPlaybackStarted/Chunk/Ended`, and the barge-in path (cancel ≤50 ms + duck +
  discard) applied. The realtime conversation itself remains executed by nothing in CI
  (the tap-adapter precedent); the decisions above the seams are tested there.
- **G5 — Per-mode cleanup selection is real.** `CleanupContext.mode` is consumed at
  last: the converse path passes `.conversing` (cleaning the committed utterance with its
  mode's provider), the dictate path keeps `.dictation`, and a per-mode provider selection
  is persisted and configurable — closing the deferral named by `llm-cleanup/prd.md:216,267`,
  `cleanup-config/spec.md:48`, and `deterministic-cleanup/prd.md:219-220`. The
  timeout-yields-raw policy is unchanged.
- **G6 — The dictation path is preserved, and the pin says so honestly.** The G5 digest
  pin (`Tests/HarnessTests/TurnTakingComposedAcceptanceTests.swift:317-347`) guards
  `SessionMachine.swift`, `DictationPipeline.swift`, and `AppBootstrap.swift`. C11's
  wiring lands in `AppBootstrap` — so the pin is **deliberately re-anchored in a reviewed
  commit with the rationale recorded**, per the pin's own contract ("it must never be
  edited to match a moved tree"); the first two files stay byte-for-byte untouched, and
  the dictate wiring inside `AppBootstrap` is additive-only.
- **G7 — Zero-network holds over the new surface.** The converse default work runs over
  the fallback implementations (`EnergyVAD`, `SilenceThresholdDetector`) and the minimal
  reply generator — no model artifact, no SDK, no URL. A probe leg drives the converse
  path's default work inside the interposer; the zero-network test stays green; model
  artifacts provision through the C2 store, never inside `configure`.
- **G8 — The real surface is verifiable on the founder's machine.** SMOKE rows are
  written and runnable: the full spoken exchange (≥5 turns including a barge-in, the P3
  gate's leg), mode clarity / zero mis-injections, the converse chord rebind, the
  menu-bar toggle, and the converse-never-injects check. Recorded, never gated.

## User Personas & Scenarios

- **The founder mid-conversation.** Presses `⌥⇧Space`, sees a notched pill in a
  different hue labeled `◈ Vocca`, speaks, hears a spoken reply, interrupts it, and the
  reply stops within 200 ms — keyboard untouched. At no point is there a target app name
  on screen, because nothing will be typed.
- **The founder mid-dictation.** Presses `⌥Space`, sees the rounded pill with `→ Slack`
  as always. A stray `⌥⇧Space` cannot end the session or switch modes; the only way to
  converse is to release and start again.
- **The accessibility-first user.** Hold-to-talk remains available forever as the
  escape hatch (`CAPABILITY_ROADMAP.md:278`); both modes honor it, and the menu-bar
  toggle gives an explicit, non-chord switch surface (`PRODUCT_SPEC.md:361`).
- **The privacy auditor.** The widget never silently listens: CONVERSING is a visible
  state, the mode is never inferred, and the converse path hands no URL to anything. The
  ledger stays dictation-only — converse sessions are not recorded (recorded out of
  scope, not an oversight).
- **The next capability (C13 actions).** The `ReplyGenerator` seam and the mode machine
  are the attachment points: the real agent replaces the deterministic stand-in behind
  the same seam, and actions compose on the mode machine without touching this unit's
  machinery.

## Requirements

### Must-have

- **R1 (the mode machine):** `SessionMode` as an explicit state machine in `VoccaCore` —
  the current mode, the active wiring selection, and the transition rules. Mode is chosen
  at session start by the chord; there is **no implicit mode switching, ever**
  (`PRODUCT_SPEC.md:198`); mid-session switching is impossible; a transition resets all
  state (buffer, transcript, target) with no carryover. The injection path is reachable
  only from the dictate state. A chord for the **other** mode while a session is active
  is refused as a no-op (the only switch is release → press the other chord); a chord for
  the **active** mode is that session's own control (dictate: hold/toggle as today;
  converse: the stop affordance, R4). At most one capture is active at any time: the
  machine refuses a second mode's start, and `StreamingCapture`'s ownership contract (a
  second start refused) backs it.
- **R2 (the structural prohibition + reset, test-first):** the roadmap's two acceptance
  tests, written before the machine: (a) in converse mode **no `TextInjector` call is
  ever made** — enforced structurally (type/assertion), asserted by a test that would
  fail if any converse path could reach the injector; (b) a mode-transition test asserts
  full reset between modes with no carryover of buffer, transcript, or target
  (`CAPABILITY_ROADMAP.md:319`).
- **R3 (the converse chord, persisted and rebindable):** `⌥⇧Space` as the shipped
  converse chord; both chords persisted (`UserDefaultsSettingsStore`'s key-pair shape
  extended, never foreclosed — `hotkey-rebinding/prd.md:268`); both rebindable from
  Settings → General with the collision warning; a rebind is refused while any session
  is in flight; equality match semantics preserved so neither chord can end the other's
  session.
- **R4 (the CONVERSING widget state):** the sixth widget state — or the listening/
  speaking pair projected from the loop's `TurnState` — with the five simultaneous cues
  (hotkey, shape, color, label, sound), never a target app name, and `FailsafeState`
  staying separate. The widget remains a projection of the machine, never a source of
  truth (`ARCHITECTURE.md:408`). **The converse session must be stoppable by an explicit
  user action** (the converse chord again, Esc, or the menu-bar toggle — the exact
  surface decided in the aspect spec, recorded; no silent listening may persist), **and
  it stops on the system triggers** (sleep, display sleep, tap disabled) — continuous
  listening may never outlive them.
- **R5 (the menu-bar mode toggle):** the menu bar shows the current state and offers the
  explicit mode toggle (`PRODUCT_SPEC.md:361`) — explicit switching only, never
  inferred.
- **R6 (the converse wiring — C10's recipe, executed):** in `VoccaBootstrap` (additive,
  configure-adjacent — never inside `configure`'s probe contract): the capture-stream
  driver over `StreamingCapture`; the `TurnTakingLoop` composition with the shipped
  `SileroVAD`/`EnergyVAD` and `SilenceThresholdDetector` (the `ParakeetEOU` PENDING state
  is consumed as-is, never re-litigated); committed utterance → ASR (the existing
  resolve-once engine) → cleanup (`.conversing`) → `ReplyGenerator` → `loop.scheduleReply`;
  the synthesizer render + `PlaybackEngine` playback with `reportPlaybackStarted/Chunk/Ended`
  so the echo gate has its reference; the barge-in path applied (cancel ≤50 ms + duck +
  discard, the interrupting words preserved); capture failure → the honest stop; and
  `onStateChange` → the widget projection. A committed utterance whose ASR or reply
  generation fails is dropped honestly — the turn is not owed (the loop's capture-failure
  rationale), nothing is injected, and the widget returns to listening with an honest
  failure notice, never a silent hang. **The loop's signatures are frozen** — C11 wraps
  and selects, never modifies (`barge-in-loop/plan_20260915.md:866-868`).
- **R7 (the `ReplyGenerator` seam):** a protocol in `VoccaCore` naming no engine and no
  network, with **two deterministic local implementations** (the seam doctrine,
  `CAPABILITY_ROADMAP.md:413`): the shipped default is honest about being a stand-in —
  it must not pretend to be an agent — and C13's real agent slots in behind the same
  seam. Its exact copy/behavior is decided in the aspect spec and recorded.
- **R8 (per-mode cleanup):** `CleanupContext.mode` consumed for real; a persisted
  per-mode provider selection with the resolver reading it and a Settings surface to
  choose it (extending the existing Cleanup tab); the converse path cleans the committed
  utterance with its mode's provider; the timeout-yields-raw policy and the never-block
  guarantee are unchanged.
- **R9 (dictation-path preservation + the pin re-anchor):** `SessionMachine.swift` and
  `DictationPipeline.swift` stay byte-for-byte (their digests unchanged); `AppBootstrap.swift`'s
  changes are additive converse wiring, and the G5 pin is re-anchored in a dedicated,
  reviewed commit with the rationale recorded in the unit's record — the pin is never
  edited to match a moved tree.
- **R10 (probes, lints, zero-network):** a `PROBE-CONVERSE` leg (or the `PROBE-TURN`
  extension) drives the converse default work — fallback VAD/detector + the minimal reply
  generator — inside the zero-network interposer; the module-coverage cross-check and
  seam-family lints gain the new files; the floor (2160) ratchets per aspect in the same
  commit as the tests it counts.
- **R11 (SMOKE rows):** the dual-mode rows written and runnable — the full spoken
  exchange (≥5 turns, ≥1 barge-in, keyboard untouched), mode clarity / zero
  mis-injections across daily use, the converse chord rebind, the menu-bar toggle, and
  the converse-never-injects check. Recorded, never gated.

### Should-have

- **S1 — The `PlaybackLevel` duck tuned if the real hardware needs it** (the N2 knob:
  default `duckGain 0.5`, `rampDuration 20 ms`) — tunable without touching the loop;
  any change recorded.
- **S2 — A converse-mode hold-to-talk variant** if the machine's chord routing makes it
  cheap (the accessibility escape hatch stays whole either way; hold-to-talk in dictate
  is non-negotiable, converse-side is optional).

### Nice-to-have

- **N1 — Per-mode ASR engine selection** — explicitly deferred by this PRD (the
  engine-picker deferral stands, now with a named follow-on and its own stored-shape
  design: `EngineSelection` is single-valued today, `PersistedSettings` persists one
  tier).
- **N2 — Reply text surface** (widget area vs expanded panel, `PRODUCT_SPEC.md:379`) —
  deferred to the design pass with C13; C11 ships state-only.

## Technical Considerations

- **Phase/layer:** P3 (`ROADMAP.md:184-221`); voice-loop layer. The unit builds ahead of
  the uncleared P2/P3 gates under the recorded posture (third unit; `_card/issue.md`
  caveats), matching the kokoro-binding and turn-taking records.
- **Module map (unchanged rules, new files):** the mode machine, `ReplyGenerator` seam +
  its two implementations, and the prohibition in `VoccaCore` (imports nothing); the
  per-mode cleanup resolution in `VoccaText` (the `CleanupResolver` precedent); the
  converse chord persistence and Settings surface in `VoccaUI`; the converse wiring in
  `VoccaBootstrap` (the only module permitted to import adapters); `PROBE-CONVERSE` in
  `VoccaNetworkProbe` with the module-coverage cross-check updated.
- **Two "modes" must not be conflated:** hold/toggle **activation** mode
  (`DictationLoopRoot.defaultMode`/`setActiveMode(_:)`, `ARCHITECTURE.md:590`) is a
  dictation-only configuration; `SessionMode` is dictate-vs-converse. The known collision
  (`cleanup-seam/spec.md:139-141`) is resolved by naming discipline in the code.
- **Privacy:** zero-egress by construction; the converse path hands no URL to anything;
  the widget's mic-truthfulness principle (`PRODUCT_SPEC.md:11`) holds because CONVERSING
  is a visible state and the machine is the only place session state lives.
- **Latency:** the barge-in budget is consumed, not re-litigated (cancel ≤50 ms + duck
  + coordinator ≤200 ms); the converse path adds ASR + cleanup + reply generation on the
  committed turn — those are turn-latency, not the barge-in budget, and are measured in
  the probe/SMOKE, recorded never gated.
- **Dependencies:** C4 (injection ladder — shipped), C10 (turn-taking machinery —
  shipped), C9 transitively via C10. No new external dependency is expected; any
  package change is a reviewed decision (the kokoro/FluidAudio precedent).
- **CI edits:** the expected-import/family lints, the probe coverage cross-check, the
  pin re-anchor, and the floor ratchet — each in the same commit as the tests it counts.
- **Floor:** 2160 (`Scripts/test-with-floor.sh:1763`), ratcheted per aspect; the
  env-gated suites' visible skips count as executed.
- **SMOKE:** the dual-mode rows appended after step 133, each a recorded-never-gated row
  with the state-entered check; the P3 gate's spoken-exchange leg is the first row.

## Risks & Open Questions

| # | Risk / Question | Tie | Mitigation |
|---|-----------------|-----|------------|
| O1 | **The G5 digest pin guards `AppBootstrap.swift`, which C11 must touch** — an accidental edit-to-match would destroy the pin's value | R9 | Additive-only wiring; a dedicated re-anchor commit with the rationale recorded; `SessionMachine`/`DictationPipeline` digests unchanged; the pin's contract quoted in the plan |
| O2 | **The realtime conversation is executed by nothing in CI** — the wiring's real behavior is unverifiable there | R6/G4 | Every decision above the seams is headless-tested (the tap-adapter precedent); SMOKE rows are the real execution; no number is gated |
| O3 | **The reply stand-in could be mistaken for an agent** | R7 | Deterministic, local, honest copy decided in the spec; the seam is documented as C13's slot; no intelligence claimed anywhere |
| O4 | **Mode-confusion mis-injection is the catastrophic failure** (`ROADMAP.md:194`) | R1/R2 | Structural prohibition (type/assertion), the reset test, the never-a-target rule, and the SMOKE week; the injection path is unreachable from converse by construction |
| O5 | **The converse stop surface and system-trigger behavior are unplanned in PRODUCT_SPEC** — a silent listening state would violate the mic-truthfulness principle | R4 | The requirement names "stoppable by an explicit action" and the sleep/display-sleep/tap-disabled stops; the exact surface is an aspect-spec decision, recorded; `PRODUCT_SPEC.md:379`'s design pass owns the reply surface, not the stop |
| O10 | **A converse turn fails mid-flight** (ASR error, reply-generation error) with no transcript owed and no surface defined | R6 | The honest drop: no injection, no hang, the widget returns to listening with a failure notice; tested headless at the seam |
| O6 | **Two "modes" collide** (hold/toggle activation vs dictate/converse) | R1 | Naming discipline in code; the collision is a known, documented trap (`cleanup-seam/spec.md:139-141`) |
| O7 | **The five-cue prose drift** — `PRODUCT_SPEC.md:188` says "four differences" over a five-row table; `:203` calls color "the third cue" | R4 | C11 implements the five cues; the spec prose is corrected in the unit's record |
| O8 | **Per-mode cleanup extends a persisted settings shape and the Cleanup tab** | R8 | Small, additive keys; the resolver pattern is established; the tab extension is one control |
| O9 | **`ParakeetEOU` is PENDING** — converse turn commitment uses `SilenceThresholdDetector` | R6 | Consumed as-is; the PENDING state is a recorded input, never re-litigated; the seam is unchanged by this unit |

## Out of Scope

No reply text rendering (widget area or expanded panel — the C13 design pass,
`PRODUCT_SPEC.md:379`); no per-mode ASR engine selection (recorded follow-on, N1); no
converse-mode ledger folding (dictation-only, recorded); no agent/reply intelligence
beyond the deterministic stand-in (C13); no actions/MCP (C13); no context provider
(C12); no acoustic echo cancellation beyond the shipped gate; no changes to the loop,
the VAD/EOU seams, the dictation machines, the injection ladder, or the failsafe; no
new network surface of any kind; no EOU un-pending.

---

## Aspect decomposition

| Aspect | Boundary |
|--------|----------|
| `mode-machine` | The `SessionMode` state machine (VoccaCore): chord-keyed routing, no implicit switching, mid-session switch impossible, full reset on transition, the structural injection prohibition, the stop-affordance seam. The roadmap's two acceptance tests, RED first. |
| `reply-seam` | The `ReplyGenerator` protocol + two deterministic local implementations (VoccaCore), honest copy, no engine/network names, the seam contract tests. Independent of the machine. |
| `converse-hotkey` | The second chord: persistence (extended key-pair shape), the Settings → General surface for both chords, the collision warning, the rebind flow for both, the equality-match pins. |
| `converse-wiring` | C10's recipe executed (VoccaBootstrap, additive): capture-stream driver, loop composition, utterance → ASR → cleanup(.conversing) → reply → `scheduleReply` → render + playback with `reportPlayback*`, the barge-in path, `onStateChange` → projection, capture-failure stop; `PROBE-CONVERSE`; the G5 pin re-anchor commit. |
| `widget-converse` | The CONVERSING state(s) in `VoccaUI`: the five cues, the never-a-target rule, the listening/speaking distinction, the menu-bar mode toggle, the reducer/store growth, the copy pins. |
| `per-mode-cleanup` | `CleanupContext.mode` consumed (VoccaCore/VoccaText): per-mode provider selection persisted, resolver reads it, Cleanup tab surface, the unchanged timeout-yields-raw guarantee. |
| `record` | The SMOKE rows, the pin re-anchor record, the STATUS/CLAUDE.md/ARCHITECTURE.md sync, the five-cue prose correction, the floor, the honesty block. |

Sequencing: `mode-machine` and `reply-seam` first (independent, headless); then
`converse-wiring` (needs both); then `converse-hotkey`, `widget-converse`, and
`per-mode-cleanup` (parallelizable); `record` last. The `converse-wiring` aspect's pin
re-anchor lands in its first commit, before any `AppBootstrap` edit.
