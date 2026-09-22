# PRD: ShellProvider

> C13 slice 7 — the P4 "run commands" leg of the wedge.
> Source: `docs/planning/_card/issue.md` (inline brief) + `_card/understanding.md`.
> Decisions confirmed with the founder 2026-09-22: destructive-by-default blast radius,
> arm-surface only this slice, self-contained command registry, and **the concrete
> sentence is derived from the argv** (never trusted as authored prose).

## Problem Statement

Vocca's action surface can drive **MCP tools** (mcp-protocol, stdio-transport) and **the
audit log** (local-data-provider), but the wedge's P4 promise is *"voice → run commands /
drive MCP tools / coding agents"* (`ROADMAP.md:41`, `CAPABILITY_ROADMAP.md:388`). The
**run commands** leg does not exist. The user who wants "vocca, empty my Downloads folder"
or "vocca, open the staging environment" has no way to express a local command as an action.

Shell is the **highest blast radius in the roadmap** (`action-surface-wiring/prd.md:219`,
`intent-layer/prd.md:253`): a shell command can do anything the user can do, and the
confirmation surface is the *only* mitigation. That is precisely why the C13 safety spine
exists (`action-safety-spine`, `action-surface-wiring`, `intent-layer`): the gate's
structural refusal, the sentence binding, dry-run, and the append-only audit were built to
be the sternest possible gate in front of the highest-risk provider. `ShellProvider` is
that provider — the third `ActionProvider` conformance, exercising the spine for real.

## Goals & Success Metrics

- **Goal 1 — Shell actions exist behind the seam.** A configured command set is describable
  and invocable through the existing gate → executor → audit round trip, with no changes to
  the safety machinery.
  - *Metric:* `ShellProvider` conforms to `ActionProvider` (`ActionProvider.swift:65-95`);
    the generic wiring recipes compose it with zero provider-specific special-casing.
- **Goal 2 — The safety spine holds at maximum radius.** A destructive shell action without
  confirmation is structurally refused, dry-run has zero side effects, and every executed
  action reconstructs from the audit log.
  - *Metric:* the C13 load-bearing acceptances pass against ShellProvider
    (`CAPABILITY_ROADMAP.md:394`) — refusal *by attempting the call*, never by observing
    that no prompt appeared.
