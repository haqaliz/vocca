# Card: feat/local-data-provider

> Inline brief — no GitHub issue (`gh issue list` is empty). Source: the founder's
> instruction on 2026-09-19 to close guardrail 7 before building the MCP client, and the
> `action-safety-spine` unit record (STATUS head entry, deviation **D3**).

## ⚠️ Scope change, 2026-09-19 — the seam failed its first real test

Attempting the provider revealed that **the shipped seam cannot accommodate it**, and the
finding is worth more than the provider.

`ActionProvider.describe` and `invoke` are **synchronous and non-throwing**. C12's
`AccessibilityContext` satisfies a synchronous witness because AX is a synchronous C API — its
`nonisolated` witness never awaits. The audit store is an **actor** with `async throws` methods,
and **a nonisolated synchronous function cannot await an actor.** There is no way to write the
provider against the shipped contract.

This is not specific to the provider chosen. It applies to any provider whose work is
asynchronous — MCP over stdio, file I/O, subprocess, anything with latency. Slice 1 even
predicted the shape of the problem (`ActionProvider.swift` records that MCP adapters "will need
the C12 D1 route"), but the D1 route only works when the underlying work is *synchronous*, and
for MCP it will not be.

**Guardrail 7 did exactly what it exists to do.** The first honest test of the seam failed it,
at the cheapest possible moment: two call sites, no wiring, no surface.

**Both operations go async**, not just `invoke`. C13 requires the confirmation to state what will
happen *in concrete terms* — "clear the audit log, 12 entries, permanently" — and that count
requires a read. A synchronous `describe` would force vague copy, which is the specific failure
C13 names ("send this message to #general" rather than "execute slack_post").

What is **not** lost: failure stays a **returned value** (`async` without `throws`), so slice 1's
property that an omitted `catch` cannot silently drop an audit record survives verbatim.

Rejected alternatives: a synchronous audit reader (a second unserialized I/O path onto the one
file whose value is being trustworthy), and choosing a different synchronous provider (closing
guardrail 7 by picking an implementation that fits the seam instead of testing it — the
guardrail made ceremonial).

## Brief

Ship the **second real `ActionProvider`**, closing guardrail 7 for the Actions seam.

`action-safety-spine` (C13 slice 1, merged as `397bfd1`) shipped the seam, the gate, the audit
store and the transport lint — but recorded **D3: guardrail 7 unmet**. `NullActionProvider` is
the shipped default, not a second implementation, so `ActionProvider` is still *an assertion*
by the repo's own doctrine:

> **A seam with one implementation is not a seam; it's an assertion.**
> — `CAPABILITY_ROADMAP.md`, guardrail 7

`ARCHITECTURE.md`'s seam row currently reads `MCPProvider` **PENDING**, `ShellProvider`
**PENDING**.

## What ships: `AuditActionProvider`

A real provider over the audit store that already lives in `VoccaActions`:

| Tool | Blast radius | Behaviour |
|---|---|---|
| `audit.count` | `readOnly` | How many entries the audit log holds |
| `audit.clear` | `destructive` | Clears the audit log — irreversible |

## Why this provider (implementer's call — see "Decisions I own")

It must be **genuinely real** (or guardrail 7 stays unmet), **safe** (or it contradicts the
spine's premise that the gate ships before anything can execute), and need **no transport**
(or it walks straight into D2).

**The module boundary decided it.** `VoccaActions` declares exactly `["VoccaCore"]`, asserted
by *equality* (`VoccaActionsTargetTests`), and `ModuleBoundaryTests` rule 3 forbids an adapter
importing any Vocca module other than `VoccaCore`. So a provider in `VoccaActions` **cannot**
read `VoccaUsage`, `VoccaInject` or anything else. The audit store is already in `VoccaActions`,
so it is the one real capability reachable without either a boundary violation or an injection
layer this slice does not need.

Rejected:
- **`ShellProvider`** — the highest blast radius in the roadmap; building it in the slice whose
  premise is "safety before capability" is self-contradictory.
- **A clipboard provider** — would race `VoccaInject`'s existing save→set→paste→restore
  clipboard hygiene.
- **A usage-ledger provider** — requires crossing the module boundary above, so it needs
  capability protocols in `VoccaCore` plus composition-root wiring. Deferred; it is the natural
  third provider once a wiring slice exists.

## The design question this unit must pin, not hand-wave

**Clearing the audit log is itself an auditable action.** Order determines whether the system is
tamper-evident:

- Record the clear **before** clearing → the clear erases its own trace; the log looks untouched.
- Record the clear **after** clearing → the log reads "cleared", surviving as ordinal 1.

**The second is correct** and must be asserted, not assumed: after `audit.clear`, the log is not
empty — it contains exactly the record of its own clearing.

## Acceptance (test-first)

1. `AuditActionProvider` exposes exactly two tools, with the declared blast radii.
2. `audit.count` returns the real entry count, driven against a real store over a temp directory.
3. `audit.clear` empties the log **and leaves exactly one entry: the record of the clear.**
4. `audit.clear` is refused through the gate without a confirmation — the real-provider version
   of slice 1's load-bearing test, which until now only ran against a stub.
5. `audit.count` runs directly (read-only path) with an enabled tool and no token.
6. Dry-run of `audit.clear` leaves the log **byte-identical** — the strongest available form of
   "zero side effects", and only assertable now that a real provider exists.
7. The transport prohibition lint still passes — the provider names no transport.
8. Guardrail 7: `ARCHITECTURE.md`'s seam row moves off PENDING for this implementation, and D3
   is amended rather than deleted.

## Decisions I own (flagged, delegated by the founder)

- The choice of provider and its two tools.
- The record-after-clear ordering.
Both are cheap to override; neither was a founder decision.

## Out of scope

The MCP client and any transport; `ShellProvider`; the intent layer; any user-visible surface;
`AppBootstrap` wiring (so the G5 pin stays untouched); the usage-ledger provider (N3).
