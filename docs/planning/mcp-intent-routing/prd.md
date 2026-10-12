# PRD — `mcp-intent-routing`

> **Phase:** P4 (Actions/MCP) · **Slug:** `mcp-intent-routing` · **Branch:**
> `feat/mcp-intent-routing/aliz` · **Aspect:** C13 (the remaining MCP machinery)
> **Source:** inline brief (`docs/planning/_card/issue.md`); no GitHub issue.
> **Base:** `origin/master` @ `ff694d8`.

---

## Problem Statement

The MCP half of the action layer is **built but inert**. `MCPProvider` is a real
`ActionProvider` actor (`Sources/VoccaActions/MCP/MCPProvider.swift:79`,
`defaultProviderID = "dev.vocca.mcp"`, `:86`) with two real transports
(`InMemoryMCPTransport`, `StdioMCPTransport`), and `ActionConfigStore` persists
`MCPServerConfiguration` rows (`action-config.json`). But **no shipping target
constructs an `MCPProvider`** (`MCPProvider.discover` is called from tests only),
`ActionWiring`'s `discoverTools` is a bounded refusal `.failed("discovery.unwired")`
(`Sources/VoccaBootstrap/ActionWiring.swift:239-247`), the server rows are rendered
by the Actions tab but nothing serves them, and the intent leg routes **only**
`vocca.agent` (`IntentWiring.swift:391-410`).

Consequence: the P4 objective — "Vocca … can drive MCP tools … using active-app
context" (`docs/ROADMAP.md:225`) — is unmet, and the P4→P5 gate's acceptance
"**≥3 distinct MCP tool integrations working end-to-end from voice**"
(`docs/ROADMAP.md:250`) is unreachable. No user-visible regression exists today
because nothing MCP is reachable at all.

**Who has the problem:** the founder (the only current user), who can configure an
MCP server in the Actions tab but can never discover, enable, or voice-invoke its
tools. **Cost of the status quo:** the highest-leverage differentiator in the
roadmap ("voice that *does things*") has zero MCP behind it.

## Goals & Success Metrics

All metrics are **tests or probes** (no live-server rate is claimed — D2). The
default configuration is unchanged.

