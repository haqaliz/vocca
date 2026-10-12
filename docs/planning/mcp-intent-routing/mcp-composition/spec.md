# Spec — aspect `mcp-composition`

**PRD:** `docs/planning/mcp-intent-routing/prd.md` (must-have 1, 2, 3; G5, G6 groundwork).
**Depends on:** `mcp-provider-guard`. **Blocks:** `intent-and-surface`.

## Problem slice

No shipping target constructs an `MCPProvider`. `ActionConfigStore` persists
`MCPServerConfiguration` rows; nothing serves them. This aspect composes the MCP
arm: a transport factory, a per-server wiring recipe, per-server providerIDs, and
root slots — additive and probe-safe, the `composeShellWiring`/`composeCodingAgentWiring`
precedent.

## In scope

- **A transport factory inside the permitted file.** A public factory type defined
  in `Sources/VoccaActions/MCP/StdioMCPTransport.swift` (the file the D2 pin already
  permits) that builds an `MCPTransport` for an `MCPServerConfiguration`. The
  composition root names the **factory**, never `StdioMCPTransport` — the
  `StdioMCPTransportTests.swift:207-232` pin stays green. A factory closure is
  injectable so tests substitute `InMemoryMCPTransport`.
- **Per-server providerID.** A single, public helper computes
  `dev.vocca.mcp.<serverID>` (the suffix is `MCPServerConfiguration.id`); used by
  discovery and by enablement-row matching. The prefix constant is public.
- **`composeMCPWiring`** (`Sources/VoccaBootstrap/MCPWiring.swift`): generic over
  `ActionProvider`, policy floor `.none` (recorded), in-flight (`sessionActive`)
  refusal at arm, sentence-bound card with the mismatch re-prompt, every decision
  recorded, additive/probe-safe. Because `ActionExecutor<Provider>` is per-provider
  and MCP has one provider per server, the recipe exposes a **per-server lookup**:
  given a `providerID`, obtain (lazily discover once, cache) an
  `IntentWiring<MCPProvider>` for that server — or `nil` if no server matches or
  discovery fails.
- **`spawnsSubprocess` declared truthfully**: `false` with zero configured servers;
  `true` when a server is configured (the capability-vs-configuration contract).
- **No `AppBootstrap` edit in this aspect** (so the G5 digest is untouched here):
  the root slots and the `configure` wiring are the `intent-and-surface` aspect's,
  done in one pass with the router so G5 is re-anchored exactly once.

## Out of scope

- The intent router arm, the card routing, the Actions-tab discovery binding (the
  `intent-and-surface` aspect).
- Real discovery timing/caching policy beyond "lazy, once per server per process"
  (specified here, consumed by the surface aspect).

## Acceptance criteria (test-first)

- A1: `dev.vocca.mcp.<serverID>` is computed identically for discovery and for
  enablement matching (one helper, one test).
- A2: over an injected in-memory factory, `composeMCPWiring` for a configured
  server yields a wiring whose `performAction` on an enabled tool presents the
  sentence-bound card and, on Confirm, records exactly one invocation
  (`[.refused, .confirmed]`).
- A3: **two configured servers coexist without cross-talk** — a call to server A's
  providerID never reaches server B's provider (asserted by distinct sentences /
  distinct transports).
- A4: a discovery failure (in-memory transport returning a failure) yields `nil`
  from the lookup; the caller fails closed.
- A5: the composed default (zero servers) declares `spawnsSubprocess == false` and
  builds no provider (no factory call).
- A6: the in-flight refusal holds at arm (a session in flight refuses).

## Dependencies / sequencing

Build after `mcp-provider-guard`. No new module; no FileManager seam; the
transport-permit lint is unchanged (the factory is in the permitted file).

## Open questions / risks

- The exact shape of the per-server lookup (a closure returning
  `IntentWiring<MCPProvider>?`, or a small struct) — settle in the plan.
- Discovery caching must be a process-lifetime cache keyed by server id; a config
  edit that removes a server invalidates its entry.
