# intent-provider-routing — PRD

> Source: the recorded follow-up of `converse-intent-wiring` (PR #58) — `docs/planning/_card/issue.md` +
> `understanding.md`. **Q1-Q3 are my recommendations, labeled; the founder confirms at the review gate.**
> No gate passes; this would be the twenty-first unit ahead of the uncleared P3→P4 / P4→P5 gates.

## Problem Statement
The shipped intent leg sends every resolved call to `AuditActionProvider`. A phrase naming an enabled coding agent
fails ("Something went wrong.", an audited failed entry — nothing spawns, no card), so the P4 deliverable
"Voice → a coding agent session with the active project as context" is untrue in the shipped build; and because the
audit provider (and the gate) never check `providerID`, a foreign row whose tool id is `audit.count`/`audit.clear`
gets the audit tool's behavior.

## Goals & Success Metrics
- A phrase naming an enabled `vocca.agent` row, spoken in converse mode in the real app, shows the **outward-facing
  card** with the argv-derived sentence (full utterance as `<task>`, the focused app's project directory); nothing
  runs until the user clicks Confirm; Confirm runs the agent through the existing reviewed path; every decision is
  audited.
- Every intent dispatch checks `providerID` against the provider that serves it (**the named acceptance test**).
- Audit tools behave exactly as today; the default (no file / no enabled tool) is byte-identical (echo);
  `agents=0 spawnsSubprocess=false` stays true for the composed default.
- Measured by tests/probes only. **No success rate is claimed**; SMOKE 158/162/166 become runnable.

## Persona & scenario
A Mac user who enabled the `claude` agent row and authored the phrase "fix the failing test" → `vocca.agent/claude`
with a `<task>` placeholder. In converse mode they say it; Vocca says "Confirm on screen."; the card shows
`Run claude -p "fix the failing test" in ~/dev/app`; they click Confirm; the agent runs; the result is audited.

## Requirements
Must-have
1. **Routing.** A non-generic router (`RoutedIntentWiring`: `resolve`, `performAction`, `spawnsSubprocess = false`) over
   two existing `IntentWiring<P>` values: the audit wiring (composed in `configure` as today) and an agent wiring
   (`IntentWiring<CodingAgentProvider>` over the agent provider + `root.agentExecutor`), the agent side read **lazily**
   from the root slot at call time (it is built in a later launch task). `performAction` selects by
   `invocation.providerID`; `vocca.agent` → the agent wiring when present; **any other providerID — including
   `vocca.agent` while the agent side is not composed — → the audit wiring** (Q3). `root.intentWiring` becomes the
   router; `composeConverseIntentClosures` and the probes keep working unchanged through the same three members.
2. **`providerID` guards.** `AuditActionProvider.describe`/`invoke` serve a tool only when
   `invocation.providerID == AuditActionProvider.providerID`; a foreign `providerID` (even with an `audit.*` tool id)
   is the existing "does not serve … Nothing will happen." fail-closed path — audited, spoken failure copy, never the
   audit tool (Q2: no card for a call that cannot invoke anything). `IntentWiring`'s agent lookup matches
   `providerID == CodingAgentProvider.providerID` AND `toolID`.
3. **The card precedes the spawn (asserted end to end).** Voice submits `.withheld`; the agent row is `outwardFacing`;
   the spawn count is 0 until `agentWiring.confirm()`; after Confirm exactly one run with the card's sentence; decline
   spawns nothing; a changed sentence re-prompts (the binding). A placeholder row with an empty utterance is refused
   before any card ("Cancelled.", recorded); the full utterance fills `<task>`; over-long/missing task refusals hold.
4. **Default unchanged:** no phrase file / no enabled tool / no agent rows → the same echo; `PROBE-CONVERSE`,
   `PROBE-INTENT-DEFAULT` (`spawnsSubprocess=false`, `intentShellRows=0`) and `PROBE-CODING-AGENT`
   (`agents=0 spawnsSubprocess=false`) lines byte-identical.
5. **Shell stays unreachable** by voice (phrase store refuses at load; keyword leg excludes shell + agents; a shell
   `providerID` falls through to the audit wiring, which refuses it). Dictation untouched. Zero network by default.
6. **Pins:** source-scan pin that `configure` assigns the router (not the bare audit wiring) and wires the lazy agent
   lookup through `rootBox`; lint rows only as demanded (the router names `ActionProvider`-generic wirings, so
   `ActionSeamBoundaryTests`'s permitted list needs reviewed rows); one deliberate G5 re-anchor (`shasum -a 256`,
   seven pin sites); floor raised to the real count.

Should-have
- Docs: resolve every "agent phrase is not voice-reachable" / "provider id limit" pointer (CLAUDE.md, STATUS,
  CAPABILITY_ROADMAP, ARCHITECTURE, SMOKE 158/162/166) with `[resolved … by intent-provider-routing]`, keep history;
  R8 mitigated not retired; "twenty-first unit"; the new honesty block.
- SMOKE: flip 158/162 from known-failing to runnable; extend 166's agent step with the expected card + Confirm + a
  recorded agent run — written, runnable, recorded never gated.

Nice-to-have (deferred, named)
- Routing shell to the voice leg (founder call, stays refused); MCP provider routing; spoken confirm (N2);
  session guard / clear-card-on-session-end; a phrase-authoring UI; display names for the ask.

## Technical Considerations
- Phase P4 (coding-agent handoff), layer actions; local-only. Router in `VoccaBootstrap`; the transport lint
  (`VoccaActions/`, exactly two permitted files) is untouched — no file names `Process`/`ShellExecutor`.
- Confirm routing is already by `card.providerID`; the intent leg presents the card with `providerID`/`taskText`/
  `resolvedDirectory`, so Confirm needs no change.
- Concurrency: router closures `@Sendable`/`@MainActor` as the existing wirings; the lazy root read follows the
  `rootBox` weak pattern.
- Latency: no new per-turn I/O beyond the agent registry read the agent branch already does.
- **Posture:** "the default configuration spawns no child process" stays true — a spawn requires a hand-written phrase,
  an enabled agent row AND a click. This is the first shipped path from speech to a child; the click is the gate (N2:
  an approval asserts a human said yes; ambient audio cannot click).

## Risks & Open Questions
- **R8 (destructive action, Med/Fatal)** — an agent run is `outwardFacing` and unbounded in effect (the agent can edit
  files, run commands): mitigated in structure (card + sentence binding + audit + timeout + reaping), **not retired**;
  "an enabled agent's egress is never provable" (D2) stands.
- Q1 (verify in the plan): does `CodingAgentWiring.confirm` refuse while a converse session is active (the arm path
  does via `sessionActive`)? If so, a voice-armed card could be un-confirmable until the session ends — decide
  (accept + record, or relax confirm's guard — NOT in this unit without a founder call).
- Q2 (recommended): unserved providers stay a fail-closed audited failure, not a card.
- Q3 (recommended): agent side not composed → fall through to the audit wiring's audited failure.
- The full utterance becomes the child's `<task>` argv (≤4096 bytes, refused not truncated): it is visible on the card
  before the click; nothing is hidden.
- The card + reply bubble layout and the real agent run remain unverified (SMOKE only).

## Out of Scope
Shell/MCP voice routing; spoken confirm; session guard; phrase UI; timeouts or env changes to agents; any dictation,
injection or ASR change; the P3→P4 gate evidence work.

## Self-critique (prd-generator, Phase 4)

| Dimension | Rating | Note |
|---|---|---|
| Problem definition | 🟢 | Two defects verified in code; the dead agent branches identified. |
| User understanding | 🟡 | Founder-shaped single persona; no user has asked for voice → agent. |
| Success metrics | 🟡 | Tests/probes only, by design; the real agent run is unmeasured until SMOKE. |
| Scope clarity | 🟢 | Routing + guards only; shell/MCP/spoken-confirm/session guard excluded. |
| Edge cases & risks | 🟡 | See gaps 1-3. |
| Feasibility | 🟢 | Reuses two shipped wirings; no new engine; lints untouched. |
| Scope & layer fit | 🟡 | Local-only and pluggable; but speech → child process in a shipped build is the highest-blast-radius step yet, 21st unit ahead of uncleared gates. |

### Top gaps
1. 🟡 **Confirm-during-session (Q1)** — if `CodingAgentWiring.confirm` shares the arm path's `sessionActive` refusal, the
   voice flow is broken by design (a card that cannot be confirmed while the session that created it runs). The plan's
   first step must read that code; the PRD deliberately does not assume.
2. 🟡 **The router's lazy agent lookup** has a startup window (agent wiring composed in a launch task): a phrase spoken
   before it exists falls through to the audit wiring's failure. Acceptable, but the user hears "Something went wrong."
   for a valid phrase — a copy question for a later unit.
3. 🟡 **Blast radius vs evidence.** Everything here is test-covered; none of it has run against a real agent CLI on a
   real machine, and the P3→P4 gate evidence (a week of mode-confusion data) predates agent work by the roadmap's own
   rule.

### The hard question
The question I'd want answered before greenlighting this: the roadmap's R12 says the agent layer must not slip behind
endless dictation polish, but its R4/gate language says agent work comes *after* external confirmation of parity. This
unit lets a spoken sentence start `claude -p "<anything you said>"` on your machine. With zero gates cleared, zero
external users, and the real-machine card layout still unverified (SMOKE 166 unrun) — is making speech able to reach a
child process now the right trade, versus running SMOKE 166 first and letting #58's audit-tool path soak?
