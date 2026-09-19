# Aspect spec — `confirmation-gate`

**Boundary:** the structural refusal, the read-only direct path, dry-run, and per-tool
enablement. Pure logic in `VoccaCore/Actions/`. No persistence, no system calls.

**Sequencing:** after `action-seam`. Parallel with `audit-log`.

---

## Problem slice

R8 (`ROADMAP.md:307`, Med likelihood / **Fatal (trust)**) is the risk that a destructive
action runs unintended. C13's acceptance demands the bypass be **structurally impossible** —
asserted by attempting it and requiring refusal, not by observing no prompt appeared. This
aspect is that structure.

## In scope

- `ActionGate` — the single decision point. Inputs: an invocation, its blast radius, the
  enablement set, the mode (live / dry-run). Output: a decision.
- **The confirmation token** — minted only by the gate, initializer unreachable elsewhere
  (the epoch-minted `ModeSession` precedent).
- **Per-invocation confirmation only** (PRD M4a) — no "don't ask again", no per-tool or
  per-session carry-over. A second invocation of the same tool requires a second token.
- **Read-only direct path** — `readOnly` runs without confirmation.
- **Dry-run** — `describe` may be called; `invoke` is called **zero** times.
- **Per-tool enablement, default off, in-memory** (PRD M7 / N1) — a disabled tool is declined
  **before any provider call**, including before `describe` (the `ContextConsentGate`
  never-read precedent: declined, never called-then-discarded).

## The escalate-only rule (added 2026-09-19, from `action-seam`)

`action-seam` placed `BlastRadius` on `ActionSummary` — the value `describe` returns — because
only the provider knows a tool's radius. The consequence, recorded in
`ActionSummary.blastRadius`'s doc comment and binding on this aspect:

> **The blast radius is the provider's own claim, and nothing verifies it.**

A safety gate that trusts the thing it is gating is not a gate. This aspect therefore applies
a **local policy that may only ever escalate** a provider's claim and **may never
de-escalate** it:

| Provider claims | Local policy may make it | May NOT make it |
|---|---|---|
| `readOnly` | `destructive` / `outwardFacing` | — |
| `destructive` | `outwardFacing` | `readOnly` |
| `outwardFacing` | — | anything lower |

The safety argument this buys, stated so it can be checked rather than believed: **a lying
provider can only cause the user to be asked more often than necessary, never less.** A
provider that under-declares to skip confirmation cannot, because the policy is the floor and
the provider's claim can only raise it.

**Acceptance (RED first):** a provider declaring `readOnly` for a tool the local policy marks
destructive is **confirmed, not auto-run** — asserted by attempting the auto-run path and
requiring refusal. And the inverse: no input to the policy produces a radius lower than the
provider's claim, asserted over all three cases.

## Out of scope

Persisting enablement (follow-on N1); the audit log's storage (this aspect emits the record,
`audit-log` persists it); any UI or prompt rendering; the escape valve discussed in PRD §8.

## Acceptance criteria (written RED first)

1. **The load-bearing test.** A destructive invocation submitted **without** a token is
   **refused** — asserted by attempting the call and requiring refusal. Not "no prompt
   appeared."
2. A forged/bypass attempt is unavailable: the token cannot be constructed outside the gate.
   Asserted at the type level, with a comment recording that a compile-time failure is the
   intended proof.
3. `outwardFacing` behaves exactly as `destructive` today (both confirm) — pinned, so the
   PRD C4 decision to collapse or diverge them is a visible edit.
4. **Dry-run invokes nothing.** The stub provider **fails the test if `invoke` is called**
   (C13's own wording), and `describe` is permitted. Domain is non-empty via the M10 stub.
5. A **disabled** tool is declined before `describe` *and* before `invoke` — asserted on the
   stub's call log, which must record zero calls of either kind.
6. Enabling a tool, invoking, then disabling it refuses the next invocation — no carry-over.
7. Confirming once does **not** confirm twice: two invocations require two tokens.
8. A `readOnly` invocation of an **enabled** tool runs without a token.

## Dependencies

`action-seam` (vocabulary + the M10 executing stub).

## Open questions

- Where the token type lives so that `invoke` can name it while its initializer stays
  private — carried from `action-seam`.
- Whether the gate is an actor or a pure value. Prefer pure: it has no I/O, and the repo's
  scorers and gates (`ContextGrantGate`, `TurnCommitmentScorer`) are pure.
