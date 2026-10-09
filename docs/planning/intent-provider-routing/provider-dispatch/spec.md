# provider-dispatch — aspect spec

Single aspect of `intent-provider-routing`. Source: `../prd.md` (approved 2026-10-09). Q1 answered from code:
`CodingAgentWiring.confirm` has NO `sessionActive` guard (only `arm` does, `CodingAgentWiring.swift:308`), so a
voice-armed card is confirmable mid-conversation. Q2/Q3 as recommended in the PRD.

## Problem slice / outcome
A spoken phrase naming an enabled `vocca.agent` row reaches the agent provider: card first, spawn only after Confirm.
Every intent dispatch is checked against the provider that serves it. Audit behavior and the default are unchanged.

## In scope
PRD must-haves 1-6, should-haves. **Planning deviation (recorded):** the router is NOT a new generic-free type; it is a
function returning an `IntentWiring<AuditActionProvider>` whose `performAction` dispatches — the root slot type, the
converse closures, the probes and every existing harness stay untouched.

## Out of scope
Per PRD: shell/MCP voice routing, spoken confirm, session guard, phrase UI, agent env/timeouts, dictation.

## Acceptance criteria (the failing tests, written first)
P1 `AuditActionProvider` serves a tool only when `invocation.providerID == AuditActionProvider.providerID`: a foreign
   providerID with tool id `audit.count`/`audit.clear` → describe is the "does not serve … Nothing will happen." sentence
   AND the call fails closed through the gate (audited failure, store untouched: `audit.clear` with a foreign providerID
   deletes nothing — assert the audit files still exist); the real audit tools unchanged.
P2 `IntentWiring`'s agent lookup requires `providerID == CodingAgentProvider.providerID` AND `toolID == agent.id`: an
   audit-provider invocation whose toolID equals an agent id takes NO agent path (no cwd enrichment, no placeholder
   refusal, no taskText).
R1 router dispatch by providerID (spies): `vocca.agent` + agent wiring present → agent wiring's `performAction`, audit
   wiring's count 0; any other providerID → audit wiring; `vocca.agent` + agent side nil → audit wiring (Q3); `dev.vocca.shell`
   → audit wiring (which fails it closed); `resolve` is the audit wiring's; `spawnsSubprocess == false`.
R2 lazy lookup: a router built BEFORE the agent slot is assigned dispatches to it AFTER (the launch-task ordering).
E1 end to end over the REAL audit + agent wirings (AgentWiringCwdHarness pattern): phrase → `vocca.agent/<id>` → card up with
   the argv-derived sentence, full utterance as `<task>`, resolved directory; agent run count 0; audit `[.refused]`;
   Confirm → run count 1 with exactly the card's sentence, audit `[.refused, .confirmed]`; Decline → run count 0, audit
   `[.refused, .refused]`; empty utterance on a placeholder row → "Cancelled.", no card, count 0; a second voice action while
   the card is up → the existing card-up refusal (nil → "Confirm on screen." via the converse wrapper), still one card.
E2 default posture: agent rows enabled + phrases present but NO click across N voice turns → run count 0, always;
   no phrase file → echo (resolve `.none`); composed default `spawnsSubprocess == false`, `agents=0` for an empty registry.
E3 a foreign `audit.clear` row (providerID `vocca.agent`, tool id `audit.clear`) never deletes audit entries.
G1 source-scan pin: `configure` assigns the routed wiring to `root.intentWiring` and wires the lazy agent lookup through
   the weak root; G5 re-anchored once (seven sites, dictation digests unchanged); floor raised to the real count; the
   PROBE-CONVERSE/PROBE-INTENT-DEFAULT/PROBE-CODING-AGENT lines byte-identical; transport lint untouched.

## Risks
First shipped speech → child path (click-gated); the startup window before the agent wiring exists (audited failure);
the real agent run and the card layout unverified (SMOKE only).
