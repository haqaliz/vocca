# Spec — aspect `mcp-provider-guard`

**PRD:** `docs/planning/mcp-intent-routing/prd.md` (must-have 4; G4).
**Depends on:** nothing. **Blocks:** `mcp-composition` (the per-server providerID
design relies on the guard).

## Problem slice

`MCPProvider` (`Sources/VoccaActions/MCP/MCPProvider.swift:190`, `:236`) serves a
tool by `invocation.toolID` alone and **never checks `invocation.providerID`** — the
same recorded defence-in-depth gap as `CodingAgentProvider`. Today it is safe only
because nothing routes foreign calls to it. Once the intent leg routes MCP by
providerID (and servers carry per-server providerIDs), the provider must refuse a
tool submitted under a foreign providerID.

## In scope

- `MCPProvider.describe` and `MCPProvider.invoke` serve a tool **only** when
  `invocation.providerID == self.providerID`; otherwise fail closed with the
  existing "does not serve the tool '…'. Nothing will happen." sentence
  (`describe`) and the `provider.unknownTool` key (`invoke`).
- One helper, judged in one place (the `AuditActionProvider.servedToolID`
  precedent, `AuditActionProvider.swift:190-192`).

## Out of scope

- `CodingAgentProvider`'s identical gap (a separate follow-up, not this unit).
- Any composition, routing, or surface change.

## Acceptance criteria (test-first)

- A1: `describe` with a foreign `providerID` returns the "does not serve … Nothing
  will happen." sentence at `.readOnly`, even when the `toolID` is a real tool.
- A2: `invoke` with a foreign `providerID` returns `.failed(reasonKey:
  "provider.unknownTool")` and the transport records **zero** `tools/call` frames
  (asserted on `InMemoryMCPTransport.sentMethods`).
- A3: the same-tool call under the provider's own providerID still describes and
  invokes unchanged (no regression).
- A4: a custom `providerID` passed to `discover(session:providerID:)` is the one
  the guard honours (per-server IDs work).

## Dependencies / sequencing

None. Ships alone; keeps the suite green; no composition-root edit (G5 untouched).
