# Card: feat/action-safety-spine

> Inline brief — no GitHub issue exists (`gh issue list` for `haqaliz/vocca` is empty).
> Source: the `vocca-next` handoff (2026-09-19) + `CAPABILITY_ROADMAP.md` C13 entry +
> the C11/C12 unit records (STATUS.md dual-mode + context-provider entries).

## Brief

Build the **first slice of C13 — Actions and MCP** (`CAPABILITY_ROADMAP.md` C13, P4):
the **safety spine**, over a stub provider only. **No MCP wire, no intent layer, no real
tool execution** in this unit.

What the slice establishes:

- The `ActionProvider` seam in the reserved `VoccaActions` module
  (`ARCHITECTURE.md:154` reserves `VoccaActions/  # P4 — ActionProvider, MCP client`;
  `ARCHITECTURE.md:284` reserves the seam row with `MCPProvider`, `ShellProvider` as its
  two implementations and **hosted: No**).
- **Blast-radius classification** of an action — read-only vs destructive/outward-facing.
- A **confirmation gate** that states what will happen in concrete terms before it happens
  ("send this message to #general"), never abstract ("execute slack_post").
- **Dry-run**: every action previewable as "here's what I would do" before it is armed.
- A local, **append-only audit log** with enough detail to reconstruct what happened.

## Acceptance (test-first — the load-bearing tests)

From C13's acceptance in `CAPABILITY_ROADMAP.md`:

1. A destructive action without confirmation must be **structurally impossible** — asserted
   by *attempting* the call and requiring it to be **refused**, not merely by observing that
   no prompt appeared.
2. **Dry-run must produce zero side effects** — asserted by a stub that *fails the test if
   invoked*.
3. Every executed action must appear in the **audit log**, asserted by reconstruction.
4. A **disabled tool is never callable**.

## The caveat to settle in the dig, before any code

**MCP transports are an egress surface.** Local stdio servers are subprocesses and stay
inside the zero-network promise; a remote MCP server over HTTP/SSE *is* egress and would
trip the `connect(2)` interposer, which is a permanent release blocker (`CLAUDE.md`,
guardrail 2 in `CAPABILITY_ROADMAP.md`). The default composition must ship **stdio-only or
with zero servers**, and any remote transport must be opt-in and badged at the point of use
like BYOK. Decide this in the dig, not at the probe failure.

## Posture (recorded, not drifted)

This would be the **fifth unit built ahead of the uncleared P2/P3 gates**. Every prior unit
record says "No gate passes"; this one must too. The gates are blocked on things this code
cannot fix: the P2 external-users leg needs distribution (notarization recorded
**blocked — not purchased**), the injection matrix was **closed by founder decision** with
FMS not computable, and the P3 conversational leg is formally unmet until C13's real agent.

Separately and in parallel (founder-hands work, no worktree): **SMOKE 129-143 are written,
runnable, and executed by nothing.** No TTFA, turn-commitment, echo, or context-resolution
percentage exists on a real machine, and the P0 seven-day ledger streak has never
accumulated.

## Dependencies (all shipped)

C10 (`turn-taking-barge-in`), C11 (`dual-mode`), C12 (`context-provider`) — per
`CAPABILITY_ROADMAP.md` C13's dependency line and the STATUS.md head entry.

## Named deferrals that point at this capability

- `docs/planning/dual-mode/prd.md:6` — `EchoReplyGenerator` is an honest stand-in;
  "the real agent slots in at C13".
- `docs/planning/dual-mode/prd.md:205` + `PRODUCT_SPEC.md:379` — reply-text rendering
  deferred to "the C13 design pass".
- `CLAUDE.md` — "the P3 gate's conversational leg stays formally unmet until C13's real
  agent".

**Note:** the reply/intent layer and reply-text rendering are *not* in this slice. They are
C13's later slices; this unit is the safety spine only.
