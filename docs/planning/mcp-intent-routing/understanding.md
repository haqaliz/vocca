# Understanding — `mcp-intent-routing`

Phase 2 deep-dig. Worktree `feat/mcp-intent-routing/aliz`, base `origin/master` @ `ff694d8`.

## What the work is really asking

Make the MCP action arm **real and voice-reachable**, closing the gap between the
shipped MCP protocol/provider machinery and the P4 objective ("voice that *does
things*", `docs/ROADMAP.md:225`) and the P4→P5 gate's "≥3 distinct MCP tool
integrations working end-to-end from voice" (`docs/ROADMAP.md:250`).

Two capabilities, one spine:
1. **Compose `MCPProvider`** into the shipped app so configured servers actually
   produce a provider (today the rows are persisted but nothing serves them).
2. **Route `dev.vocca.mcp` by providerID** in the intent leg, mirroring
   `intent-provider-routing` (`vocca.agent` reaches its card; everything else
   falls to audit).

## Current state (verified in code, not prose)

- `MCPProvider` (`Sources/VoccaActions/MCP/MCPProvider.swift:79`) is a real
  `ActionProvider` actor with `defaultProviderID = "dev.vocca.mcp"` (`:86`),
  reachable **only** via `discover(session:providerID:)` (`:158-176`) — private
  init. Its `providerID` is an *instance* carrier (`:126`), unlike the other
  providers' statics.
- `MCPTransport` (`MCPTransport.swift:72-96`): `spawnsSubprocess` (default
  `false`), `send`/`receive`. Two real implementations: `InMemoryMCPTransport`
  (no syscalls) and `StdioMCPTransport` (the only spawner, `:152`).
- `ActionConfigStore` persists `action-config.json` = `servers:
  [MCPServerConfiguration]` + `enablement: [ActionConfigEnablementRow]`; rows key
  on **providerID + toolID** (`ActionConfig.swift:89-123`), caps 8 servers / 512
  rows (`ActionConfigStore.swift:76,81`).
- `ActionWiring.swift` **maps** the server rows (`:216-217`, `:228-229`, `:261`)
  but constructs **no** `MCPProvider`, and `discoverTools` is a bounded refusal
  `.failed("discovery.unwired")` (`:239-247`). The Actions tab already has
  "Configured servers" + "Tools" sections (`ActionsTabPage.swift:42-84`), then
  Shell (`:86-104`) and Coding agents (`:106-140`).
- `routeIntentWiring` (`IntentWiring.swift:391-410`) dispatches exactly two arms:
  `vocca.agent` → agent wiring (lazy `root.agentIntentWiring`), else audit.
  `spawnsSubprocess` hard-coded `false`.
- `AuditActionProvider` guards on providerID (`:190-192`); `CodingAgentProvider`
  and `MCPProvider` do **not** (safe only because the router gates).

## The hard constraint (must be designed around, not discovered at GREEN)

`StdioMCPTransportTests.testNothingOutsideTheTransportFileConstructsTheStdioTransport`
(`Tests/HarnessTests/StdioMCPTransportTests.swift:207-232`) scans **all of
`Sources/`** and asserts the only file naming `StdioMCPTransport` is its own file.
The whole D2 answer ("the default configuration cannot create a child") rests on
this. Wiring real stdio into the composition root is therefore either (a) a
**reviewed edit to this pin** (the `shell-provider` transport-permit precedent),
or (b) avoided by naming a **factory defined inside the permitted file**, so the
root never names the transport type.

Also: the transport-prohibition lint
(`ActionTransportProhibitionTests.swift:245-248`) permits exactly two files under
`VoccaActions/` (`StdioMCPTransport.swift`, `ShellExecutor.swift`); `AppBootstrap`
is *not* scanned by it (it scans `VoccaActions/`), so the root naming a factory is
fine.

## Dishonesty traps in the brief (surface these, don't paper over)

- **MCP tools are discovery-shaped, not registry-shaped.** Shell and agents read a
  *persisted file* for their rows without spawning; MCP tool rows only exist after
  `initialize` + `listTools`, which **spawns** on stdio. So "add an MCP section
  with tool rows" is not a copy of Shell/Agents — discovery is an OS touch.
- **`providerID` collision.** All servers default to `dev.vocca.mcp`, so two
  servers with the same tool name collide on an enablement row. A per-server ID
  convention (`dev.vocca.mcp.<serverID>`?) must be decided.
- **Arguments.** Phrase/Keyword resolvers supply no arguments
  (`ActionInvocation.arguments = nil`), so a voice MCP call describes as "with no
  arguments". Fine for a first slice, but it bounds what "end-to-end from voice"
  means.
- **`spawnsSubprocess`.** The router hard-codes `false`; an MCP wiring with
  configured servers must declare the truth (capability ≠ configuration, the
  Shell/Agent contract).

## Affected areas (file-level)

- New: `Sources/VoccaBootstrap/MCPWiring.swift` (the recipe, generic over
  `ActionProvider`), a transport-factory seam, root slots.
- `Sources/VoccaBootstrap/IntentWiring.swift` — a third `routeIntentWiring` arm.
- `Sources/VoccaBootstrap/AppBootstrap.swift` — composition, launch task, card
  confirm/decline routing (`:903-931`), tab arm/preview bindings (`:2300-2317`),
  G5 digest.
- `Sources/VoccaUI/Actions/` — the MCP section / discovery binding.
- `Sources/VoccaActions/MCP/` — possibly a factory type (in the permitted file).
- Tests: `StdioMCPTransportTests` pin (if stdio wired), `ActionSeamBoundaryTests`
  (new wiring rows), `ZeroNetworkTests` + `VoccaNetworkProbe` (a new drive),
  the 7 G5/SMOKE-mirror invariant suites, `Scripts/test-with-floor.sh` floor.

## Layer / phase

Layer: actions (P4, C13). Local-only; macOS-only; opt-in; no cloud. The default
must stay `spawnsSubprocess=false` with zero servers. It is a 23rd unit ahead of
the uncleared P2/P3 gates — the recorded posture; R8 is in a real voice path.

## Open questions for the interview / review gate

1. **Stdio wiring scope.** Ship real stdio in this slice (reviewed pin edit + a
   factory in the permitted file), or land the routing/surface spine over an
   injected transport factory with real stdio as a named follow-up?
2. **providerID convention** for multiple MCP servers.
3. **Discovery timing** — on Actions-tab section open (spawns per configured
   server) vs an explicit user action.
4. **Does the slice include the Actions-tab MCP surface**, or routing only?
5. **Arguments from voice** — accept "no arguments" for the first slice?