- **Goal 3 — The default configuration still spawns nothing.** Adding ShellProvider does not
  weaken the D2 promise ("default config makes zero network calls **and spawns no child
  process**", `CLAUDE.md`).
  - *Metric:* `PROBE-SHELL` asserts the composed default (`commands=0`,
    `spawnsSubprocess=false`) inside the zero-network interposer; the D2 limit is stated in
    the copy.
- **Goal 4 — No transcript/safety regression.** The dictation path and the action surface
  are byte-for-byte untouched (the G5 pin precedent) and the floor ratchets.
  - *Metric:* dictation digests unchanged; `Scripts/test-with-floor.sh` floor raised in the
    suite's growth commit.

**Non-goals as metrics:** no resolution/accuracy rate exists and none may be quoted; no gate
passes (the recorded posture holds — this is the eleventh unit ahead of the uncleared gates).

## User Personas & Scenarios

- **The power user** (primary): a developer or operator who wants a repeatable local
  command (deploy script, "tidy downloads", "open the env dashboard") available as a Vocca
  action — armed from the Actions tab, confirmed on a card, recorded in the audit log. They
  configure commands once in a JSON file they can version-control, and enable each per-tool.
- **The privacy-conscious user**: runs the default configuration; sees that nothing is
  configured, nothing spawns, and the copy says where the claim stops.

Scenario: the user configures `empty-downloads` (destructive) and `open-dashboard` (read-only)
in `shell-commands.json`, enables both. From the Actions tab they arm "open-dashboard"; the
card shows the concrete sentence; confirming runs the command, the audit log reconstructs it.
Arming "empty-downloads" without confirming is refused *by attempting the call* — no file
is ever touched without the granted sentence.

## Requirements

### Must-have

- **R1 — Command registry** (`command-registry` aspect): a self-contained persisted registry
  `shell-commands.json` (founder decision): named commands with a command line, a
  **`readOnly: Bool`** flag, fixed named parameters (`$1`, `$2`, …), and the concrete
  sentence template. Tolerant decode (absent/corrupt file → empty registry, never a throw),
  caps (bounded command count and byte limits), atomic writes, **no arguments ever persisted**
  in enablement (the `ActionConfigStore` discipline — enablement is membership, args travel
  only at call time).
- **R2 — Destructive by default** (founder decision, MCP "absent means unsafe" precedent):
  a command whose config does **not** declare `readOnly: true` claims
  `BlastRadius.destructive` (or `outwardFacing` where the command egresses). The gate's
  escalate-only policy can only raise this, never lower it (`ActionGate.swift:152-168`).
- **R3 — `ShellProvider` conforms to `ActionProvider`** (`provider` aspect): `toolIDs` from
  the registry; `describe` renders the **concrete sentence derived from the argv** — the
  command name + the rendered argv (`key = value` for supplied arguments, sanitised, keys
  sorted — the `MCPProvider.swift:294-327` discipline) plus the author's optional plain
  clause, **never a bare command echo and never trusted authored prose** (founder decision:
  the card confirms what actually runs); unknown-tool / unknown-command refusal as a value;
  unreadable/missing arguments render a refusal sentence **without de-escalating the radius**
  (`MCPProvider.swift:202-207`); `invoke` is async, never throws, returns `ActionOutcome`
  with bounded reason keys; never constructs an `ActionConfirmation`.
- **R4 — Safe execution** (`execution` aspect): the subprocess engine with a **bounded
  injected-clock timeout — hard ceiling 30 s — with a wait-count** so a spin loop cannot
  pass (the stdio-transport contract), **no orphan** (asserted
  `kill(pid, 0) == -1 && errno == ESRCH` — the stdio-transport acceptance), bounded output
  capture, exit code → `ActionOutcome` mapping, and a hostile battery (typed failure on
  exit, timeout, flood).
- **R5 — The transport-permit widening, reviewed** (`provider` aspect): `Process` is a
  forbidden family in `VoccaActions` and the permitted set is exactly one file
  (`ActionTransportProhibitionTests.swift:161-202`). `ShellProvider` names `Process` by
  definition, so the widening is the reviewed-edit mechanism — and it **owes the review the
  D2 answer**: a shell child is not observable, a restricted child purges the interposer env,
  so the zero-network guard cannot see a shell child's egress; the claim narrowed in writing
  (the `stdio-transport` precedent) is that the *default configuration* cannot create one.
- **R6 — Wiring, unwired default** (`wiring` aspect): additive composition in `AppBootstrap`
  (the `NullIntentResolver` precedent) — nothing is composed into the default, so the
  composed default's fact carriers stay `false`; a ShellProvider wiring declares
  `spawnsSubprocess` truthfully (the analogue of `StdioMCPTransport.swift:152`). Enablement
  rows reuse the `ActionConfigStore` shape (providerID + toolID). **Arm-surface only this
  slice** (founder decision): shell commands are reachable from the Actions tab arm surface,
  never from the intent catalog; the intent seam gets a shell leg deliberately in a later
  slice.
- **R7 — Probe + guard-the-guard** (`probe` aspect): `PROBE-SHELL` drives the composed
  default inside the zero-network interposer asserting `commands=0`, `spawnsSubprocess=false`; the
  guard-the-guard readers refuse a version that no longer describes the composed default.

### Should-have

- **S1 — Family-A lint rows**: the five per-family permitted rows the new conformance forces
  (`ActionSeamBoundaryTests.swift:84-97`), delivered in the same commit as the provider.
- **S2 — SMOKE rows** for the real surface: configure → enable → arm → confirm → command
  runs → audit reconstructs; the destructive-refusal row; the dry-run row. Written and
  runnable, **recorded, never gated**.
- **S3 — Command-level overrides** on the arm surface for the cases the sentence template
  gets wrong (the `InjectionStrategyStore` user-visible override precedent). *(If the arm
  surface is generic this may be free or deferred — decide in wiring.)*

### Nice-to-have

- **N1 — Per-command timeout config** beyond the enforced ceiling.
- **N2 — Environment scrubbing** documented (env vars passed are the configured ones, never
  the full environment) if the execution engine scrubs by default.

## Technical Considerations

- **Seam:** `Sources/VoccaCore/Actions/ActionProvider.swift:65-95` — `describe` async + pure;
  `invoke` async, **never throws** (failure stays a returned value so an omitted `catch`
  cannot drop an audit record). Core is Foundation-free; the vocabulary (`ActionInvocation`,
  `ActionSummary`, `ActionOutcome`, `BlastRadius`) is already pinned.
- **Gate/executor:** `ActionExecutor<Provider>` is the gate's only caller and records every
  decision (`ActionExecutor.swift:120-141`); the wiring recipes are generic over the provider
  (`ActionWiring.swift:54-139`, `IntentWiring.swift:60-102`). ShellProvider is a *third
  conformance*, not new safety machinery.
- **Module placement:** `VoccaActions/` (with the reviewed transport widening) — the
  stdio-transport precedent (empty → exactly one permitted file) extended to exactly two. The
  widening is the mechanism the D2 review is recorded in.
- **Dependencies:** the shipped spine (action-safety-spine, local-data-provider,
  mcp-protocol, stdio-transport, action-surface-wiring, intent-layer). No new external
  dependencies. Test floor **2761**.
- **CI reality:** real `Process` runs on macOS runners and the founder's machine (the
  stdio-transport precedent already runs real children); the suite must use benign commands
  (`/bin/echo`, `/bin/true`) and the hostile battery must be scripted, not adversarial.
