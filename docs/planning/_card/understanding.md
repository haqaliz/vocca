# Understanding: ShellProvider (feat/shell-provider)

Source: `docs/planning/_card/issue.md` (inline brief) + the Phase 2 code dig.
All claims below cite real files in the worktree; code wins over prose.

## What the unit is really asking

C13 slice 7: the P4 "run commands" leg of the wedge. A **shell-command `ActionProvider`**
that executes a *configured* command set on the user's machine, behind the existing
`ActionProvider` seam — with the full proven safety spine applied: the `describe`/`invoke`
split, the gate's structural refusal, sentence binding, dry-run with zero side effects, and
the append-only audit. It is the highest-blast-radius component in the roadmap
(`CAPABILITY_ROADMAP.md:483`, `action-surface-wiring/prd.md:219`), deferred for sequencing,
never blocked.

## Affected areas (from the dig)

1. **New provider** behind `Sources/VoccaCore/Actions/ActionProvider.swift:65-95` —
   `describe(_:) async -> ActionSummary` (pure; renders the concrete sentence), `invoke(_:confirmation:) async -> ActionOutcome` (async, **never throws**).
2. **Command configuration** — a registry of named commands (command line, sentence, blast
   radius claim) + enablement. The shipped `ActionConfigStore` (`action-config.json`) holds
   servers + enablement rows keyed `providerID`+`toolID`, "absent is off"
   (`Sources/VoccaActions/Config/ActionConfigStore.swift`). Whether shell commands reuse this
   store or need a sibling shape is a PRD decision.
3. **The transport-prohibition lint** — THE decisive constraint. `Tests/HarnessTests/ActionTransportProhibitionTests.swift:161-163` forbids `Process`/`posix_spawn`/`NSTask`/`system`
   in `Sources/VoccaActions/`, and the permitted set is **exactly one file**
   (`VoccaActions/MCP/StdioMCPTransport.swift`, `:200-202`). A `ShellProvider` names `Process`
   by definition, so it **cannot ship in `VoccaActions` without a reviewed widening** — and the
   widening owes the review an answer to D2 (a shell child is not observable; a restricted
   child purges the interposer env; the zero-network guard cannot see its egress).
4. **Composition + fact carrier** — the wiring recipes (`ActionWiring<Provider>`,
   `IntentWiring<Provider>`) are generic over the provider and declare `spawnsSubprocess`
   (`ActionWiring.swift:110,382`; `IntentWiring.swift:79,260`). The composed **default**
   pins `false`. A ShellProvider wiring must declare its value truthfully; the default
   configuration must still spawn nothing.
5. **Probe + zero-network interposer** — `VoccaNetworkProbe/` with the fact-carrier pattern;
   `PROBE-SHELL` would assert the composed default (`spawnsSubprocess=false`) inside the
   interposer (`Tests/HarnessTests/ZeroNetworkTests.swift` guard-the-guard family).
6. **Family-A lint** — a new provider conformance adds five rows to the per-family permitted
   tables in `Tests/HarnessTests/ActionSeamBoundaryTests.swift` (doc `:84-97`).

## The reuse that makes this tractable

The spine is built and generic: `ActionExecutor<Provider>` is the gate's only caller and
records every decision; the confirmation card, dry-run, sentence binding, mismatch re-prompt,
and re-render-after-record are all wired for any `Provider`. ShellProvider is a *third*
conformance, not new safety machinery. `InvokeBehavior.failsTheTestIfInvoked` already exists
for the dry-run acceptance; temp-dir store harnesses exist (`ActionWiringHarness`).

## Design questions the PRD must decide

- **Module placement**: `VoccaActions/` + a reviewed transport-permit widening (the
  stdio-transport precedent: empty → exactly one file; this would be one → two), versus a new
  module. The widening path is the honest one — it is the mechanism D2 reviews are recorded in.
- **Command configuration shape**: reuse `ActionConfigStore` enablement rows (providerID +
  toolID = command name) with a separate command-definition file, or a self-contained command
  registry. "No arguments ever" in the persisted enablement must hold; args travel only at
  call time.
- **Arguments**: fixed named parameters per command definition (`$1`, `$2`…), rendered
  `key = value` in `describe` exactly as `MCPProvider.swift:294-327` does; unreadable/missing
  args = refusal sentence **without de-escalating the radius** (`MCPProvider.swift:202-207`).
- **Composed default posture**: ShellProvider unwired (the `NullIntentResolver` precedent) so
  the composed default's fact carriers stay `false` — and the copy states where the claim
  stops (D2).
- **Real `Process` in CI**: the stdio-transport precedent already runs real children with
  real pipes and asserts no-orphan (`kill(pid,0) == -1 && errno == ESRCH`), so benign real
  shell commands (`/bin/echo`, `/bin/true`) in the suite are in-pattern.

## Open questions for the founder

- Is a shell command's blast radius **always** `destructive`/`outwardFacing` by default
  (conservative), with read-only only when the author declares a read-only command — matching
  the MCP fail-safe "absent means unsafe"?
- Should shell commands be voice-reachable in this slice (the intent catalog is built from
  enablement rows, so `IntentWiring` picks them up automatically once enabled), or arm-surface
  only?

## Guardrail check

macOS-only, local-only (executes on the user's machine), no cloud, never cripples the local
core, dictation core already shipped. The risk to record is **R8 amplified** (shell is
unboundedly destructive), **N2** (approval asserts a human said yes), **D2** (child not
observable) — all stated, none hidden. Phase: **P4** (C13).