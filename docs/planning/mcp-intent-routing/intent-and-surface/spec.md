# Spec — aspect `intent-and-surface`

**PRD:** `docs/planning/mcp-intent-routing/prd.md` (must-have 5, 6, 7; G1, G2, G3, G6).
**Depends on:** `mcp-composition`. **Blocks:** `probe-and-pins`.

## Problem slice

The composed MCP arm is unreachable by voice and by the surface: the intent router
dispatches only `vocca.agent`, the card's Confirm/Decline routes only
shell/agent/audit, the composite keyword fallback could select an MCP tool, and the
Actions-tab `discoverTools` binding is a hard refusal. This aspect closes all four.

## In scope

- **Router arm.** `routeIntentWiring` (`IntentWiring.swift:391-410`) gains a third
  arm: an invocation whose `providerID` has the `dev.vocca.mcp` prefix dispatches to
  the MCP wiring, obtained lazily from the new root slot. Absent/failed MCP
  (startup window, discovery failure, unserved provider) falls through to the audit
  wiring's audited fail-closed.
- **Card routing.** `root.actionConfirm`/`actionDecline` (`AppBootstrap.swift:903-931`)
  and the tab arm/preview bindings (`:2300-2317`) route the `dev.vocca.mcp` prefix to
  the MCP wiring.
- **Composite exclusion.** `AppBootstrap.composeIntentResolver` passes the MCP
  prefix alongside the shell and agent exclusions to `CompositeIntentResolver`, so
  the keyword fallback never selects an MCP tool. (A phrase row may still name MCP
  explicitly.)
- **Surface discovery + enablement.** The Actions-tab `discoverTools` binding
  (`ActionWiring.swift:239-247`) is wired to the MCP factory (opt-in per configured
  server); discovered tool rows carry the **per-server** providerID
  (`dev.vocca.mcp.<serverID>`) so enablement rows match the router; enablement
  persists through the shared store (default off). The existing "Configured servers"
  + "Tools" sections render it; the D2 copy is present.

## Out of scope

- A phrase-authoring UI; the phrase file stays hand-edited.
- Spoken confirm/decline (N2); a session guard.
- Argument construction from voice (a voice MCP call carries no arguments).

## Acceptance criteria (test-first)

- A1: a phrase naming an enabled `dev.vocca.mcp.<serverID>` tool resolves → the
  sentence-bound card → Confirm records exactly one invocation over an in-memory
  transport; Decline records none; no click across many turns runs nothing (G1, G2).
- A2: a disabled MCP tool is refused **by attempting the call** (the gate's
  enablement decline), provider count 0 (G3).
- A3: a foreign providerID (an MCP tool id under a non-MCP provider) is refused (G4,
  with `mcp-provider-guard`).
- A4: with `keywordFallback` on, the keyword resolver never resolves to an MCP row
  (the composite exclusion; the `-UNFILTERED` counterfactual fails when removed).
- A5: discovery for a configured server over an in-memory factory returns its tools
  with per-server providerIDs; the tool row toggles an enablement row keyed
  `dev.vocca.mcp.<serverID>` + toolID (G6).
- A6: a discovery failure surfaces `.failed(key)` and nothing is enabled; a hung
  discovery fails closed (bounded by the transport `readTimeout`).

## Dependencies / sequencing

Build after `mcp-composition`. Touches `AppBootstrap` (G5 re-anchor), `IntentWiring`,
`ActionWiring`, `ActionsTab*` (UI), and the composite composition.

## Open questions / risks

- The UI cannot name `VoccaActions` types (module boundary); discovery results map
  at the root, the `ActionsConfigDraft`/`agentFile` precedent.
- Whether the MCP section is a distinct `Section` or reuses the existing "Tools"
  section — the existing sections already exist; prefer reuse with the D2 copy.
