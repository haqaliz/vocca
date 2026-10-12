# Source: inline brief (no GitHub issue)

`id` is a slug (`mcp-intent-routing`); no GitHub issue was fetched. The brief
below is the source of truth, carried from the `vocca-next` handoff.

## Brief

Compose `MCPProvider` (over the existing `MCPTransport`, in-memory for tests)
from the `MCPServerConfiguration` rows `ActionWiring.swift` already persists,
add an opt-in Actions-tab MCP section (discovery + per-tool enablement, default
off, the D2 copy), and route `dev.vocca.mcp` in the intent leg by `providerID`
— the `intent-provider-routing` pattern — so a phrase naming an enabled MCP
tool reaches the sentence-bound confirmation card and only Confirm runs it
through the shared executor.

Caveat to respect in the plan: the real stdio transport spawns a child and its
egress is unprovable (D2) — keep it opt-in/configured, do not let the default
spawn, and quote no MCP success rate until a real server run exists.

## Acceptance tests (written first)

- A disabled MCP tool is never callable (asserted by attempting the call).
- A phrase resolves → card → confirm → one recorded invocation over an
  in-memory transport.
- A foreign-provider `providerID` is refused.
- The composed default still reads `agents=0 spawnsSubprocess=false` with zero
  servers.

## Phase placement

P4 (Actions/MCP), C13 — the P4→P5 gate requires "≥3 distinct MCP tool
integrations working end-to-end from voice" (`docs/ROADMAP.md:250`). Today
`MCPProvider` is composed nowhere; the MCP server rows are persisted but no
provider serves them.
