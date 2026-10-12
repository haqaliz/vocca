# Spec — aspect `probe-and-pins`

**PRD:** `docs/planning/mcp-intent-routing/prd.md` (G5; the invariant machinery).
**Depends on:** `intent-and-surface`. **Blocks:** nothing (it is the closing slice).

## Problem slice

Every provider composition in this repo ships with a zero-network probe drive, the
invariant families' mirror rows, a deliberate G5 re-anchor, and a raised floor.
This slice adds the MCP equivalent so the slice's claims are asserted rather than
described, and the default posture is pinned.

## In scope

- **A probe drive** (`Sources/VoccaNetworkProbe/MCPVoiceDrive.swift` or an extension
  of the existing MCP drive): exercises the composed MCP arm over an in-memory
  factory — phrase → card → Confirm → one recorded invocation; the disabled-tool
  refusal; the default (zero servers) `spawnsSubprocess=false`; the foreign-provider
  refusal. Emits a `PROBE-MCP-VOICE` line with counts/booleans only.
- **`ZeroNetworkTests`** expected lifecycle line + accessor; the drive's
  `moduleWitness` (if a new module — none here) folded into the coverage list.
- **Invariant mirrors**: the `PROBE-MCP-VOICE` line and/or the new wiring rows added
  to the families that mirror them (`ReplyRenderingInvariantTests`,
  `AuthBaselineInvariantTests`, `ActiveProjectInvariantTests`,
  `AgentPresetsInvariantTests`, `SpokenTaskInvariantTests`) as the record's pattern
  requires; `ActionSeamBoundaryTests` rows for `MCPWiring.swift`; the `policy:`
  call-site count updated.
- **G5 re-anchor**: `AppBootstrap.swift` recomputed with `shasum -a 256`, the digest
  re-anchored across all seven pin sites, the dictation digests
  (`1baeb2de…`/`ce70ca10…`) confirmed unchanged.
- **Floor**: `Scripts/test-with-floor.sh` `MINIMUM_EXECUTED_TESTS` raised to the
  executed count in the same commit; the comment updated with the digest move.

## Out of scope

- SMOKE rows (written in the unit record, runnable, never gated).
- Any behavior change.

## Acceptance criteria (test-first)

- A1: `PROBE-MCP-VOICE` is byte-pinned by `ZeroNetworkTests`; the zero-network suite
  is green (the in-memory factory makes no syscalls).
- A2: the default composed root reads `agents=0 spawnsSubprocess=false` and the
  MCP drive reports zero servers/zero providers.
- A3: all seven G5 pin sites carry the recomputed digest; the dictation digests are
  unchanged.
- A4: the floor script's minimum matches the executed test count.

## Dependencies / sequencing

Last. The G5 re-anchor lands after the final `AppBootstrap` edit
(`intent-and-surface`); if that aspect and this are split, the re-anchor lands with
whichever edits the root last.