- **Probe/interposer:** the composed default is driven inside the zero-network interposer
  (`Tests/HarnessTests/ZeroNetworkTests.swift`); loopback counts as NETWORK on purpose.

## Risks & Open Questions

- **R8 amplified (HIGH):** shell is unboundedly destructive. Mitigation: the proven spine
  (structural refusal by attempting the call, sentence binding, dry-run, audit) applied at
  the maximum radius, plus destructive-by-default. **N2 is stated:** an approval asserts a
  human said yes and cannot verify it; the binding narrows what an approval can be replayed
  against.
- **D2 (recorded):** a spawned shell child is not observable and a restricted child purges
  the interposer env — the zero-network guard cannot see a shell child's egress. The claim
  narrowed in writing: the *default configuration* cannot create one.
- **Classifier accuracy (inherited, unmeasured):** the intent seam is arm-surface-only this
  slice, so no classifier involvement; still no rate may be quoted.
- **Open question 1:** does the arm surface's generic enablement rows already render shell
  commands, or does the wiring aspect need a small shell leg in the Actions tab? (Decide in
  wiring; the generic recipe suggests the former.)
- **Open question 2:** stdout/stderr content — captured, bounded, and *not* persisted
  (the raw argument blob never-persisted precedent). The audit entry keeps only the rendered
  sentence (bounded 1 KB, `ActionAuditEntry.swift:117-137`).
- **Resolved at the gate:** the concrete sentence is **derived from the argv** (name +
  rendered argv + optional authored plain clause, sanitised), never trusted authored prose —
  the card confirms what actually runs. Timeout ceiling pinned at **30 s** with the
  injected-clock wait-count contract.

## Out of Scope

- **Voice-triggered shell actions** (founder decision) — the intent catalog stays
  MCP/audit-only this slice; a shell leg lands with a later intent seam.
- **Coding-agent handoff** — its own C13 remaining item, needs subprocess execution as a
  precondition but is not this slice.
- **Interactive/piped commands** (no stdin, no shell metacharacter expansion beyond the
  configured argv), **sudo / privilege escalation**, **arbitrary user-typed command lines**
  (the registry is a fixed configured set, not a REPL).
- **Argument-building UI** — arguments come from the fixed named parameters, validated by
  the provider.
- **Time-boxed / decaying per-tool trust** — the §8 deferral stands (blockers recorded in
  intent-layer: persisted trust state, changed approval semantics, M4a).
- Any change to the dictation path, capture, ASR, cleanup, injection, TTS, or the MCP
  transport. Cloud anything: no hosted provider, no telemetry, no egress.

## Aspect Decomposition

1. **`command-registry`** — `shell-commands.json` shape, tolerant decode, caps, atomic
   writes, destructive-by-default rule, validation.
2. **`provider`** — `ShellProvider` conformance, describe/invoke discipline, unknown/unreadable
   refusal without de-escalation, the transport-permit widening + D2 answer, Family-A rows.
3. **`execution`** — the subprocess engine: bounded timeout, no-orphan, bounded output,
   exit-code mapping, hostile battery.
4. **`wiring`** — additive `AppBootstrap` composition, unwired default, `spawnsSubprocess`
   truthfulness, enablement reuse, arm-surface reachability, copy.
5. **`probe`** — `PROBE-SHELL` + guard-the-guard inside the zero-network interposer.
6. **`record`** — unit record, docs sync (STATUS/CLAUDE/CAPABILITY/ARCHITECTURE), SMOKE
   rows, floor ratchet in the same commit as the suite growth.

## Data Model

`shell-commands.json` (Application Support, the `ActionConfigStore` directory shape):

```json
{
  "version": 1,
  "commands": [
    {
      "id": "empty-downloads",
      "command": ["/usr/bin/find", "~/Downloads", "-type", "f", "-delete"],
      "readOnly": false,
      "parameters": [],
      "clause": "This cannot be undone."
    },
    {
      "id": "open-dashboard",
      "command": ["/usr/bin/open", "http://localhost:3000"],
      "readOnly": true,
      "parameters": [],
      "clause": "Opens the staging dashboard."
    }
  ]
}
```

- `command` is a fixed argv array — **no shell expansion, no metacharacters**, nothing the
  user types at call time. `parameters` declare fixed named slots (`$1`, …) rendered
  `key = value` in `describe`. `readOnly` defaults to `false` when absent (destructive by
  default). `clause` is an *optional* plain-text sentence the author adds; it is appended to
  the **argv-derived** sentence (`name` + rendered argv + clause, sanitised), so the card
  confirms what actually runs and a misleading clause cannot hide a different argv.
- Enablement lives in the existing `ActionConfigStore` (providerID `dev.vocca.shell` +
  command id), **never in this file** — enablement is membership; arguments travel only at
  call time, never persisted.