# intent-provider-routing — Phase 2 understanding (2026-10-08)

Layer: actions (C13), P4 coding-agent handoff. Local-only; no cloud. No gate passes. The first slice where a
spoken phrase can lead to a CHILD PROCESS in a shipped build — but only after a hand-authored phrase, an enabled
agent row AND a click on the card.

## What is really being asked
Make the shipped intent leg dispatch each resolved call to the provider that serves its `providerID`, instead of
sending everything to `AuditActionProvider`. Today that is wrong in two ways (both verified in code):
1. A phrase naming `vocca.agent` is described by the audit provider ("does not serve the tool … Nothing will
   happen.", claims `.readOnly`), auto-runs, FAILS ("Something went wrong.", an audited `autoRanReadOnly` failed
   entry). The agent branches inside `IntentWiring.performAction` (cwd enrichment, `<task>` placeholder, pre-card
   refusal, card with `taskText`/`resolvedDirectory`) are dead in the shipped build — they run (they read
   `root.agentRegistry`) but their `provider.describe` is the audit provider's.
2. `AuditActionProvider` selects its tool by `toolID` alone (`:121-139`, `:165-179`); `ActionGate.submit` never
   checks the invocation's `providerID` against the provider. A foreign row with tool id `audit.count` gets the
   audit tool.
Plus: `IntentWiring.swift:273` matches the agent row by `toolID` only (an audit/MCP tool whose id equals an agent
id would take the agent path).

## Verified constraints
- `ActionExecutor<Provider>` is generic over ONE provider ("per-provider by construction"); no composite provider
  exists; one executor cannot serve several providers.
- Three wirings exist, each over its own executor + provider: `ActionWiring<AuditActionProvider>` (sync, in
  `configure`), `ShellWiring<ShellProvider>` and `CodingAgentWiring<CodingAgentProvider>` (both built LATER in launch
  `Task`s after async registry loads). The intent wiring is composed synchronously, BEFORE the agent provider exists —
  so any routing must look the agent side up lazily through the root.
- Card CONFIRM/DECLINE already route by `card.providerID` (`AppBootstrap.swift:852-876`) to `agentWiring.confirm()`; the
  confirm re-submits with `.granted` + `approvedSentence` (the sentence binding is re-checked by the agent provider's
  describe); the spawn site is `ShellExecutor.swift:211/:236` behind the reviewed timeout/reap machinery. The transport
  lint scans only `VoccaActions/` and permits exactly two files — routing code in `VoccaBootstrap` names neither.
- `composeConverseIntentClosures` and the probes read `root.intentWiring` only through `.resolve`, `.performAction`,
  `.spawnsSubprocess`; `spawnsSubprocess` is declared `false` everywhere and PROBE-INTENT-DEFAULT asserts it.
- The tests that compose the wiring over `CodingAgentProvider` (AgentWiringCwdTests:311, UtteranceThreadingTests:486)
  already exercise the full agent voice flow against a generic `IntentWiring<CodingAgentProvider>`.

## Design options (recommendation in the PRD)
A) Composite `ActionProvider` dispatching by providerID — needs a third audit writer / second describe path; the
   gate can't tell it which route confirms; rejected.
B) **Thin router over TWO existing `IntentWiring<P>` values** (audit, agent): one shared `resolve`; `performAction`
   picks the wiring by the resolved invocation's `providerID`; the agent side is read lazily from the root; any other
   providerID falls through to the audit wiring, whose provider now guards `providerID` (an unserved provider is
   refused/failed, audited, never executed). Reuses every existing, tested piece.

## Open questions → PRD
- Q1 confirm-time `sessionActive` guard for agents: the agent ARM path refuses while a converse session is running;
  does CONFIRM? (plan must read `CodingAgentWiring.confirm`).
- Q2 unserved providers: keep the fail-closed audited failure (recommended) vs a card.
- Q3 agent not yet composed (launch Task pending / no agents configured): fall through to the audit wiring's audited
  failure (recommended) — never a hang.