| # | Goal | Measurable signal |
|---|------|-------------------|
| G1 | Voice reaches an MCP tool | A phrase naming an enabled `dev.vocca.mcp.<serverID>` tool resolves → the sentence-bound confirmation card → Confirm records exactly one invocation (`[.refused, .confirmed]`), over an in-memory transport. |
| G2 | Nothing runs before a click | No invocation occurs across many voice turns without a Confirm click. |
| G3 | A disabled tool is inert | An un-enabled MCP tool is refused **by attempting the call** (the gate's enablement decline), provider count 0. |
| G4 | Provider routing is sound | A foreign `providerID` against the MCP provider is refused (the new `MCPProvider` guard). |
| G5 | The default cannot spawn | With zero configured servers the composed default still reads `agents=0 spawnsSubprocess=false`, the echo answers byte-identically, and the zero-network suite is green. |
| G6 | The surface is real and honest | Configuring a server makes discovery run (opt-in, per configured server); its tools appear as rows; enablement persists; the D2 copy is on the surface. |

## User Personas & Scenarios

- **The founder (primary, today).** Has a local MCP server binary. Adds it in
  Actions → Configured servers; opens the section (discovery runs); enables one
  tool; writes a phrase row in `intent-phrases.json` naming that provider/tool;
  speaks the phrase in converse mode; sees the concrete sentence ("Run the MCP
  tool '…' on the server '…', with no arguments."); clicks Confirm; the tool runs
  once and is audited.
- **A future MCP user.** Same flow, but the phrase/enablement surfaces are
  hand-edits today (the founder-only limitation, unchanged this slice).

## Requirements

### Must-have

1. **`composeMCPWiring`** (`Sources/VoccaBootstrap/MCPWiring.swift`) — a recipe
   mirroring `composeShellWiring`/`composeCodingAgentWiring`: generic over
   `ActionProvider`, policy floor `.none` (recorded), in-flight (`sessionActive`)
   refusal at arm, additive/probe-safe (nothing reads or spawns at composition),
   sentence-bound card with the mismatch re-prompt, every decision recorded.
2. **A transport factory inside the permitted file.** A factory type defined in
   `Sources/VoccaActions/MCP/StdioMCPTransport.swift` (the file the D2 pin already
   permits) so the composition root names a **factory**, never
   `StdioMCPTransport` — the `StdioMCPTransportTests.swift:207-232` pin stays
   green without a reviewed edit. The factory builds a `StdioMCPTransport` for a
   given `MCPServerConfiguration`.
3. **Per-server providerID: `dev.vocca.mcp.<serverID>`.** Each configured server
   is discovered with its own providerID (via `MCPProvider.discover(session:providerID:)`),
   so enablement rows never collide across servers. `MCPServerConfiguration.id` is
   the suffix.
4. **`MCPProvider` gains the providerID guard** — `describe`/`invoke` serve a tool
   only under their own `providerID` (the `AuditActionProvider.swift:190-192`
   precedent); a foreign providerID fails closed with the "does not serve … Nothing
   will happen." sentence. (Retires the recorded defence-in-depth gap for MCP.)
5. **The intent router arm.** `routeIntentWiring` (`IntentWiring.swift:391-410`)
   gains a third arm: an invocation whose `providerID` has the `dev.vocca.mcp`
   prefix dispatches to the MCP intent wiring, read lazily from a new root slot
   (the `agent()` pattern). Absent/failed MCP (startup window, discovery failure)
   falls through to the audit wiring's audited fail-closed.
6. **Card confirm/decline routing.** `root.actionConfirm`/`actionDecline`
   (`AppBootstrap.swift:903-931`) and the tab arm/preview bindings
   (`:2300-2317`) route `dev.vocca.mcp.*` to the MCP wiring.
7. **The Actions-tab MCP surface.** `discoverTools` is wired to the factory (opt-in
   per configured server; not `.unwired`); the discovered tools render as the
   existing tool rows; per-tool enablement persists through the shared store;
   default off. The D2 copy is on the section.
8. **Acceptance tests (test-first):** G1–G6 above.

### Should-have

- **Discovery is lazy and cached** *(decided 2026-10-12)*. Discovery runs on
  section open and on first voice use for a configured server; results are cached
  for the process — **at most one discovery per server per process**, and Confirm
  reuses the cache (no second spawn). Never eager at launch.
- **A bounded discovery timeout, failing closed** *(decided 2026-10-12)*. A
  discovery that spawns a slow or hostile binary is bounded by the transport's own
  `readTimeout`; a hung or failed discovery resolves to the **audit side's audited
  fail-closed** — never a card, never a run, nothing blocked indefinitely.
- **`spawnsSubprocess` declared truthfully** for the MCP wiring (false with zero
  configured servers; the capability-vs-configuration contract of Shell/Agents).

### Nice-to-have (deferred, named)

- Display names for the spoken ask; a settings row for `keywordFallback`; an
  `MCPProvider` re-discovery affordance on the surface.

## Technical Considerations

- **Layer / phase:** actions (P4, C13). Local-only, macOS-only, opt-in; no cloud.
- **The D2 pin is the load-bearing constraint** (`StdioMCPTransportTests.swift:207-232`):
  the factory-in-the-permitted-file design keeps the pin green while allowing
  real stdio opt-in. If the plan finds the factory must live elsewhere, permitting
  a second file is a **deliberate reviewed edit** recorded in the record.
- **The transport-permit lint** (`ActionTransportProhibitionTests.swift:245-248`,
  permitted set exactly two files under `VoccaActions/`) is **unchanged** — no new
  file names the `Process` family; the factory is in the already-permitted file.
- **`ActionExecutor<Provider>` holds one provider**, but MCP has one provider per
  server (one `MCPSession`). The MCP wiring therefore builds/obtains a provider
  **per server** (lazily, cached) rather than a single shared executor — the
  concrete shape is a tech-plan decision.
- **Module boundary:** no new module. `ModuleBoundaryTests` expects no change
  beyond the new wiring file obeying the rules.
- **FileManager seam table:** unchanged (no new FileManager seam).
- **`ActionSeamBoundaryTests`:** new `ActionProvider`/`ActionInvocation` rows for
  `MCPWiring.swift` (the seam's signatures force Family-A growth per real wiring).
- **`policy:` call-site count** (pinned at 96 in two invariant suites) moves with
  every new `ActionGate.submit(`; updated deliberately.
- **G5 pin:** `AppBootstrap.swift` changes → the digest is recomputed with
  `shasum -a 256` and re-anchored across all seven pin sites; the dictation digests
  (`1baeb2de…`/`ce70ca10…`) must stay unchanged. Floor raised in the same commit.
- **Probe coverage:** any new `.library` module ships its probe drive; this slice
  adds none, but a new `PROBE-MCP-VOICE` (or an extended drive) plus the
  `ZeroNetworkTests` expected line should be added, and the module-coverage
  cross-check stays green.
- **Zero network:** the in-memory transport makes no syscalls; stdio is loopback-
  free but a child — the interposer cannot see it (D2). No test claims egress
  detection.

## Risks & Open Questions

| Risk / Question | Severity | Note / mitigation |
|---|---|---|
| **R8 — a destructive MCP tool the user didn't intend** | Med / Fatal (trust) | Mitigated in structure (card + sentence binding + click + audit), **not retired**. `MCPProvider` `describe` marks a non-`readOnlyHint` tool `outwardFacing`. |
| **D2 — an enabled MCP child's egress is unprovable** | Standing | The honest copy carries the limit; the default cannot spawn; no rate is claimed. |
| **Discovery spawns** — when and how often | Med | **Decided:** lazy + cached, at most one discovery per server per process; section open or first use; Confirm reuses the cache; bounded by the transport `readTimeout` and failing closed to the audit side. |
| **Composite keyword fallback excludes shell + agents** — should it also exclude MCP? | Med | **Decided: yes** — add the `dev.vocca.mcp` prefix to `CompositeIntentResolver`'s exclusions (a phrase row may still name MCP explicitly). |
| **The multi-provider executor shape** (`ActionExecutor<Provider>` holds one provider; MCP has one per server) | Med | **Decided:** settle in the plan's first aspect — a lazily-built, cached wiring per server — with an acceptance that two configured servers coexist without cross-talk. |
| **Per-server providerID is dynamic** — a hand-edited phrase must match `dev.vocca.mcp.<serverID>` | Low | Founder-only today (the shell/agent precedent). Recorded. |
| **Two servers exposing the same tool name** | Low | Distinct providerIDs make rows distinct; the resolvers still pick one. Recorded. |
| **23rd unit ahead of the uncleared P2/P3 gates** | Standing | The recorded posture; "no gate passes", no rate quoted. |
| **Card + surface rendered by nothing in CI** | Standing | SMOKE rows only; recorded. |

## Out of Scope

- The **intent-seam shell leg** (a voice path to shell commands) — refused by
  founder decision.
- **Spoken confirm/decline (N2)** and a **session guard**.
- A **phrase-authoring UI** (`intent-phrases.json` stays hand-edited).
- **`$N` parameter slots** and **argument construction from voice** (a voice MCP
  call carries no arguments this slice).
- **Time-boxed / decaying per-tool trust** (§8, decided and deferred).
- **C14** (model registry + out-of-tree provider proof).
- Any change to the dictation path, capture, ASR, cleanup, injection, or TTS.
- Cloud: no hosted provider, no telemetry, no egress.
