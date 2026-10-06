# converse-intent-wiring — PRD

> The recommended next unit from `composite-intent-resolver` (PR #57; STATUS "shipped voice leg is unwired").
> Source: inline brief (`docs/planning/_card/issue.md`) + `understanding.md`. Greenfield-of-this-seam only:
> every piece it joins already exists and is tested. **Q1-Q3 below are my recommendations, labeled; the
> founder confirms at the review gate.** No gate passes; this is the twentieth unit ahead of the uncleared
> P3→P4 and P4→P5 gates.

## Problem Statement
`phrase-intent-resolver` (2026-09-25) recorded that "the shipped configuration can voice-act". It cannot:
the converse driver is composed without the intent leg, so the real app echoes every utterance and the
resolvers, the executor, the confirmation card and the audit log are exercised only by tests and probes.
The action surface (C13) has no voice path in a shipped build.

## Goals & Success Metrics
- A spoken phrase that matches a row in `intent-phrases.json` whose tool is enabled reaches the shared
  executor in the **real app**: read-only runs and is audited with a spoken ack; destructive/outward-facing
  shows the card and is audited; nothing else changes.
- With no phrase file or no enabled tool, behavior is **byte-identical to today's echo** (asserted).
- Measured by tests/probes only. **No success rate is claimed**; SMOKE rows 148-165 become runnable (no longer
  VOID) and are recorded, never gated.

## Persona & scenario
A Mac user who authored one phrase ("count the audit log") and enabled `audit.count`. In converse mode they
say it; Vocca counts and answers by voice. They author "wipe the log" → `audit.clear`; they say it; Vocca says
"Confirm on screen." and the card appears; they click Confirm; the action runs and is audited.

## Requirements
Must-have
1. **Wire the leg.** `AppBootstrap.configure` passes `intentProvider` and `intentActionHandler` to
   `composeConverseWiring`: lazy `[weak root]` closures that read `root.intentWiring` at call time
   (nil wiring or released root → nil → echo, the driver's existing fall-through). Resolve maps `.none` through
   unchanged; the handler is `performAction`. Constructed by one named static (e.g.
   `AppBootstrap.composeConverseIntentClosures(root:)`) so it is testable without `configure`.
2. **Default unchanged (asserted):** no phrase file, an empty table, or no enabled tool → the same reply the
   echo generator produces today, through the real wiring (not only the driver-level nil tests).
3. **Q1 (my recommendation): a card-up result is spoken, not echoed.** When `performAction` returns nil and a
   confirmation is now showing (`root.widgetStore.state.confirmation != nil`), the handler wrapper returns the
   fixed line **"Confirm on screen."** instead of letting the driver echo the user's words. `IntentWiring` and
   its pinned "honest-drop" test are untouched — the wrapper lives in the new static. A nil with no card up
   (a `.notInvoked`) still echoes (existing behavior).
4. The safety rows hold through the real path: outward-facing always cards (approval `.withheld`), every
   decision audited, `auditRecorded == false` → the failure copy, a second action while a card is up is
   refused (existing guard), a shell phrase cannot exist (refused at load), the keyword switch stays off by
   default and excludes shell + coding agents.
5. No new egress, no child process by default: `spawnsSubprocess=false` declared; the zero-network suite green;
   `PROBE-CONVERSE` output unchanged (it wires nil closures on purpose — comment updated).
6. **Pins:** a source-scan pin (the `converseReplySink:` precedent, `AppBootstrapWiringTests`) that
   `composeConverseWiring(` receives both intent closures; lint rows only as demanded; one deliberate G5
   re-anchor computed with `shasum -a 256` (seven sites); floor raised to the real count.

Should-have
- Docs: remove "shipped voice leg is unwired" from CLAUDE.md/STATUS/CAPABILITY_ROADMAP/ARCHITECTURE (keep the
  dated corrections as history), flip SMOKE 148-165 Void lines to runnable, record the findings below.
- SMOKE: one new row — the real-app voice round trip (read-only ack; destructive → "Confirm on screen." + card
  + confirm + audit entry; a mid-conversation card; the card with the reply bubble visible) — written, runnable,
  recorded, never gated.

Nice-to-have (deferred, named)
- Spoken confirm/decline (N2: new trust surface); a phrase-authoring UI; refusing/queuing a card during a
  session; clearing the card on session end; time-boxed/decaying trust; a PROBE drive of the real converse +
  intent composition over temp stores.

## Technical Considerations
- Phase P3/P4, layer: voice loop → actions seam. Local-only; no cloud, no dictation-path change (dictation
  digests pinned). Actor hop: `IntentWiring.resolve`/`performAction` are `@MainActor`, the driver closures are
  `@Sendable` — the closures `await` them; `root` is captured weakly (the driver retains the closures).
- Ordering: `intentWiring` is composed after the converse `Task` is created but before it runs; lazy reads make
  it a non-issue (verify with a test that the closure sees a wiring set after construction).
- Latency: one synchronous config/phrase read per turn on the already-awaited intent step (existing cost,
  previously unreached in the app); no ASR/VAD/TTS-path change. Not measured; no number claimed.
- Reuse: `ConverseIntentStepTests` harness (`ScriptedIntentProvider`), `IntentRoundTripHarness`,
  `IntentDriverIntegrationTests` voice round trip.

## Risks & Open Questions
- **R8 (destructive action, Med/Fatal)** now in a real voice path: mitigated in structure (card + `.withheld` +
  audit), not retired; N2 stands (an approval asserts a human said yes; click-only confirm today).
- Mid-conversation card (no session guard): recorded, accepted (Q3 recommendation); the card persists after the
  session ends until clicked.
- Card + reply bubble layout unverified — SMOKE only.
- The user can only author phrases by hand-editing JSON; reachable by the founder first.
- Open (founder): is "Confirm on screen." the right fixed copy, and spoken at all vs staying silent?

## Out of Scope
Spoken confirm; shell voice leg; settings/phrase UI; keyword-switch UI; threshold or synonym changes; display
names for the ask; any dictation/injection/ASR change; the P3→P4 gate evidence work.

## Self-critique (prd-generator, Phase 4)

| Dimension | Rating | Note |
|---|---|---|
| Problem definition | 🟢 | The gap is verified in code (`AppBootstrap.swift:583`, `ConverseWiring.swift:89-91`), not asserted. |
| User understanding | 🟡 | One persona, founder-shaped; no user has asked for voice actions. |
| Success metrics | 🟡 | Tests/probes only, by design; "voice acts" is unmeasured until SMOKE is run on a real machine. |
| Scope clarity | 🟢 | Wiring + one spoken line; spoken confirm, phrase UI and session guard explicitly deferred. |
| Edge cases & risks | 🟡 | See gaps 1-3. |
| Feasibility | 🟢 | Two lazy closures and a wrapper over shipped, tested parts. |
| Scope & layer fit | 🟡 | Local-only and pluggable; but it advances a phase early (twentieth unit ahead of uncleared gates) and puts R8 into a real voice path. |

### Top gaps
1. 🟡 **"Confirm on screen." is a new spoken string with a hidden dependency**: it is correct only if the card is
   actually visible (panel created lazily; layout with the reply bubble unverified). A user looking away hears
   an instruction they cannot act on. Mitigation here is only the SMOKE row; a real fix is a visible/audible
   cue contract in the card unit.
2. 🟡 **No session guard**: a destructive card can appear while converse continues and then outlive the
   session. The card is generation-tokened and click-only, so a stale card cannot be replayed, but a user who
   walks away leaves an armed card. Accepted and recorded; a clear-on-session-end rule is deferred.
3. 🟡 **The wrapper reads `widgetStore.state.confirmation` after `performAction` returns** — a race if the
   card was dismissed in between (the same MainActor, so unlikely) or if a *different* path put a card up.
   Plan must pin: wrapper speaks the line only when this call's result was nil AND a card is showing.

### The hard question
The question I'd want answered before greenlighting this: the phrase table is hand-edited JSON and enabling a
tool lives in an Actions tab the founder has not had a reason to open — so after this unit the *first and only*
person who can make Vocca act by voice is the founder, on a build that has cleared **none** of its gates. Is
this the right use of the slot, versus the P3→P4 gate evidence (a week of daily-use mode-confusion data) that
the roadmap says must come before agent work?
